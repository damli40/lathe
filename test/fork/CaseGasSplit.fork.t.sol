// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LatheOrders} from "../../src/LatheOrders.sol";
import {IProcessor} from "../../src/ITapeOut.sol";

interface IERC20G {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ITapeOutG {
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

/// @notice The split-check bug on real TapeOut (X Layer mainnet fork, block 76,480,000), from the final review of
/// 2026-11-21 (evidence/2026-11-21-case-gas-fix.md), and the fix.
/// Circuit: 6 inputs, 1 output, 25 REFs in a chain (10 to the live 4-gate XOR, 13 to the live 1-gate NAND, 2 to
/// the live 2-gate AND): 57 reported gates, formula budget 955,000 per case. Its costliest case run first in a
/// transaction (the REF'd circuits cold) needs about 966,000; later in a transaction (warm) far less.
/// The order's table is the circuit's own answers, so the circuit is right on every case.
/// This repo's forge runs with isolate = true: every external call below is its own transaction, so every check
/// starts cold, as on chain. vm.cool on the two processors makes that explicit.
contract CaseGasSplitFork is Test {
    uint256 constant FORK_BLOCK = 76_480_000;
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant C = 0xB04EB79D1A5EECaabAAfF7B77d7c27578EE693FF; // AND 1, OR 2, NAND 3
    address constant X = 0x839bdD6fa7A66416A609A735e11DE5411B98574e; // XOR 1
    uint96 constant AMOUNT = 10_000_000;
    /// What the builder declares: the costliest cold case (about 966,000 to succeed) x 64/63, plus about 10%.
    uint32 constant DECLARED = 1_080_000;
    LatheOrders lathe;
    address buyer = makeAddr("buyer");
    address bld = makeAddr("bld");
    address griefer = makeAddr("griefer");

    function setUp() public {
        vm.createSelectFork("xlayer", FORK_BLOCK);
        lathe = new LatheOrders(FACTORY, USDT0, makeAddr("feeTo"), 100);
        deal(USDT0, buyer, 1000 * uint256(AMOUNT));
        vm.prank(buyer);
        IERC20G(USDT0).approve(address(lathe), type(uint256).max);
        vm.deal(bld, 100 ether);
    }

    function _ref(address cpu, uint256 id, uint256 a, uint256 b) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"02", cpu, uint64(id), uint8(2), uint8(1), bytes3(uint24(a)), bytes3(uint24(b)));
    }

    /// 6-input chain: r0 = T0(x0, x1), rj = Tj(x[(j+1)%6], r(j-1)). 10 XORs, then 13 NANDs, then 2 ANDs.
    function _mintChain() internal returns (uint256 id) {
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
            uint256 a = j == 0 ? 3 : 2 + ((j + 1) % 6);
            uint256 b = j == 0 ? 2 : 8 + j - 1;
            nl = abi.encodePacked(nl, _ref(cpu, tid, a, b));
        }
        uint256 fee = ITapeOutG(C).TAPEOUT_FEE();
        vm.prank(bld);
        id = ITapeOutG(C).tapeout{value: fee}(nl, 6, 1);
    }

    function _table(uint256 id) internal view returns (bytes memory t) {
        t = new bytes(8);
        for (uint256 c = 0; c < 64; ++c) {
            bytes memory out = IProcessor(C).eval(id, abi.encodePacked(uint8(c)));
            if (uint8(out[0]) & 1 == 1) t[c / 8] = bytes1(uint8(t[c / 8]) | uint8(1 << (c % 8)));
        }
    }

    function _order(uint256 id, bytes memory t, uint32 caseGas) internal returns (uint256 o) {
        vm.prank(buyer);
        o = lathe.createOrder(6, 1, t, AMOUNT, uint64(block.timestamp + 1 days), bld, 0);
        vm.prank(bld);
        if (caseGas == 0) lathe.deliver(o, C, id);
        else lathe.deliver(o, C, id, caseGas);
    }

    function _status(uint256 o) internal view returns (uint8) {
        (,,,,,,,, LatheOrders.Status st) = lathe.orders(o);
        return uint8(st);
    }

    /// One check transaction by a stranger, from a cold start.
    function _check(uint256 o, uint256 n) internal returns (bool done, bool passed) {
        vm.cool(C);
        vm.cool(X);
        vm.prank(griefer);
        return lathe.check(o, n);
    }

    /// The reviewer's reproduction, kept for the old three-argument deliver (the formula budget): order A, checked
    /// in one transaction, pays; order B, the same circuit, is rejected at case 7 when a stranger checks cases
    /// 0..6 and then case 7 alone. This is still how a delivery with too little per-case gas behaves.
    function test_fork_formulaBudget_strangerSplitRejectsHonestCircuit() public {
        uint256 id = _mintChain();
        (,,, uint32 gates) = IProcessor(C).circuitInfo(id);
        assertEq(gates, 57);
        assertEq(lathe.evalBudget(gates), 955_000);
        bytes memory t = _table(id);

        uint256 a = _order(id, t, 0);
        assertEq(_status(a), 1, "batched, not inline");
        (bool done, bool passed) = _check(a, 64);
        assertTrue(done && passed, "order A: one transaction, paid");

        uint256 b = _order(id, t, 0);
        uint256 b0 = IERC20G(USDT0).balanceOf(bld);
        (done,) = _check(b, 7);
        assertFalse(done, "cases 0..6 pass");
        (done, passed) = _check(b, 1);
        assertTrue(done && !passed, "order B: case 7 alone, rejected");
        assertEq(_status(b), 0, "back to Open");
        assertEq(IERC20G(USDT0).balanceOf(bld), b0, "builder not paid");
        console.log("formula budget: order A paid; order B rejected at case 7 by check(7) then check(1)");
    }

    /// The fix: the same circuit delivered with a declared per-case gas pays under the stranger's split, and under
    /// one-case-per-transaction from every starting case.
    function test_fork_declaredCaseGas_everySplitPays() public {
        uint256 id = _mintChain();
        bytes memory t = _table(id);

        uint256 b = _order(id, t, DECLARED);
        assertEq(lathe.caseGasOf(b), DECLARED);
        assertEq(_status(b), 1, "batched");
        uint256 b0 = IERC20G(USDT0).balanceOf(bld);
        _check(b, 7);
        (bool done, bool passed) = _check(b, 1);
        assertFalse(done, "case 7 alone: passes now");
        (done, passed) = _check(b, 64);
        assertTrue(done && passed, "paid");
        assertEq(IERC20G(USDT0).balanceOf(bld) - b0, AMOUNT - AMOUNT / 100);

        uint256 c = _order(id, t, DECLARED);
        for (uint256 k = 0; k < 64; ++k) {
            (done, passed) = _check(c, 1);
            assertTrue(k == 63 ? done && passed : !done, "every case, first in its own transaction, passes");
        }
        console.log("declared 1,080,000: paid under check(7), check(1), check(64) and under 64 single-case checks");
    }
}
