// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LatheBase} from "./LatheBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";

contract LatheOrdersRefundTest is LatheBase {
    uint256 constant PAR_ID = 2;
    uint64 deadline;

    function setUp() public override {
        super.setUp();
        setCircuitFromTable(PAR_ID, builder, 6, 1, parityTable(), 20);
        deadline = uint64(block.timestamp + 1 days);
    }

    function status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function deliverParity(uint256 id) internal {
        vm.prank(builder);
        lathe.deliver(id, address(proc), PAR_ID);
    }

    function test_refund_beforeDeadline_reverts() public {
        uint256 id = createParity();
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id);
        // exactly at the deadline is still "before": delivery is allowed at now == deadline
        vm.warp(deadline);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id);
    }

    function test_refund_afterDeadline_open_ok() public {
        uint256 id = createParity();
        uint256 before = usdt.balanceOf(buyer);
        vm.warp(deadline + 1);
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Refunded(id, buyer, AMOUNT);
        vm.prank(buyer);
        lathe.refund(id);
        assertEq(usdt.balanceOf(buyer), before + AMOUNT);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Refunded));
    }

    /// Review Focus 3: a check is mid-way at the deadline. The buyer cannot refund during the grace period.
    function test_refund_duringGrace_whileChecking_reverts() public {
        uint256 id = createParity();
        deliverParity(id);
        lathe.check(id, 10);
        vm.warp(deadline + 1);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id);
        vm.warp(deadline + lathe.GRACE()); // last second of grace
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id);
    }

    function test_check_duringGrace_canStillPay() public {
        uint256 id = createParity();
        deliverParity(id);
        lathe.check(id, 10);
        vm.warp(deadline + lathe.GRACE()); // last second of grace
        (bool done, bool passed) = lathe.check(id, 64);
        assertTrue(done && passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    function test_check_afterGrace_reverts() public {
        uint256 id = createParity();
        deliverParity(id);
        vm.warp(deadline + lathe.GRACE() + 1);
        vm.expectRevert(LatheOrders.GraceOver.selector);
        lathe.check(id, 64);
    }

    function test_refund_afterGrace_ok() public {
        uint256 id = createParity();
        deliverParity(id);
        lathe.check(id, 10);
        uint256 before = usdt.balanceOf(buyer);
        vm.warp(deadline + lathe.GRACE() + 1);
        vm.prank(buyer);
        lathe.refund(id);
        assertEq(usdt.balanceOf(buyer), before + AMOUNT);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Refunded));
        (address p,,,,,) = lathe.deliveries(id);
        assertEq(p, address(0));
        vm.expectRevert(LatheOrders.NotChecking.selector);
        lathe.check(id, 64);
    }

    /// A delivery rejected during grace reopens the order after its deadline, so the buyer can refund at once.
    function test_rejectDuringGrace_thenRefundAtOnce() public {
        uint256 id = createParity();
        deliverParity(id);
        proc.setOut(PAR_ID, 40, hex"01"); // parity(40) = 0, so answering 1 is wrong
        vm.warp(deadline + 1);
        (, bool passed) = lathe.check(id, 64);
        assertFalse(passed);
        vm.prank(buyer);
        lathe.refund(id);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Refunded));
        // and no new delivery after the deadline
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotOpen.selector);
        lathe.deliver(id, address(proc), PAR_ID);
    }

    function test_refund_notBuyer_reverts() public {
        uint256 id = createParity();
        vm.warp(deadline + 1);
        vm.prank(stranger);
        vm.expectRevert(LatheOrders.NotBuyer.selector);
        lathe.refund(id);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotBuyer.selector);
        lathe.refund(id);
    }

    function test_refund_twice_reverts() public {
        uint256 id = createParity();
        vm.warp(deadline + 1);
        vm.startPrank(buyer);
        lathe.refund(id);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id);
        vm.stopPrank();
    }

    function test_refund_afterPaid_reverts() public {
        uint256 id = createParity();
        deliverParity(id);
        lathe.check(id, 64);
        vm.warp(deadline + lathe.GRACE() + 1);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id);
    }

    function test_refund_nonexistentOrder_reverts() public {
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.NotBuyer.selector);
        lathe.refund(42);
    }

    /// Hole: USD₮0 is upgradeable and may blacklist. If the builder (or fee recipient) is blacklisted, the payout
    /// reverts and the order stays in Checking. The money must not be stuck: after grace the buyer refunds.
    function test_blacklistedBuilder_payoutReverts_buyerRefundsAfterGrace() public {
        uint256 id = createParity();
        deliverParity(id);
        usdt.setBlacklisted(builder, true);
        vm.expectRevert(bytes("blacklisted"));
        lathe.check(id, 64);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Checking));
        vm.warp(deadline + lathe.GRACE() + 1);
        uint256 before = usdt.balanceOf(buyer);
        vm.prank(buyer);
        lathe.refund(id);
        assertEq(usdt.balanceOf(buyer), before + AMOUNT);
    }

    function test_blacklistedFeeRecipient_payoutReverts_buyerRefundsAfterGrace() public {
        uint256 id = createParity();
        deliverParity(id);
        usdt.setBlacklisted(feeTo, true);
        vm.expectRevert(bytes("blacklisted"));
        lathe.check(id, 64);
        vm.warp(deadline + lathe.GRACE() + 1);
        vm.prank(buyer);
        lathe.refund(id);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Refunded));
    }
}
