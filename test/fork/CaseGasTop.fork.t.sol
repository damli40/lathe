// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {Test, console} from "forge-std/Test.sol";
import {LatheOrders} from "../../src/LatheOrders.sol";
import {IProcessor} from "../../src/ITapeOut.sol";
import {Piece, PieceKind} from "../../src/FormulaLib.sol";
import {Wire, WIRE_TOP} from "../../src/NetlistLib.sol";

interface IERC20Top {
    function approve(address, uint256) external returns (bool);
}

interface ITapeOutTop {
    function tapeout(bytes calldata, uint32, uint32) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

/// @notice A top circuit on real TapeOut whose piece was delivered with a declared per-case gas (ported from the
/// e31f19f review). Piece 0 is a 6-input circuit five link levels deep (REFs into REFs; 57 gates counted, but its
/// cold case costs far more than evalBudget(57)), delivered with caseGas 1,530,000. Every case is then checked
/// alone in its own cold transaction and passes. The top joins it with a 2-input AND; deliverTop pays, and run
/// either refuses or returns the right answer on all 128 inputs (never a wrong one).
contract CaseGasTopFork is Test {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant C = 0xB04EB79D1A5EECaabAAfF7B77d7c27578EE693FF;
    address constant X = 0x839bdD6fa7A66416A609A735e11DE5411B98574e;
    LatheOrders lathe;
    address buyer = makeAddr("buyer");
    address bld = makeAddr("bld");

    function setUp() public {
        vm.createSelectFork("xlayer", 76_480_000);
        lathe = new LatheOrders(FACTORY, USDT0, makeAddr("feeTo"), 100);
        deal(USDT0, buyer, 1e12);
        vm.prank(buyer);
        IERC20Top(USDT0).approve(address(lathe), type(uint256).max);
        vm.deal(bld, 100 ether);
    }

    function _ref2(address cpu, uint256 id, uint256 a, uint256 b) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"02", cpu, uint64(id), uint8(2), uint8(1), bytes3(uint24(a)), bytes3(uint24(b)));
    }

    function _ref6(address cpu, uint256 id) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"02",
            cpu,
            uint64(id),
            uint8(6),
            uint8(1),
            bytes3(uint24(2)),
            bytes3(uint24(3)),
            bytes3(uint24(4)),
            bytes3(uint24(5)),
            bytes3(uint24(6)),
            bytes3(uint24(7))
        );
    }

    function _mint(bytes memory nl, uint32 nIn) internal returns (uint256) {
        uint256 fee = ITapeOutTop(C).TAPEOUT_FEE();
        vm.prank(bld);
        return ITapeOutTop(C).tapeout{value: fee}(nl, nIn, 1);
    }

    function _deep() internal returns (uint256 d) {
        bytes memory nl;
        for (uint256 j = 0; j < 25; ++j) {
            address cpu = C;
            uint256 tid;
            if (j < 10) {
                cpu = X;
                tid = 1;
            } else if (j < 23) {
                tid = 3;
            } else {
                tid = 1;
            }
            uint256 a = j == 0 ? 2 : 2 + ((j + 1) % 6);
            uint256 b = j == 0 ? 3 : 8 + j - 1;
            nl = abi.encodePacked(nl, _ref2(cpu, tid, a, b));
        }
        d = _mint(nl, 6);
        for (uint256 k = 0; k < 5; ++k) {
            d = _mint(_ref6(C, d), 6);
        }
    }

    function _spec(bytes memory t) internal pure returns (LatheOrders.PiecedSpec memory s) {
        s.pieces = new Piece[](2);
        s.pieces[0] = Piece(PieceKind.Table, 6, 1, 0, 0);
        s.pieces[1] = Piece(PieceKind.Table, 2, 1, 0, 0);
        s.tables = new bytes[](2);
        s.tables[0] = t;
        s.tables[1] = hex"08";
        s.maxGates = new uint32[](2);
        s.labels = new bytes32[](0);
        s.wires = new Wire[](9);
        for (uint8 k = 0; k < 6; ++k) {
            s.wires[k] = Wire(WIRE_TOP, k, 0, k);
        }
        s.wires[6] = Wire(0, 0, 1, 0);
        s.wires[7] = Wire(WIRE_TOP, 6, 1, 1);
        s.wires[8] = Wire(1, 0, WIRE_TOP, 0);
        s.needsTop = true;
    }

    function _runAll(uint256 o, uint256 d) internal {
        uint256 refused;
        for (uint256 x = 0; x < 128; ++x) {
            vm.cool(C);
            vm.cool(X);
            (bool ok, bytes memory ret) =
                address(lathe).staticcall{gas: 10_000_000}(abi.encodeCall(lathe.run, (o, abi.encodePacked(uint8(x)))));
            if (!ok) {
                refused++;
                continue;
            }
            bytes memory out = abi.decode(ret, (bytes));
            bytes memory p0 = IProcessor(C).eval(d, abi.encodePacked(uint8(x & 63)));
            uint8 want = (uint8(p0[0]) & 1) & uint8(x >> 6);
            assertEq(uint8(out[0]) & 1, want, "top answer");
        }
        console.log("run refused on", refused, "of 128 inputs");
    }

    function test_top_pieceWithDeclaredGas_paysAndRuns() public {
        uint256 d = _deep();
        bytes memory t = new bytes(8);
        for (uint256 c = 0; c < 64; ++c) {
            bytes memory out = IProcessor(C).eval(d, abi.encodePacked(uint8(c)));
            if (uint8(out[0]) & 1 == 1) t[c / 8] = bytes1(uint8(t[c / 8]) | uint8(1 << (c % 8)));
        }
        LatheOrders.PiecedSpec memory s = _spec(t);
        vm.prank(buyer);
        uint256 o = lathe.createPiecedOrder(s, 10_000_000, uint64(block.timestamp + 1 days), bld);
        vm.prank(bld);
        lathe.deliverPiece(o, 0, C, d, 1_530_000);
        uint256 andId = _mint(_ref2(C, 1, 2, 3), 2);
        vm.prank(bld);
        lathe.deliverPiece(o, 1, C, andId);
        for (uint256 k = 0; k < 64; ++k) {
            vm.cool(C);
            vm.cool(X);
            vm.prank(makeAddr("s"));
            (bool done,) = lathe.checkPiece{gas: 30_000_000}(o, 0, 1);
            if (k < 63) assertFalse(done);
        }
        (,,,,, uint32 nc) = lathe.pieceOf(o, 0);
        assertEq(nc, 64, "piece 0 passed under 64 single-case checks");
        bytes memory nl = lathe.expectedTopNetlist(o);
        uint256 top = _mint(nl, 7);
        vm.prank(bld);
        lathe.deliverTop(o, C, top);
        (,,,,,,,, LatheOrders.Status st) = lathe.orders(o);
        assertEq(uint8(st), 2);
        (,,, uint32 tg,,) = lathe.deliveries(o);
        console.log("top gates", tg, "piece formula", lathe.evalBudget(57));
        _runAll(o, d);
    }
}
