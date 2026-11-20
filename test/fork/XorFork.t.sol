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
        vm.prank(circuitOwner);
        lathe.deliver(id, XOR_PROC, XOR_ID);
    }

    function test_fork_factoryKnowsXor() public view {
        assertTrue(IProcessorFactory(FACTORY).isCPU(XOR_PROC));
    }

    function test_fork_xorPasses() public {
        uint256 before = IERC20Like(USDT0).balanceOf(circuitOwner);
        uint256 id = create(hex"06");
        (bool done, bool passed) = lathe.check(id, 4);
        assertTrue(done && passed);
        assertEq(IERC20Like(USDT0).balanceOf(circuitOwner) - before, uint256(AMOUNT) * 9_900 / 10_000);
        assertEq(lathe.feesOwed(), uint256(AMOUNT) / 100);
        lathe.claimFees(); // FIX 2: the fee is pulled, not pushed
        assertEq(IERC20Like(USDT0).balanceOf(feeTo), uint256(AMOUNT) / 100);
    }

    function test_fork_wrongTableFails() public {
        // XNOR table (1,0,0,1) = 0b1001 = 0x09: case 0 is already wrong
        uint256 id = create(hex"09");
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Rejected(id, 0);
        (bool done, bool passed) = lathe.check(id, 4);
        assertTrue(done);
        assertFalse(passed);
        // OR table (0,1,1,1) = 0x0e: only case 3 is wrong
        id = create(hex"0e");
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Rejected(id, 3);
        lathe.check(id, 4);
    }

    /// Gas per case. Run with --isolate so each lathe call is its own transaction (cold storage, as on chain).
    /// Marginal cost of one more case = (check of 3 cases - check of 1 case) / 2, both without payout.
    function test_fork_gasPerCase() public {
        uint256 a = create(hex"06");
        uint256 b = create(hex"06");
        uint256 c = create(hex"06");

        lathe.check(a, 1);
        uint256 one = vm.lastFrameGas().gasTotalUsed;
        lathe.check(b, 3);
        uint256 three = vm.lastFrameGas().gasTotalUsed;
        lathe.check(c, 4);
        uint256 fullPaid = vm.lastFrameGas().gasTotalUsed;

        console.log("check(1 case)            gas:", one);
        console.log("check(3 cases)           gas:", three);
        console.log("check(4 cases + payout)  gas:", fullPaid);
        console.log("marginal gas per case       :", (three - one) / 2);
    }
}

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
