// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LatheOrders} from "../../src/LatheOrders.sol";
import {IProcessor, IProcessorFactory} from "../../src/ITapeOut.sol";

/// @notice Runs Lathe against the real TapeOut XOR circuit and the real USD₮0 on an X Layer mainnet fork.
/// Fork pinned at block 76,432,018 (2026-11-20) so results repeat and the RPC response is cached locally.
/// Run: forge test --match-path 'test/fork/*' -vv
contract XorForkTest is Test {
    uint256 constant FORK_BLOCK = 76_432_018;
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant XOR_PROC = 0x839bdD6fa7A66416A609A735e11DE5411B98574e;
    uint256 constant XOR_ID = 1;
    uint96 constant AMOUNT = 10_000_000; // 10 USD₮0

    LatheOrders lathe;
    address buyer = makeAddr("buyer");
    address feeTo = makeAddr("feeTo");
    address circuitOwner;

    function setUp() public {
        vm.createSelectFork("xlayer", FORK_BLOCK);
        lathe = new LatheOrders(FACTORY, USDT0, feeTo, 100);
        circuitOwner = IProcessor(XOR_PROC).ownerOf(XOR_ID);
        deal(USDT0, buyer, 100 * uint256(AMOUNT));
        vm.prank(buyer);
        IERC20Like(USDT0).approve(address(lathe), type(uint256).max);
    }

    function create(bytes memory table) internal returns (uint256 id) {
        vm.prank(buyer);
        id = lathe.createOrder(2, 1, table, AMOUNT, uint64(block.timestamp + 1 days), address(0), 0);
    }

    function deliver(uint256 id) internal {
        vm.prank(circuitOwner);
        lathe.deliver(id, XOR_PROC, XOR_ID);
    }

    function status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function test_fork_factoryKnowsXor() public view {
        assertTrue(IProcessorFactory(FACTORY).isCPU(XOR_PROC));
    }

    /// FIX 4: the 4-gate XOR is small (4 cases x evalBudget(4) <= INLINE_CHECK_MAX_GAS), so deliver checks
    /// every case and pays in the same transaction.
    function test_fork_xorPasses() public {
        uint256 before = IERC20Like(USDT0).balanceOf(circuitOwner);
        uint256 id = create(hex"06");
        deliver(id);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        assertEq(IERC20Like(USDT0).balanceOf(circuitOwner) - before, uint256(AMOUNT) * 9_900 / 10_000);
        assertEq(lathe.feesOwed(), uint256(AMOUNT) / 100);
        lathe.claimFees(); // FIX 2: the fee is pulled, not pushed
        assertEq(IERC20Like(USDT0).balanceOf(feeTo), uint256(AMOUNT) / 100);
    }

    /// FIX 4: a wrong table makes the delivery revert at the first wrong case; the order stays Open.
    function test_fork_wrongTableFails() public {
        // XNOR table (1,0,0,1) = 0b1001 = 0x09: case 0 is already wrong
        uint256 id = create(hex"09");
        vm.prank(circuitOwner);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 0));
        lathe.deliver(id, XOR_PROC, XOR_ID);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
        // OR table (0,1,1,1) = 0x0e: only case 3 is wrong
        id = create(hex"0e");
        vm.prank(circuitOwner);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 3));
        lathe.deliver(id, XOR_PROC, XOR_ID);
    }

    /// Gas for a small delivery checked inline: deliver + 4 cases + payout in one call.
    /// Run with --isolate so each lathe call is its own transaction (cold storage, as on chain).
    function test_fork_gasInlineDeliver() public {
        uint256 id = create(hex"06");
        deliver(id);
        uint256 used = vm.lastFrameGas().gasTotalUsed;
        console.log("deliver + 4-case inline check + payout gas:", used);
        console.log("gas limit needed is higher: each case needs evalBudget(4) * 64/63 + reserve available");
        console.log("evalBudget(4):", lathe.evalBudget(4));
    }
}

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
