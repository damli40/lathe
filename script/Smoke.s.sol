// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Testnet smoke run (chain 1952) against the contracts DeployTestnet made.
/// Env: LATHE, USDT, PROCESSOR, XOR_ID, WRONG_ID; optional REFUND_DELAY (seconds, default 300).
/// The broadcaster must be the deployer (it owns both mock circuits and holds the mUSDT). Every order names the
/// broadcaster as its builder: the contract refuses an order without one (BuilderRequired).
///   (a) 2-input XOR order + deliver the honest circuit. deliver checks small circuits inline, so it pays at once.
///   (b) same order + deliver the wrong circuit. That reverts WrongAnswer(3), and forge does not broadcast a
///       call that reverts, so the order is created on chain and the wrong delivery is SIMULATED here and its
///       revert reason checked. The log prints a cast command that sends it on chain anyway, for a failed tx hash.
///   (c) order with a short deadline; the log prints the exact refund command to run after it passes.
contract Smoke is Script {
    bytes internal constant XOR_TABLE = hex"06"; // cases 0..3 -> 0,1,1,0, LSB first
    uint96 internal constant AMOUNT = 1e6; // 1 mUSDT
    uint256 internal constant DELIVER_GAS = 1_000_000;

    function run() external {
        require(block.chainid == 1952, "Smoke: not X Layer testnet (1952)");
        LatheOrders lathe = LatheOrders(vm.envAddress("LATHE"));
        IERC20 usdt = IERC20(vm.envAddress("USDT"));
        address processor = vm.envAddress("PROCESSOR");
        uint256 xorId = vm.envUint("XOR_ID");
        uint256 wrongId = vm.envUint("WRONG_ID");
        uint256 refundDelay = vm.envOr("REFUND_DELAY", uint256(300));
        require(address(lathe.usdt()) == address(usdt), "Smoke: USDT does not match LATHE.usdt()");

        uint64 deadline = uint64(block.timestamp + 1 days);
        uint64 shortDeadline = uint64(block.timestamp + refundDelay);

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        usdt.approve(address(lathe), 3 * uint256(AMOUNT));

        // (a) honest XOR -> Paid
        uint256 a = lathe.createOrder(2, 1, XOR_TABLE, AMOUNT, deadline, me, 0);
        // Explicit gas: forge sizes a tx from the gas it saw used (x1.3), but deliver must also HOLD each case's
        // eval budget (100,000 + 15,000 per gate, x64/63, + 20,000) before calling eval, and eval uses far less.
        // Without this the sent tx reverts InsufficientGasForCase (seen on the local anvil run).
        lathe.deliver{gas: DELIVER_GAS}(a, processor, xorId);

        // (b) order for the wrong delivery
        uint256 b = lathe.createOrder(2, 1, XOR_TABLE, AMOUNT, deadline, me, 0);

        // (c) short-deadline order for the refund case
        uint256 c = lathe.createOrder(2, 1, XOR_TABLE, AMOUNT, shortDeadline, me, 0);
        vm.stopBroadcast();

        _logStatus("(a) honest XOR, expect Paid(2)", lathe, a);
        require(_status(lathe, a) == LatheOrders.Status.Paid, "Smoke (a): not Paid");

        // (b) simulate the wrong delivery as the circuit owner; never broadcast.
        vm.prank(me);
        try lathe.deliver(b, processor, wrongId) {
            revert("Smoke (b): wrong circuit was accepted");
        } catch (bytes memory err) {
            require(
                keccak256(err) == keccak256(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, uint256(3))),
                "Smoke (b): reverted, but not with WrongAnswer(3)"
            );
            console2.log("(b) wrong circuit: deliver reverts WrongAnswer(3) (simulated, not sent)");
        }
        _logStatus("(b) order stays Open(0)", lathe, b);
        require(_status(lathe, b) == LatheOrders.Status.Open, "Smoke (b): not Open");
        console2.log("    To put the failed delivery on chain (optional), run:");
        console2.log(
            string.concat(
                "    cast send ",
                vm.toString(address(lathe)),
                " 'deliver(uint256,address,uint256)' ",
                vm.toString(b),
                " ",
                vm.toString(processor),
                " ",
                vm.toString(wrongId),
                " --gas-limit 1000000 --rpc-url https://testrpc.xlayer.tech/terigon --account <name>"
            )
        );

        _logStatus("(c) short deadline, expect Open(0) until refund", lathe, c);
        console2.log("    Deadline (unix seconds):", uint256(shortDeadline));
        console2.log("    After that time, run:");
        console2.log(
            string.concat(
                "    cast send ",
                vm.toString(address(lathe)),
                " 'refund(uint256)' ",
                vm.toString(c),
                " --rpc-url https://testrpc.xlayer.tech/terigon --account <name>"
            )
        );
        console2.log("    Then check it shows Refunded(3):");
        console2.log(
            string.concat(
                "    cast call ",
                vm.toString(address(lathe)),
                " 'orders(uint256)(address,address,uint96,uint64,uint32,uint8,uint8,uint8,uint8)' ",
                vm.toString(c),
                " --rpc-url https://testrpc.xlayer.tech/terigon"
            )
        );
    }

    function _status(LatheOrders lathe, uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function _logStatus(string memory label, LatheOrders lathe, uint256 id) internal view {
        console2.log(label);
        console2.log("    order id", id, "status", uint256(_status(lathe, id)));
    }
}
