// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {WiredBase} from "./WiredBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece} from "../src/FormulaLib.sol";
import {Wire} from "../src/NetlistLib.sol";

/// @notice Caller-gas sweeps over the declared per-case gas (ported from the e31f19f review). Each test sends a
/// range of gas amounts around the per-case hold (caseGas x 64/63) and asserts that too little gas only ever
/// reverts with no state change, never a rejection of an honest circuit, and that enough gas gives the right answer.
contract LatheOrdersCaseGasSweepTest is WiredBase {
    uint256 constant H = 70;

    function setUp() public override {
        super.setUp();
        setCircuitFromTable(H, builder, 6, 1, parityTable(), 1);
    }

    function _st(uint256 o) internal view returns (uint8) {
        (,,,,,,,, LatheOrders.Status s) = lathe.orders(o);
        return uint8(s);
    }

    function _next(uint256 o) internal view returns (uint32 n) {
        (,,,,, n) = lathe.deliveries(o);
    }

    /// Batched check(o, 1): caller gas swept around the hold; passes advance the cursor, reverts change nothing.
    function test_sweep_check_declared() public {
        uint32 D = 3_000_000;
        proc.setEvalGasCost(H, 2_950_000);
        uint256 o = createParity();
        vm.prank(builder);
        lathe.deliver(o, address(proc), H, D);
        assertEq(_st(o), 1);
        uint256 hold = uint256(D) * 64 / 63;
        uint256 passes;
        uint256 reverts;
        for (uint256 g = hold - 150_000; g < hold + 250_000; g += 997) {
            uint256 snap = vm.snapshotState();
            vm.prank(stranger);
            (bool ok,) = address(lathe).call{gas: g}(abi.encodeCall(lathe.check, (o, 1)));
            if (ok) {
                passes++;
                assertEq(_st(o), 1, "still checking");
                assertEq(_next(o), 1, "advanced");
            } else {
                reverts++;
                assertEq(_next(o), 0);
                assertEq(_st(o), 1);
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("passes", passes);
        emit log_named_uint("reverts", reverts);
        assertGt(passes, 0);
        assertGt(reverts, 0);
    }

    /// Inline deliver: delivery gas swept; the only outcomes are a revert (no state) or Paid, never Checking.
    function test_sweep_deliver_inline_declared() public {
        uint32 D = 460_000; // 64 x 460k = 29.44M <= 30M: inline
        proc.setEvalGasCost(H, 440_000);
        uint256 o = createParity();
        // Least it can need: 63 cases burn 440,000 each, the last one must find its full hold (D x 64/63) left.
        uint256 need = 63 * 440_000 + uint256(D) * 64 / 63;
        uint256 passes;
        uint256 reverts;
        for (uint256 g = need - 1_200_000; g < need + 1_800_000; g += 149_993) {
            uint256 snap = vm.snapshotState();
            vm.prank(builder);
            (bool ok,) = address(lathe).call{gas: g}(
                abi.encodeWithSignature("deliver(uint256,address,uint256,uint32)", o, address(proc), H, D)
            );
            if (ok) {
                passes++;
                assertEq(_st(o), 2, "paid");
            } else {
                reverts++;
                assertEq(_st(o), 0);
                assertEq(lathe.caseGasOf(o), 0);
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("passes", passes);
        emit log_named_uint("reverts", reverts);
        assertGt(passes, 0);
        assertGt(reverts, 0);
    }

    /// run on a paid order: caller gas swept; the result is the right answer or a refusal, never a wrong answer.
    function test_sweep_run_declared() public {
        uint32 D = 3_000_000;
        proc.setEvalGasCost(H, 10);
        uint256 o = createParity();
        vm.prank(builder);
        lathe.deliver(o, address(proc), H, D);
        vm.prank(stranger);
        lathe.check{gas: 250_000_000}(o, 64);
        assertEq(_st(o), 2);
        proc.setEvalGasCost(H, 2_950_000);
        uint256 hold = uint256(D) * 64 / 63;
        uint256 rights;
        uint256 refusals;
        uint256 other;
        for (uint256 g = hold - 100_000; g < hold + 600_000; g += 3_331) {
            (bool ok, bytes memory ret) = address(lathe).staticcall{gas: g}(abi.encodeCall(lathe.run, (o, hex"07")));
            if (ok) {
                bytes memory out = abi.decode(ret, (bytes));
                assertEq(uint8(out[0]), 1, "parity(7)=1");
                rights++;
            } else if (ret.length >= 4 && bytes4(ret) == LatheOrders.InsufficientGasForCase.selector) {
                refusals++;
            } else {
                other++;
            }
        }
        emit log_named_uint("right", rights);
        emit log_named_uint("InsufficientGasForCase", refusals);
        emit log_named_uint("other revert (OOG in the hop)", other);
        assertGt(rights, 0);
    }
}

contract LatheOrdersCaseGasSweepPieceTest is WiredBase {
    /// checkPiece(o, 0, 1): caller gas swept around the hold; the piece is never rejected.
    function test_sweep_checkPiece_declared() public {
        uint256 H = 71;
        setCircuitFromTable(H, builder, 6, 1, parityTable(), 1);
        proc.setEvalGasCost(H, 10);
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(6, 1);
        bytes[] memory ts = new bytes[](1);
        ts[0] = parityTable();
        Wire[] memory ws = new Wire[](7);
        for (uint8 j = 0; j < 6; ++j) {
            ws[j] = w(TOP, j, 0, j);
        }
        ws[6] = w(0, 0, TOP, 0);
        uint256 o = createWired(ps, ts, ws, false);
        vm.prank(builder);
        lathe.deliverPiece(o, 0, address(proc), H, 3_000_000);
        proc.setEvalGasCost(H, 2_950_000);
        uint256 hold = uint256(3_000_000) * 64 / 63;
        uint256 passes;
        uint256 reverts;
        for (uint256 g = hold - 150_000; g < hold + 250_000; g += 997) {
            uint256 snap = vm.snapshotState();
            vm.prank(stranger);
            (bool ok,) = address(lathe).call{gas: g}(abi.encodeCall(lathe.checkPiece, (o, 0, 1)));
            (address p,,,,, uint32 nc) = lathe.pieceOf(o, 0);
            assertTrue(p != address(0), "never rejected");
            if (ok) {
                passes++;
                assertEq(nc, 1);
            } else {
                reverts++;
                assertEq(nc, 0);
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("passes", passes);
        emit log_named_uint("reverts", reverts);
        assertGt(passes, 0);
        assertGt(reverts, 0);
    }
}
