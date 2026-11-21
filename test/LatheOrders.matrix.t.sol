// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WiredBase} from "./WiredBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece} from "../src/FormulaLib.sol";
import {Wire} from "../src/NetlistLib.sol";

/// @notice State matrix (from the final review, 2026-11-21, extended for the per-case gas fix): 20 order states x
/// 3 times (before the deadline, in the grace period, after it) x 11 calls (deliver, check, deliverPiece on pieces
/// 0 and 2, checkPiece on pieces 0 and 2, deliverTop, refund by the buyer and by a stranger, and the two new
/// overloads deliver and deliverPiece with a declared caseGas) = 660 cells. After every call, whatever it did or
/// refused: the tokens the contract holds equal the open order's amount (if it is Open or Checking) plus the fees
/// owed, and a stored per-case gas exists exactly when a delivery does (top circuits store none).
contract LatheOrdersMatrixTest is WiredBase {
    // proc ids
    uint256 constant XOR_S = 10; uint256 constant XOR_B = 11; uint256 constant TOG_S = 12; uint256 constant TOG_B = 13;
    uint256 constant OR_S = 20; uint256 constant NAND_S = 21; uint256 constant AND_S = 22;
    uint256 constant OR_B = 30; uint256 constant NAND_B = 31; uint256 constant AND_B = 32;

    function setUp() public override {
        super.setUp();
        setCircuitFromTable(XOR_S, builder, 2, 1, hex"06", SMALL);
        setCircuitFromTable(XOR_B, builder, 2, 1, hex"06", BATCHED_GATES);
        setStatefulCircuitFromTable(TOG_S, builder, 1, 1, 1, hex"3c", SMALL);
        setStatefulCircuitFromTable(TOG_B, builder, 1, 1, 1, hex"3c", BATCHED_GATES);
        setCircuitFromTable(OR_S, builder, 2, 1, hex"0e", SMALL);
        setCircuitFromTable(NAND_S, builder, 2, 1, hex"07", SMALL);
        setCircuitFromTable(AND_S, builder, 2, 1, hex"08", SMALL);
        setCircuitFromTable(OR_B, builder, 2, 1, hex"0e", BATCHED_GATES);
        setCircuitFromTable(NAND_B, builder, 2, 1, hex"07", BATCHED_GATES);
        setCircuitFromTable(AND_B, builder, 2, 1, hex"08", BATCHED_GATES);
    }

    function xorParts() internal pure returns (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) {
        ps = new Piece[](3);
        ps[0] = tablePiece(2, 1); ps[1] = tablePiece(2, 1); ps[2] = tablePiece(2, 1);
        ts = new bytes[](3);
        ts[0] = hex"0e"; ts[1] = hex"07"; ts[2] = hex"08";
        ws = new Wire[](7);
        ws[0] = w(TOP, 0, 0, 0); ws[1] = w(TOP, 1, 0, 1); ws[2] = w(TOP, 0, 1, 0); ws[3] = w(TOP, 1, 1, 1);
        ws[4] = w(0, 0, 2, 0); ws[5] = w(1, 0, 2, 1); ws[6] = w(2, 0, TOP, 0);
    }

    function mk(uint256 s) internal returns (uint256 o, string memory name) {
        if (s < 4 || (s >= 4 && s < 8)) {
            bool mem = s >= 4;
            uint256 k = s % 4;
            vm.prank(buyer);
            o = mem
                ? lathe.createStatefulOrder(1, 1, 1, hex"3c", AMOUNT, deadline, builder, 0)
                : lathe.createOrder(2, 1, hex"06", AMOUNT, deadline, builder, 0);
            name = string.concat(mem ? "MEM " : "TABLE ", k == 0 ? "Open" : k == 1 ? "Checking" : k == 2 ? "Paid" : "Refunded");
            if (k == 1) { vm.prank(builder); lathe.deliver(o, address(proc), mem ? TOG_B : XOR_B); }
            if (k == 2) { vm.prank(builder); lathe.deliver(o, address(proc), mem ? TOG_S : XOR_S); }
            if (k == 3) { vm.warp(deadline + 1); vm.prank(buyer); lathe.refund(o); vm.warp(deadline - 1 days); }
            return (o, name);
        }
        bool top = s >= 14;
        uint256 j = top ? s - 14 : s - 8;
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = xorParts();
        o = createWired(ps, ts, ws, top);
        string[6] memory nm = ["Open-none", "p0-checking", "p0-passed", "p01-passed,p2-checking", "all-passed(Paid for joins)", "Refunded"];
        name = string.concat(top ? "NEEDSTOP " : "JOINS ", nm[j]);
        if (j == 1) deliverP(o, 0, address(proc), OR_B);
        if (j == 2) deliverP(o, 0, address(proc), OR_S);
        if (j == 3) { deliverP(o, 0, address(proc), OR_S); deliverP(o, 1, address(proc), NAND_S); deliverP(o, 2, address(proc), AND_B); }
        if (j == 4) { deliverP(o, 0, address(proc), OR_S); deliverP(o, 1, address(proc), NAND_S); deliverP(o, 2, address(proc), AND_S); }
        if (j == 5) { vm.warp(deadline + 1); vm.prank(buyer); lathe.refund(o); vm.warp(deadline - 1 days); }
    }

    function sel(bytes memory r) internal pure returns (bytes4 x) { if (r.length >= 4) assembly { x := mload(add(r, 32)) } }

    function probe(uint256 o, uint256 f, uint256 topId) internal returns (bool ok, bytes memory r) {
        if (f == 0) { vm.prank(builder); (ok, r) = address(lathe).call(abi.encodeWithSignature("deliver(uint256,address,uint256)", o, address(proc), XOR_S)); }
        if (f == 1) { vm.prank(stranger); (ok, r) = address(lathe).call(abi.encodeCall(lathe.check, (o, 100))); }
        if (f == 2) { vm.prank(builder); (ok, r) = address(lathe).call(abi.encodeWithSignature(DP4, o, 0, address(proc), OR_S)); }
        if (f == 3) { vm.prank(builder); (ok, r) = address(lathe).call(abi.encodeWithSignature(DP4, o, 2, address(proc), AND_S)); }
        if (f == 4) { vm.prank(stranger); (ok, r) = address(lathe).call(abi.encodeCall(lathe.checkPiece, (o, 0, 100))); }
        if (f == 5) { vm.prank(stranger); (ok, r) = address(lathe).call(abi.encodeCall(lathe.checkPiece, (o, 2, 100))); }
        if (f == 6) { vm.prank(builder); (ok, r) = address(lathe).call(abi.encodeCall(lathe.deliverTop, (o, address(rproc), topId))); }
        if (f == 7) { vm.prank(buyer); (ok, r) = address(lathe).call(abi.encodeCall(lathe.refund, (o))); }
        if (f == 8) { vm.prank(stranger); (ok, r) = address(lathe).call(abi.encodeCall(lathe.refund, (o))); }
        // 7.6M x 4 cases > 30M: recorded and checked in batches, not inline.
        if (f == 9) { vm.prank(builder); (ok, r) = address(lathe).call(abi.encodeWithSignature("deliver(uint256,address,uint256,uint32)", o, address(proc), XOR_S, uint32(7_600_000))); }
        if (f == 10) { vm.prank(builder); (ok, r) = address(lathe).call(abi.encodeWithSignature("deliverPiece(uint256,uint256,address,uint256,uint32)", o, 0, address(proc), OR_S, uint32(7_600_000))); }
    }

    string constant DP4 = "deliverPiece(uint256,uint256,address,uint256)";

    /// A stored per-case gas exists exactly when a delivery does, and is never below the formula; a top has none.
    function gasMatchesDelivery(uint256 o) internal view {
        (address p,,, uint32 g,,) = lathe.deliveries(o);
        uint256 cg = lathe.caseGasOf(o);
        if (lathe.piecesOf(o).length == 0) {
            assertEq(cg != 0, p != address(0), "caseGasOf iff delivery");
            if (p != address(0)) assertGe(cg, lathe.evalBudget(g), "caseGas >= formula");
        } else {
            assertEq(cg, 0, "a top stores no per-case gas");
        }
        for (uint256 i = 0; i < lathe.piecesOf(o).length; ++i) {
            (address pp,,, uint32 pg,,) = lathe.pieceOf(o, i);
            uint256 pcg = lathe.pieceCaseGasOf(o, i);
            assertEq(pcg != 0, pp != address(0), "pieceCaseGasOf iff piece delivery");
            if (pp != address(0)) assertGe(pcg, lathe.evalBudget(pg), "piece caseGas >= formula");
        }
    }

    function cell(uint256 o, string memory name, uint256 t, uint256 f, uint256 topId) internal {
        vm.warp(t == 0 ? deadline - 10 : t == 1 ? deadline + 10 : deadline + 1 days + 10);
        probe(o, f, topId);
        uint8 st1 = uint8(status(o));
        assertEq(usdt.balanceOf(address(lathe)), (st1 <= 1 ? AMOUNT : 0) + lathe.feesOwed(), string.concat("accounting: ", name));
        gasMatchesDelivery(o);
    }

    function test_matrix_accountingAndCaseGas() public {
        uint256 cells; // a local: vm.revertTo also rolls back this contract's storage
        for (uint256 s = 0; s < 20; ++s) {
            uint256 snap0 = vm.snapshot();
            (uint256 o, string memory name) = mk(s);
            uint256 topId;
            try lathe.expectedTopNetlist(o) returns (bytes memory nl) { topId = rproc.mint(nl, 2, 1, builder); }
            catch { topId = rproc.mint(hex"00000002000003", 2, 1, builder); }
            for (uint256 t = 0; t < 3; ++t) {
                for (uint256 f = 0; f < 11; ++f) {
                    uint256 snap = vm.snapshot();
                    cell(o, name, t, f, topId);
                    cells++;
                    vm.revertTo(snap);
                }
            }
            vm.revertTo(snap0);
        }
        assertEq(cells, 660);
    }
}
