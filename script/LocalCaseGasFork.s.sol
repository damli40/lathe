// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {IProcessor} from "../src/ITapeOut.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";

interface ITapeOutS {
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

/// @notice LOCAL ANVIL FORK of X Layer mainnet only (block 76,480,000; see evidence/2026-11-21-case-gas-fix.md).
/// From the final review's reproduction. Deploys LatheOrders on the real TapeOut factory with a mock token, mints
/// the 25-REF chain circuit (57 gates, formula budget 955,000), and creates two identical orders for its own
/// answers: order A delivered with the formula budget (three-argument deliver), order B with a declared per-case
/// gas of 1,080,000. Then send, each as its own transaction: check(A, 7), check(A, 1), check(B, 7), check(B, 1),
/// check(B, 64). A is rejected at case 7 (status 0), B is Paid (status 2). The commands are printed.
/// Refuses to run anywhere but a fork at a block below 76,481,000 on chain 196.
contract LocalCaseGasFork is Script {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant C = 0xB04EB79D1A5EECaabAAfF7B77d7c27578EE693FF;
    address constant X = 0x839bdD6fa7A66416A609A735e11DE5411B98574e;
    uint32 constant DECLARED = 1_080_000;

    function _ref(address cpu, uint256 id, uint256 a, uint256 b) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"02", cpu, uint64(id), uint8(2), uint8(1), bytes3(uint24(a)), bytes3(uint24(b)));
    }

    function run() external {
        require(block.chainid == 196 && block.number < 76_481_000, "local fork of X Layer at block 76,480,000 only");
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
        uint256 fee = ITapeOutS(C).TAPEOUT_FEE();
        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        MockUSDT usdt = new MockUSDT();
        LatheOrders lathe = new LatheOrders(FACTORY, address(usdt), me, 100);
        usdt.mint(me, 100_000_000);
        usdt.approve(address(lathe), type(uint256).max);
        uint256 id = ITapeOutS(C).tapeout{value: fee}(nl, 6, 1);
        vm.stopBroadcast();

        bytes memory t = new bytes(8);
        for (uint256 c = 0; c < 64; ++c) {
            bytes memory out = IProcessor(C).eval(id, abi.encodePacked(uint8(c)));
            if (uint8(out[0]) & 1 == 1) t[c / 8] = bytes1(uint8(t[c / 8]) | uint8(1 << (c % 8)));
        }
        vm.startBroadcast();
        uint256 oa = lathe.createOrder(6, 1, t, 10_000_000, uint64(block.timestamp + 7 days), me, 0);
        uint256 ob = lathe.createOrder(6, 1, t, 10_000_000, uint64(block.timestamp + 7 days), me, 0);
        lathe.deliver{gas: 3_000_000}(oa, C, id);
        lathe.deliver{gas: 3_000_000}(ob, C, id, DECLARED);
        vm.stopBroadcast();
        console2.log("LATHE", address(lathe));
        console2.log("CIRCUIT", id);
        console2.log("ORDER_FORMULA", oa);
        console2.log("ORDER_DECLARED", ob);
        console2.log("then, one transaction each (gas 80,000,000 is ample):");
        console2.log("  cast send $LATHE 'check(uint256,uint256)' <order> 7 ; ... <order> 1 ; ... <order> 64");
    }
}
