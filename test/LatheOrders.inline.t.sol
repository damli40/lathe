// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LatheBase} from "./LatheBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";

/// @notice FIX 4: small circuits are checked inside deliver, so a junk delivery can never hold the order.
contract LatheOrdersInlineTest is LatheBase {
    uint256 constant SMALL_XOR = 1; // 4 gates: 4 cases x evalBudget(4) is far under INLINE_CHECK_MAX_GAS
    uint256 constant BIG_XOR = 2; // BATCHED_GATES: batched path

    function setUp() public override {
        super.setUp();
        setCircuitFromTable(SMALL_XOR, builder, 2, 1, xorTable(), 4);
        setCircuitFromTable(BIG_XOR, builder, 2, 1, xorTable(), BATCHED_GATES);
    }

    function status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    /// The fixtures in the other test files rely on BATCHED_GATES taking the batched path.
    function test_fixtures_batchedGatesIsAboveInlineLimit() public view {
        assertGt(4 * lathe.evalBudget(BATCHED_GATES), lathe.INLINE_CHECK_MAX_GAS());
        assertLe(4 * lathe.evalBudget(4), lathe.INLINE_CHECK_MAX_GAS());
    }

    function test_deliver_smallHonest_paysInOneTx() public {
        uint256 id = createXor();
        vm.expectEmit(true, true, false, true);
        emit LatheOrders.Paid(id, builder, address(proc), SMALL_XOR);
        vm.prank(builder);
        lathe.deliver(id, address(proc), SMALL_XOR);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        uint256 fee = uint256(AMOUNT) * FEE_BPS / 10_000;
        assertEq(usdt.balanceOf(builder), AMOUNT - fee);
        assertEq(lathe.feesOwed(), fee);
    }

    function test_deliver_smallJunk_revertsAndOrderStaysOpen() public {
        uint256 id = createXor();
        proc.setOut(SMALL_XOR, 2, hex"00"); // case 2 should be 1
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 2));
        lathe.deliver(id, address(proc), SMALL_XOR);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
        (address p,,,,,) = lathe.deliveries(id);
        assertEq(p, address(0), "no delivery recorded");
        assertEq(usdt.balanceOf(address(lathe)), AMOUNT);
        // an honest delivery is still possible straight after
        proc.setOut(SMALL_XOR, 2, hex"01");
        vm.prank(builder);
        lathe.deliver(id, address(proc), SMALL_XOR);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    /// A small gas bomb cannot occupy the order either: it reverts at case 0.
    function test_deliver_smallGasBomb_reverts() public {
        uint256 id = createXor();
        proc.setBurnGasEval(SMALL_XOR, true);
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 0));
        lathe.deliver(id, address(proc), SMALL_XOR);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
    }

    /// Every gas limit either reverts with nothing recorded, or pays. Some limits hit InsufficientGasForCase.
    function test_deliver_inlineWithTooLittleGas_reverts() public {
        uint256 id = createXor();
        bool sawInsufficient;
        for (uint256 g = 100_000; g < 800_000; g += 5_000) {
            vm.prank(builder);
            (bool ok, bytes memory ret) =
                address(lathe).call{gas: g}(abi.encodeCall(lathe.deliver, (id, address(proc), SMALL_XOR)));
            if (ok) {
                assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
                break;
            }
            assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open), "a failed delivery leaves nothing");
            if (bytes4(ret) == LatheOrders.InsufficientGasForCase.selector) sawInsufficient = true;
        }
        assertTrue(sawInsufficient);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid), "enough gas pays");
    }

    function test_deliver_largeCircuit_usesBatchedCheck() public {
        uint256 id = createXor();
        vm.prank(builder);
        lathe.deliver(id, address(proc), BIG_XOR);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Checking));
        assertEq(usdt.balanceOf(builder), 0);
        (bool done, bool passed) = lathe.check(id, 4);
        assertTrue(done && passed);
    }

    /// The limit is inclusive: cases x budget == limit is inline, one gate more is batched.
    function test_inlineLimit_boundary() public {
        // 4 cases: the largest inline gate count g has 4 * (BASE + PER_GATE * g) <= limit
        uint256 g = (lathe.INLINE_CHECK_MAX_GAS() / 4 - lathe.EVAL_BASE_GAS()) / lathe.EVAL_GAS_PER_GATE();
        proc.setGateCount(SMALL_XOR, uint32(g));
        uint256 a = createXor();
        vm.prank(builder);
        lathe.deliver(a, address(proc), SMALL_XOR);
        assertEq(uint8(status(a)), uint8(LatheOrders.Status.Paid));

        proc.setGateCount(SMALL_XOR, uint32(g + 1));
        uint256 b = createXor();
        vm.prank(builder);
        lathe.deliver(b, address(proc), SMALL_XOR);
        assertEq(uint8(status(b)), uint8(LatheOrders.Status.Checking));
    }
}
