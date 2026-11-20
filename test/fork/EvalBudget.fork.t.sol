// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LatheOrders} from "../../src/LatheOrders.sol";
import {IProcessor} from "../../src/ITapeOut.sol";
import {BitLib} from "../../src/BitLib.sol";

interface ITapeoutMint {
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

interface IERC20Fork {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev Calls eval with all the gas it has and reports what one eval cost.
contract EvalMeter {
    function cost(address p, uint256 id, bytes calldata inputs) external view returns (uint256 used, bytes memory out) {
        uint256 g0 = gasleft();
        out = IProcessor(p).eval(id, inputs);
        used = g0 - gasleft();
    }
}

/// @notice The per-case gas budget on real TapeOut circuits (X Layer mainnet fork, block 76,432,018).
/// Real processors are beacon proxies. Before the budget, an out-of-gas inside eval looked like a wrong answer,
/// so anyone could get an honest circuit rejected by calling check with ~400k gas (review finding, Nov 20).
/// Circuits used, all minted on the fork with REF only (REF needs no transistor tokens):
/// - IDENT: 6 inputs -> 16 outputs, one REF to the real 8x8 multiplier (id 16) with b = 1, so output = input.
///   gateCount 652: the REF'd multiplier's gates count (TAP-02 section 6).
/// - BOMB: 6 inputs -> 1 output, logically correct (output = input bit 1), built from REF chains so that one eval
///   costs far more gas per gate than real gates do.
/// Run: forge test --match-path 'test/fork/EvalBudget.fork.t.sol' -vv  (sequential; the public RPC 403s under load)
contract EvalBudgetForkTest is Test {
    uint256 constant FORK_BLOCK = 76_432_018;
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant MUL_PROC = 0xbAF50Aa9614B17bA4F81b31455da81a176A9F969; // id 16 = 8x8 multiplier, 652 gates
    address constant XOR_PROC = 0x839bdD6fa7A66416A609A735e11DE5411B98574e; // id 1 = XOR, 4 gates
    uint96 constant AMOUNT = 10_000_000;

    LatheOrders lathe;
    EvalMeter meter;
    address buyer = makeAddr("buyer");
    address honest = makeAddr("honest");
    address griefer = makeAddr("griefer");
    uint256 identId;
    uint256 bombId;
    uint256 xorChainId; // 64 REFs to XOR in a row: honest, REF-heavy, 256 gates

    function setUp() public {
        vm.createSelectFork("xlayer", FORK_BLOCK);
        lathe = new LatheOrders(FACTORY, USDT0, makeAddr("feeTo"), 100);
        meter = new EvalMeter();
        deal(USDT0, buyer, 100 * uint256(AMOUNT));
        vm.prank(buyer);
        IERC20Fork(USDT0).approve(address(lathe), type(uint256).max);
        vm.deal(honest, 1 ether);

        vm.startPrank(honest);
        // IDENT: a = in0..in5 (signals 2..7), a6 = a7 = 0, b = 1.
        bytes memory ins;
        for (uint256 i = 0; i < 8; ++i) ins = abi.encodePacked(ins, _u24(i < 6 ? 2 + i : 0));
        ins = abi.encodePacked(ins, _u24(1));
        for (uint256 i = 1; i < 8; ++i) ins = abi.encodePacked(ins, _u24(0));
        identId = _mint(MUL_PROC, abi.encodePacked(hex"02", MUL_PROC, uint64(16), uint8(16), uint8(16), ins), 6, 16);

        // BOMB: D0 = XOR; D(k) = one REF to D(k-1), 2 in / 1 out, still XOR, still 4 gates.
        uint256 d = 1;
        for (uint256 k = 0; k < 4; ++k) {
            d = _mint(XOR_PROC, _ref(XOR_PROC, d, 2, 3), 2, 1);
        }
        // Top: r0 = D(in0, in1); r(k) = D(in0, r(k-1)). r(k) = in1 for odd k; 8 REFs -> output = in1.
        bytes memory net;
        for (uint256 k = 0; k < 8; ++k) {
            net = abi.encodePacked(net, _ref(XOR_PROC, d, 2, k == 0 ? 3 : 8 + k - 1));
        }
        bombId = _mint(XOR_PROC, net, 6, 1);

        // XOR chain: 64 REFs straight to XOR id 1, 2 in / 1 out. Used only to measure REF-heavy gas.
        net = "";
        for (uint256 k = 0; k < 64; ++k) {
            net = abi.encodePacked(net, _ref(XOR_PROC, 1, 2, k == 0 ? 3 : 4 + k - 1));
        }
        xorChainId = _mint(MUL_PROC, net, 2, 1);
        vm.stopPrank();
    }

    function _u24(uint256 x) internal pure returns (bytes3) {
        return bytes3(uint24(x));
    }

    function _ref(address cpu, uint256 id, uint256 a, uint256 b) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"02", cpu, uint64(id), uint8(2), uint8(1), _u24(a), _u24(b));
    }

    function _mint(address proc, bytes memory net, uint32 nIn, uint32 nOut) internal returns (uint256) {
        return ITapeoutMint(proc).tapeout{value: ITapeoutMint(proc).TAPEOUT_FEE()}(net, nIn, nOut);
    }

    function _status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function _identTable() internal pure returns (bytes memory t) {
        t = new bytes(128); // 64 cases x 16 bits
        for (uint256 c = 0; c < 64; ++c) t[2 * c] = bytes1(uint8(c));
    }

    function _identOrder() internal returns (uint256 id) {
        vm.prank(buyer);
        id = lathe.createOrder(6, 16, _identTable(), AMOUNT, uint64(block.timestamp + 1 days), address(0), 0);
        vm.prank(honest);
        lathe.deliver(id, MUL_PROC, identId);
    }

    /// gateCount includes the REF'd multiplier's 652 gates, so the budget is sized for the real work.
    function test_fork_gateCountIncludesRefGates() public view {
        (,,, uint32 g) = IProcessor(MUL_PROC).circuitInfo(identId);
        assertEq(g, 652);
        (,,, g) = IProcessor(MUL_PROC).circuitInfo(xorChainId);
        assertEq(g, 64 * 4);
        (,,, g) = IProcessor(XOR_PROC).circuitInfo(bombId);
        assertEq(g, 8 * 4);
    }

    /// The review's attack, now: every gas limit either reverts (nothing recorded) or leaves the order Checking.
    function test_fork_lowGasCheck_revertsNeverRejects() public {
        uint256 id = _identOrder();
        vm.prank(griefer);
        vm.expectRevert(LatheOrders.InsufficientGasForCase.selector);
        lathe.check{gas: 400_000}(id, 1); // the gas that rejected the honest circuit before the fix
        for (uint256 g = 60_000; g < 2_400_000; g += 10_000) {
            vm.prank(griefer);
            (bool ok,) = address(lathe).call{gas: g}(abi.encodeCall(lathe.check, (id, 1)));
            assertFalse(ok, "a single case needs its whole budget");
            assertEq(uint8(_status(id)), uint8(LatheOrders.Status.Checking));
        }
    }

    /// The honest 652-gate REF circuit passes and pays, in batches.
    function test_fork_honestRefCircuitPasses() public {
        uint256 id = _identOrder();
        bool done;
        bool passed;
        for (uint256 i = 0; i < 4 && !done; ++i) {
            (done, passed) = lathe.check(id, 16);
        }
        assertTrue(done && passed);
        assertEq(uint8(_status(id)), uint8(LatheOrders.Status.Paid));
    }

    /// A gas bomb within the buyer's maxGates is rejected at case 0, the same way at any gas the caller sends.
    function test_fork_gasBombRejectedDeterministically() public {
        // It is logically correct: with unlimited gas, output = input bit 1 for every case.
        for (uint256 c = 0; c < 64; c += 21) {
            (, bytes memory out) = meter.cost(XOR_PROC, bombId, BitLib.pack(c, 6));
            assertEq(BitLib.lowBits(out, 1), (c >> 1) & 1);
        }
        (uint256 used,) = meter.cost(XOR_PROC, bombId, BitLib.pack(0, 6));
        uint256 budget = lathe.evalBudget(32);
        console.log("bomb: 32 gates, one eval costs", used, "budget", budget);
        assertGt(used, budget, "the bomb must cost more than its budget");

        bytes memory table = new bytes(8); // output = bit 1 of the case
        for (uint256 c = 0; c < 64; ++c) {
            if ((c >> 1) & 1 == 1) table[c / 8] = bytes1(uint8(table[c / 8]) | uint8(1 << (c % 8)));
        }
        vm.prank(buyer);
        uint256 id = lathe.createOrder(6, 1, table, AMOUNT, uint64(block.timestamp + 1 days), address(0), 32);
        vm.prank(honest);
        lathe.deliver(id, XOR_PROC, bombId);

        uint256 snap = vm.snapshotState();
        uint256[3] memory gases = [budget * 64 / 63 + 300_000, 10 * budget, 150_000_000];
        for (uint256 i = 0; i < 3; ++i) {
            vm.revertToState(snap);
            vm.expectEmit(true, false, false, true);
            emit LatheOrders.Rejected(id, 0);
            (bool done, bool passed) = lathe.check{gas: gases[i]}(id, 64);
            assertTrue(done);
            assertFalse(passed);
            assertEq(uint8(_status(id)), uint8(LatheOrders.Status.Open));
        }
    }

    /// The measurement behind the constants: every honest circuit here costs at most 2/3 of its budget
    /// (a margin of at least 1.5x), measured cold (run with --isolate for first-touch costs).
    function test_fork_budgetMargin() public view {
        _margin("IDENT (1 REF to the 652-gate multiplier)", MUL_PROC, identId, 652, BitLib.pack(63, 6));
        _margin("MUL16 (652 real gates)", MUL_PROC, 16, 652, hex"ffff");
        _margin("XOR (4 gates)", XOR_PROC, 1, 4, hex"03");
        _margin("XOR chain (64 REFs to XOR, 256 gates)", MUL_PROC, xorChainId, 256, hex"03");
    }

    function _margin(string memory name, address p, uint256 id, uint256 gates, bytes memory inp) internal view {
        (uint256 used,) = meter.cost(p, id, inp);
        uint256 budget = lathe.evalBudget(gates);
        console.log(name);
        console.log("   eval gas", used, "budget", budget);
        console.log("   gas per gate", used / gates);
        assertLe(used * 3 / 2, budget, "budget margin below 1.5x");
    }
}
