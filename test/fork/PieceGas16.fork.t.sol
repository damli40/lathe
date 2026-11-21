// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LatheOrders} from "../../src/LatheOrders.sol";
import {IProcessor} from "../../src/ITapeOut.sol";
import {Piece, PieceKind} from "../../src/FormulaLib.sol";
import {MockFactory} from "../mocks/MockProcessor.sol";
import {MockUSDT} from "../mocks/MockUSDT.sol";

/// @dev Calls eval with all the gas it has and reports what one eval cost.
contract EvalMeter16 {
    function cost(address p, uint256 id, bytes calldata inputs) external view returns (uint256 used, bytes memory out) {
        uint256 g0 = gasleft();
        out = IProcessor(p).eval(id, inputs);
        used = g0 - gasleft();
    }
}

/// @dev A 16-input GreaterOrEqual(8, 8) piece that pays the real 8x8 multiplier's eval gas on every case: it calls
/// the real multiplier (id 16, 652 gates) with the same 2 input bytes, throws the product away and answers a >= b.
/// It reports 652 gates, so Lathe gives each case the real multiplier's budget. No such circuit exists on chain;
/// it exists so checkPiece can be measured end to end with real per-case circuit cost. The extra call layer makes
/// the measured figure a little higher than a real 652-gate piece would be.
contract MulCostPiece {
    address public immutable mul;
    address public immutable who;

    constructor(address mul_, address who_) {
        mul = mul_;
        who = who_;
    }

    function ownerOf(uint256) external view returns (address) {
        return who;
    }

    function circuitInfo(uint256) external pure returns (uint32, uint32, uint32, uint32) {
        return (16, 1, 0, 652);
    }

    function netlist(uint256) external pure returns (bytes memory) {
        return "mul-cost-piece";
    }

    function eval(uint256, bytes calldata inputs) external view returns (bytes memory) {
        IProcessor(mul).eval(16, inputs);
        return abi.encodePacked(uint8(uint8(inputs[0]) >= uint8(inputs[1]) ? 1 : 0));
    }
}

/// @notice Gas per case for a 16-input piece, on the real 8x8 multiplier (X Layer mainnet fork, block 76,432,018).
/// Part 1 measures the multiplier's own eval at 16 inputs. Part 2 measures checkPiece end to end on a
/// GreaterOrEqual(8, 8) piece whose every case runs the real multiplier (MulCostPiece above). Lathe is deployed with
/// a mock factory and mock token here, because the real factory does not list MulCostPiece; the circuit work is the
/// real multiplier's. Results: evidence/2026-11-21-gas-16-input-piece.md.
/// Run: forge test --match-path 'test/fork/PieceGas16.fork.t.sol' -vv  (sequential; the public RPC 403s under load)
contract PieceGas16ForkTest is Test {
    uint256 constant FORK_BLOCK = 76_432_018;
    address constant MUL_PROC = 0xbAF50Aa9614B17bA4F81b31455da81a176A9F969; // id 16 = 8x8 multiplier

    function setUp() public {
        vm.createSelectFork("xlayer", FORK_BLOCK);
    }

    function test_fork_mulEval_16inputs() public {
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = IProcessor(MUL_PROC).circuitInfo(16);
        assertEq(nIn, 16);
        assertEq(nOut, 16);
        assertEq(nState, 0);
        assertEq(gates, 652);
        EvalMeter16 m = new EvalMeter16();
        uint16[8] memory xs = [uint16(0), 0x0001, 0x00ff, 0xff00, 0xffff, 0x1234, 0x5a5a, 0x0d0b];
        m.cost(MUL_PROC, 16, hex"0000"); // warm the processor once, as in a batch
        uint256 lo = type(uint256).max;
        uint256 hi;
        uint256 sum;
        for (uint256 i = 0; i < xs.length; ++i) {
            bytes memory input = abi.encodePacked(uint8(xs[i]), uint8(xs[i] >> 8));
            (uint256 used, bytes memory out) = m.cost(MUL_PROC, 16, input);
            // a = input byte 0, b = input byte 1, outputs = a * b, 16 bits LSB first.
            uint256 prod = uint256(uint8(out[0])) | (uint256(uint8(out[1])) << 8);
            assertEq(prod, uint256(uint8(xs[i])) * uint256(uint8(xs[i] >> 8)), "multiplier answer");
            if (used < lo) lo = used;
            if (used > hi) hi = used;
            sum += used;
        }
        console.log("mul eval gas (warm) min", lo);
        console.log("mul eval gas (warm) max", hi);
        console.log("mul eval gas (warm) mean", sum / xs.length);
    }

    /// checkPiece and the payout read the delivered circuit's whole netlist to compare its hash; this is that cost
    /// for the real 652-gate multiplier, first (cold) read and a warm read.
    function test_fork_mulNetlistRead() public view {
        uint256 g = gasleft();
        bytes32 h = keccak256(IProcessor(MUL_PROC).netlist(16));
        uint256 cold = g - gasleft();
        g = gasleft();
        bytes32 h2 = keccak256(IProcessor(MUL_PROC).netlist(16));
        uint256 warm = g - gasleft();
        assertEq(h, h2);
        console.log("netlist bytes", IProcessor(MUL_PROC).netlist(16).length);
        console.log("netlist read + hash, cold", cold);
        console.log("netlist read + hash, warm", warm);
    }

    function test_fork_checkPiece_gasPerCase_16inputs() public {
        address builder = makeAddr("builder");
        address buyer = makeAddr("buyer");
        MockFactory f = new MockFactory();
        MockUSDT usdt = new MockUSDT();
        MulCostPiece piece = new MulCostPiece(MUL_PROC, builder);
        f.setCPU(address(piece), true);
        LatheOrders lathe = new LatheOrders(address(f), address(usdt), makeAddr("feeTo"), 100);
        usdt.mint(buyer, 1e9);
        vm.prank(buyer);
        usdt.approve(address(lathe), type(uint256).max);

        Piece[] memory ps = new Piece[](1);
        ps[0] = Piece(PieceKind.GreaterOrEqual, 16, 1, 8, 8);
        vm.prank(buyer);
        uint256 id = lathe.createPiecedOrder(
            ps, new bytes[](1), 1e6, uint64(block.timestamp + 1 days), builder, new uint32[](1), new bytes32[](0)
        );
        vm.prank(builder);
        lathe.deliverPiece(id, 0, address(piece), 1);
        assertEq(lathe.evalBudget(652), 9_880_000);

        uint256 g = gasleft();
        lathe.checkPiece(id, 0, 1);
        uint256 g1 = g - gasleft();
        g = gasleft();
        lathe.checkPiece(id, 0, 10);
        uint256 g10 = g - gasleft();
        g = gasleft();
        lathe.checkPiece(id, 0, 30);
        uint256 g30 = g - gasleft();
        (,,,,, uint32 next) = lathe.pieceOf(id, 0);
        assertEq(next, 41);
        console.log("checkPiece 1 case (first call, cold)", g1);
        console.log("checkPiece 10 cases (warm)", g10);
        console.log("checkPiece 30 cases (warm)", g30);
        console.log("marginal gas per case (30 - 10) / 20", (g30 - g10) / 20);
    }
}
