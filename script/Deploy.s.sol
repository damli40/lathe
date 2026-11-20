// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LatheOrders} from "../src/LatheOrders.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @notice Mainnet deploy of LatheOrders on X Layer (chain 196).
/// Reads USDT, FEE_RECIPIENT and FEE_BPS from the environment and never prints them.
/// Logs only the deployed address. Dami runs it with his own keystore:
///   forge script script/Deploy.s.sol --rpc-url https://rpc.xlayer.tech --account <name> --broadcast
contract Deploy is Script {
    /// TapeOut processor factory on X Layer mainnet, fixed at deploy.
    address public constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;

    function run() external returns (LatheOrders lathe) {
        require(block.chainid == 196, "Deploy: not X Layer mainnet (196)");

        address usdt = vm.envAddress("USDT");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 feeBps = vm.envUint("FEE_BPS");

        // Cheap checks that catch a wrong env value before money depends on it. The contract is immutable,
        // so a typo here means a redeploy.
        require(FACTORY.code.length > 0, "Deploy: factory has no code");
        require(usdt.code.length > 0, "Deploy: USDT has no code");
        require(IDecimals(usdt).decimals() == 6, "Deploy: USDT decimals != 6");
        require(feeRecipient != address(0), "Deploy: FEE_RECIPIENT is zero");
        require(feeBps <= 500, "Deploy: FEE_BPS above 500");

        vm.startBroadcast();
        lathe = new LatheOrders(FACTORY, usdt, feeRecipient, uint16(feeBps));
        vm.stopBroadcast();

        console2.log("LatheOrders", address(lathe));
    }
}
