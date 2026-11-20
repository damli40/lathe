// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LatheBase} from "./LatheBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockProcessor} from "./mocks/MockProcessor.sol";
import {BitLib} from "../src/BitLib.sol";
import {TableLib} from "../src/TableLib.sol";

/// @notice Random create / deliver (right or wrong, inline or batched) / check / refund / time / claim calls
/// for the money invariant below. Every order names `builder`. From review 2.
contract MoneyHandler is Test {
    LatheOrders lathe;
    MockUSDT usdt;
    MockProcessor proc;
    address buyer;
    address builder;
    uint256[] public ids;
    uint256 nextCircuit = 100;

    constructor(LatheOrders l, MockUSDT u, MockProcessor p, address b, address bd) {
        lathe = l;
        usdt = u;
        proc = p;
        buyer = b;
        builder = bd;
    }

    function create(uint96 amt, uint8 nIn) external {
        amt = uint96(bound(amt, 1, 1e12));
        nIn = uint8(bound(nIn, 1, 3));
        usdt.mint(buyer, amt);
        uint256 cases = uint256(1) << nIn;
        bytes memory t = new bytes((cases + 7) / 8);
        if (cases < 8) t[0] = bytes1(uint8(1));
        else t[0] = 0x55;
        vm.prank(buyer);
        ids.push(lathe.createOrder(nIn, 1, t, amt, uint64(block.timestamp + 1 days), builder, 0));
    }

    /// `big` = 2,000 gates, so the check is batched; otherwise 5 gates, checked inside deliver.
    function deliver(uint256 i, bool good, bool big) external {
        if (ids.length == 0) return;
        uint256 id = ids[i % ids.length];
        (,,,,, uint8 nIn,,, LatheOrders.Status s) = lathe.orders(id);
        if (s != LatheOrders.Status.Open) return;
        uint256 cid = nextCircuit++;
        uint256 cases = uint256(1) << nIn;
        proc.setCircuit(cid, builder, nIn, 1, 0, big ? 2000 : 5);
        bytes memory t = lathe.tableOf(id);
        bytes[] memory o = new bytes[](cases);
        for (uint256 c; c < cases; ++c) {
            uint256 v = TableLib.expected(t, c, 1);
            if (!good && c == cases - 1) v ^= 1;
            o[c] = BitLib.pack(v, 1);
        }
        proc.setOuts(cid, o);
        vm.prank(builder);
        try lathe.deliver(id, address(proc), cid) {} catch {}
    }

    function check(uint256 i, uint256 n) external {
        if (ids.length == 0) return;
        try lathe.check(ids[i % ids.length], bound(n, 0, 8)) {} catch {}
    }

    function refund(uint256 i) external {
        if (ids.length == 0) return;
        vm.prank(buyer);
        try lathe.refund(ids[i % ids.length]) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }

    function claim() external {
        lathe.claimFees();
    }

    /// Sum of amounts still owed to someone: orders that are Open or Checking.
    function locked() external view returns (uint256 sum) {
        for (uint256 k; k < ids.length; ++k) {
            (,, uint96 amt,,,,,, LatheOrders.Status s) = lathe.orders(ids[k]);
            if (s == LatheOrders.Status.Open || s == LatheOrders.Status.Checking) sum += amt;
        }
    }
}

contract LatheOrdersInvariantTest is LatheBase {
    MoneyHandler h;

    function setUp() public override {
        super.setUp();
        h = new MoneyHandler(lathe, usdt, proc, buyer, builder);
        targetContract(address(h));
    }

    /// The contract never holds more or less than the money still locked in orders plus fees not yet claimed.
    function invariant_balanceEqualsLockedPlusFees() public view {
        assertEq(usdt.balanceOf(address(lathe)), h.locked() + lathe.feesOwed());
    }
}
