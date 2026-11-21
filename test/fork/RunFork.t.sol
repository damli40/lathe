// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LatheOrders} from "../../src/LatheOrders.sol";
import {IProcessor} from "../../src/ITapeOut.sol";

interface IERC20Run {
    function approve(address, uint256) external returns (bool);
}

/// @notice run on real TapeOut circuits (X Layer mainnet fork, block 76,432,018), and a real circuit whose truth
/// table changes when two inputs are swapped, so a mix-up of input order would show.
/// XOR (the only circuit delivered before this) is symmetric and cannot reveal swapped inputs.
/// MUX: processor 0xca6f...7340 id 3, 3 inputs, 1 output, 0 memory, 4 gates, found by a slow sequential scan of
/// circuitInfo + eval on processors cpus(0..) (2026-11-21). Its table is [0,1,0,1,0,0,1,1]: output = x2 ? x1 : x0.
/// Packed LSB first: cases 1, 3, 6, 7 are 1 = 0b11001010 = 0xca. With x0 and x1 swapped it is [0,0,1,1,0,1,0,1] =
/// 0xac, which first differs at case 1 (x0 = 1, x1 = 0, x2 = 0).
/// Run: forge test --match-path 'test/fork/RunFork.t.sol' -vv  (sequential; the public RPC 403s under load)
contract RunForkTest is Test {
    uint256 constant FORK_BLOCK = 76_432_018;
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant XOR_PROC = 0x839bdD6fa7A66416A609A735e11DE5411B98574e;
    address constant MUX_PROC = 0xCa6Fa40e0b548aBa9132F3f5050eE4C4c5eB7340;
    uint256 constant MUX_ID = 3;
    uint96 constant AMOUNT = 10_000_000;

    LatheOrders lathe;
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork("xlayer", FORK_BLOCK);
        lathe = new LatheOrders(FACTORY, USDT0, makeAddr("feeTo"), 100);
        deal(USDT0, buyer, 100 * uint256(AMOUNT));
        vm.prank(buyer);
        IERC20Run(USDT0).approve(address(lathe), type(uint256).max);
    }

    function order(uint8 nIn, bytes memory table, address builder) internal returns (uint256 id) {
        vm.prank(buyer);
        id = lathe.createOrder(nIn, 1, table, AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
    }

    function test_run_matchesEval() public {
        address owner = IProcessor(XOR_PROC).ownerOf(1);
        uint256 id = order(2, hex"06", owner);
        vm.prank(owner);
        lathe.deliver(id, XOR_PROC, 1);
        for (uint8 x = 0; x < 4; ++x) {
            bytes memory inp = abi.encodePacked(x);
            assertEq(lathe.run(id, inp), IProcessor(XOR_PROC).eval(1, inp));
        }
        (address p, uint256 c) = lathe.ruleOf(id);
        assertEq(p, XOR_PROC);
        assertEq(c, 1);
    }

    function test_fork_muxShape() public view {
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = IProcessor(MUX_PROC).circuitInfo(MUX_ID);
        assertEq(nIn, 3);
        assertEq(nOut, 1);
        assertEq(nState, 0);
        assertEq(gates, 4);
    }

    /// The right table pays; the same table with x0 and x1 swapped is refused at case 1.
    function test_fork_muxInputOrderMatters() public {
        address owner = IProcessor(MUX_PROC).ownerOf(MUX_ID);
        uint256 swapped = order(3, hex"ac", owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 1));
        lathe.deliver(swapped, MUX_PROC, MUX_ID);

        uint256 id = order(3, hex"ca", owner);
        vm.prank(owner);
        lathe.deliver(id, MUX_PROC, MUX_ID);
        (,,,,,,,, LatheOrders.Status s) = lathe.orders(id);
        assertEq(uint8(s), uint8(LatheOrders.Status.Paid));
        // run answers what the circuit answers, case by case, and case 1 vs case 2 differ
        for (uint8 x = 0; x < 8; ++x) {
            bytes memory inp = abi.encodePacked(x);
            assertEq(lathe.run(id, inp), IProcessor(MUX_PROC).eval(MUX_ID, inp));
        }
        assertEq(lathe.run(id, hex"01"), hex"01", "x0 = 1, x2 = 0 picks x0");
        assertEq(lathe.run(id, hex"02"), hex"00", "x1 = 1, x2 = 0 picks x0 = 0");
    }
}
