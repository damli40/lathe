// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LatheBase} from "./LatheBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {TableLib} from "../src/TableLib.sol";

contract TableLibHarness {
    function expected(bytes calldata t, uint256 c, uint256 w) external pure returns (uint256) {
        return TableLib.expected(t, c, w);
    }
}

contract LatheOrdersCreateTest is LatheBase {
    function test_create_pullsUSDT() public {
        uint256 before = usdt.balanceOf(buyer);
        uint256 id = createXor();
        assertEq(id, 1);
        assertEq(usdt.balanceOf(address(lathe)), AMOUNT);
        assertEq(usdt.balanceOf(buyer), before - AMOUNT);
        (address b,, uint96 amount,,, uint8 nIn, uint8 nOut, uint8 nState, LatheOrders.Status s) = lathe.orders(id);
        assertEq(b, buyer);
        assertEq(amount, AMOUNT);
        assertEq(nIn, 2);
        assertEq(nOut, 1);
        assertEq(nState, 0);
        assertEq(uint8(s), uint8(LatheOrders.Status.Open));
        assertEq(lathe.tableOf(id), xorTable());
    }

    function test_create_emitsOrderCreated() public {
        uint64 dl = uint64(block.timestamp + 1 days);
        vm.expectEmit(true, true, false, true);
        emit LatheOrders.OrderCreated(1, buyer, AMOUNT, dl);
        vm.prank(buyer);
        lathe.createOrder(2, 1, xorTable(), AMOUNT, dl, address(0), 0);
    }

    function test_create_rejectsTooManyInputs() public {
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.TooManyCases.selector);
        lathe.createOrder(7, 1, new bytes(16), AMOUNT, uint64(block.timestamp + 1), address(0), 0);
    }

    function test_create_rejectsTooManyOutputs() public {
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.TooManyOutputs.selector);
        lathe.createOrder(1, 17, new bytes(5), AMOUNT, uint64(block.timestamp + 1), address(0), 0);
    }

    /// Hole: nOut 0 means an empty table that every circuit of the right input count would "pass".
    function test_create_rejectsZeroOutputs() public {
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.TooManyOutputs.selector);
        lathe.createOrder(2, 0, "", AMOUNT, uint64(block.timestamp + 1), address(0), 0);
    }

    function test_create_rejectsWrongTableLength() public {
        vm.startPrank(buyer);
        vm.expectRevert(LatheOrders.WrongTableLength.selector);
        lathe.createOrder(2, 1, hex"0600", AMOUNT, uint64(block.timestamp + 1), address(0), 0);
        vm.expectRevert(LatheOrders.WrongTableLength.selector);
        lathe.createOrder(6, 1, new bytes(7), AMOUNT, uint64(block.timestamp + 1), address(0), 0);
        vm.stopPrank();
    }

    /// FIX 3: bits past the last answer must be zero, so one rule has exactly one table (and one hash).
    function test_create_rejectsNonZeroTablePadding() public {
        vm.startPrank(buyer);
        // XOR uses 4 bits; 0xf6 sets the 4 unused high bits
        vm.expectRevert(LatheOrders.TablePaddingNotZero.selector);
        lathe.createOrder(2, 1, hex"f6", AMOUNT, uint64(block.timestamp + 1), address(0), 0);
        // only the top bit set is still padding
        vm.expectRevert(LatheOrders.TablePaddingNotZero.selector);
        lathe.createOrder(2, 1, hex"86", AMOUNT, uint64(block.timestamp + 1), address(0), 0);
        // 2 inputs x 3 outputs = 12 bits: 0xd5 0x01 ok, 0xd5 0x11 has a padding bit
        vm.expectRevert(LatheOrders.TablePaddingNotZero.selector);
        lathe.createOrder(2, 3, hex"d511", AMOUNT, uint64(block.timestamp + 1), address(0), 0);
        lathe.createOrder(2, 1, hex"06", AMOUNT, uint64(block.timestamp + 1), address(0), 0);
        lathe.createOrder(2, 3, hex"d501", AMOUNT, uint64(block.timestamp + 1), address(0), 0);
        // a whole number of bytes has no padding: every bit value is allowed
        lathe.createOrder(6, 1, hex"ffffffffffffffff", AMOUNT, uint64(block.timestamp + 1), address(0), 0);
        vm.stopPrank();
    }

    function test_create_rejectsPastDeadline() public {
        vm.startPrank(buyer);
        vm.expectRevert(LatheOrders.DeadlinePassed.selector);
        lathe.createOrder(2, 1, xorTable(), AMOUNT, uint64(block.timestamp), address(0), 0);
        vm.expectRevert(LatheOrders.DeadlinePassed.selector);
        lathe.createOrder(2, 1, xorTable(), AMOUNT, uint64(block.timestamp - 1), address(0), 0);
        vm.stopPrank();
    }

    function test_create_rejectsZeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.ZeroAmount.selector);
        lathe.createOrder(2, 1, xorTable(), 0, uint64(block.timestamp + 1), address(0), 0);
    }

    function test_constructor_rejectsFeeAbove500() public {
        vm.expectRevert(LatheOrders.FeeTooHigh.selector);
        new LatheOrders(address(factory), address(usdt), feeTo, 501);
        // 500 is the ceiling and is allowed.
        LatheOrders ok = new LatheOrders(address(factory), address(usdt), feeTo, 500);
        assertEq(ok.feeBps(), 500);
    }

    /// Hole: a zero fee recipient would make every payout revert (ERC20 refuses transfers to address 0),
    /// leaving passed orders unpaid. Reject it at deploy.
    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(LatheOrders.ZeroAddress.selector);
        new LatheOrders(address(factory), address(usdt), address(0), 100);
        vm.expectRevert(LatheOrders.ZeroAddress.selector);
        new LatheOrders(address(0), address(usdt), feeTo, 100);
        vm.expectRevert(LatheOrders.ZeroAddress.selector);
        new LatheOrders(address(factory), address(0), feeTo, 100);
    }

    /// Hole: USD₮0 is an upgradeable proxy; if it ever took a cut on transfer, the contract would hold less
    /// than `amount` and the last payout would fail. Reject the order instead of locking a short balance.
    function test_create_rejectsFeeOnTransferToken() public {
        usdt.setTransferFeeBps(10);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.ReceivedLessThanAmount.selector);
        lathe.createOrder(2, 1, xorTable(), AMOUNT, uint64(block.timestamp + 1), address(0), 0);
    }

    function test_expected_xorTable() public {
        TableLibHarness h = new TableLibHarness();
        assertEq(h.expected(hex"06", 0, 1), 0);
        assertEq(h.expected(hex"06", 1, 1), 1);
        assertEq(h.expected(hex"06", 2, 1), 1);
        assertEq(h.expected(hex"06", 3, 1), 0);
    }

    function test_expected_wideAnswers() public {
        TableLibHarness h = new TableLibHarness();
        // w = 3: answers 5, 2, 7 -> bits 101 010 111 LSB first -> 0b111_010_101 = 0x1D5 -> bytes d5 01
        assertEq(h.expected(hex"d501", 0, 3), 5);
        assertEq(h.expected(hex"d501", 1, 3), 2);
        assertEq(h.expected(hex"d501", 2, 3), 7);
    }

    function test_byteLength() public pure {
        assertEq(TableLib.byteLength(4, 1), 1);
        assertEq(TableLib.byteLength(64, 1), 8);
        assertEq(TableLib.byteLength(64, 16), 128);
        assertEq(TableLib.byteLength(3, 3), 2);
    }
}
