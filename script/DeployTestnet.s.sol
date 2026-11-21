// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {MockFactory, MockProcessor} from "../test/mocks/MockProcessor.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";
import {FormulaProcessor} from "../test/mocks/FormulaProcessor.sol";

/// @notice X Layer TESTNET (chain 1952) deploy. TapeOut and USDT do not exist on testnet
/// (evidence/2026-11-20-preflight.md, section 5), so this deploys stand-ins:
///   - MockUSDT (6 decimals, anyone can mint), 1,000 mUSDT minted to the deployer;
///   - MockFactory + MockProcessor, with two circuits owned by the deployer:
///       circuit 1 = honest 2-input XOR (answers 0,1,1,0), 4 gates;
///       circuit 2 = deliberately wrong (answers 0,1,1,1, i.e. OR), 4 gates;
///       circuit 3 = honest toggle with one memory bit: 1 input, 1 output, 1 memory bit, 4 gates. Case c has
///         x0 = c & 1 and memory s = c >> 1; new memory = s XOR x0, output = new memory (table 0x3c);
///       circuit 4 = the same toggle, wrong in case 3 only (x0 = 1, s = 1: new memory 1 instead of 0);
///   - FormulaProcessor (mock circuits that compute a + b or a >= b, test/mocks/FormulaProcessor.sol), registered with
///     the mock factory, with four circuits owned by the deployer, all 4 gates (budget 160,000 gas per case), for
///     pieced orders (a and b are read LSB first: a = the low widthA input bits, b = the next widthB bits):
///       formula circuit 1 = Add(2, 2): 4 inputs, 3 outputs (a + b);
///       formula circuit 2 = GreaterOrEqual(3, 2): 5 inputs, 1 output (a >= b);
///       formula circuit 3 = the same GreaterOrEqual(3, 2), wrong in case 5 only (a = 5, b = 0: answers 0);
///       formula circuit 4 = GreaterOrEqual(6, 6): 12 inputs, 4,096 cases, too many to check inside one delivery,
///         so it is checked with scripts/crank.mjs (Smoke.s.sol prints the command);
///   - LatheOrders pointing at the mock factory and MockUSDT, fee 1% to the deployer. forge first deploys
///     LatheOrders' two linked libraries, LatheChecks and LatheReads (see DEPLOY.md).
/// This proves the order contract's own logic only. Real TapeOut circuits are proven by the fork tests.
/// The mocks reuse test/mocks so there is one copy of them. Their setters have no access control: fine for a
/// throwaway testnet, never for mainnet. Logs only the deployed addresses.
contract DeployTestnet is Script {
    uint256 public constant XOR_ID = 1;
    uint256 public constant WRONG_ID = 2;
    uint256 public constant TOGGLE_ID = 3;
    uint256 public constant WRONG_TOGGLE_ID = 4;
    uint256 public constant ADD22_ID = 1; // on the FormulaProcessor
    uint256 public constant GE32_ID = 2;
    uint256 public constant GE32_WRONG_ID = 3;
    uint256 public constant GE66_ID = 4;
    uint256 public constant GE32_WRONG_CASE = 5;
    uint32 public constant FORMULA_GATES = 4;
    uint16 public constant TESTNET_FEE_BPS = 100;
    uint256 public constant MINT = 1_000e6;

    function run() external {
        require(block.chainid == 1952, "DeployTestnet: not X Layer testnet (1952)");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        MockUSDT usdt = new MockUSDT();
        MockFactory factory = new MockFactory();
        MockProcessor processor = new MockProcessor();
        factory.setCPU(address(processor), true);

        bytes[] memory xorOuts = new bytes[](4);
        xorOuts[0] = hex"00";
        xorOuts[1] = hex"01";
        xorOuts[2] = hex"01";
        xorOuts[3] = hex"00";
        processor.setCircuit(XOR_ID, deployer, 2, 1, 0, 4);
        processor.setOuts(XOR_ID, xorOuts);

        bytes[] memory wrongOuts = new bytes[](4);
        wrongOuts[0] = hex"00";
        wrongOuts[1] = hex"01";
        wrongOuts[2] = hex"01";
        wrongOuts[3] = hex"01"; // case 3 (1 XOR 1) should be 0
        processor.setCircuit(WRONG_ID, deployer, 2, 1, 0, 4);
        processor.setOuts(WRONG_ID, wrongOuts);

        // step answers: outputs and new memory per case c = x0 + 2*s
        bytes[] memory tog = new bytes[](4);
        tog[0] = hex"00";
        tog[1] = hex"01";
        tog[2] = hex"01";
        tog[3] = hex"00";
        processor.setCircuit(TOGGLE_ID, deployer, 1, 1, 1, 4);
        processor.setOuts(TOGGLE_ID, tog);
        processor.setNewStates(TOGGLE_ID, tog);

        bytes[] memory wrongState = new bytes[](4);
        wrongState[0] = hex"00";
        wrongState[1] = hex"01";
        wrongState[2] = hex"01";
        wrongState[3] = hex"01"; // case 3: memory 1 flipped by x0 = 1 should be 0
        processor.setCircuit(WRONG_TOGGLE_ID, deployer, 1, 1, 1, 4);
        processor.setOuts(WRONG_TOGGLE_ID, tog);
        processor.setNewStates(WRONG_TOGGLE_ID, wrongState);

        FormulaProcessor formula = new FormulaProcessor();
        factory.setCPU(address(formula), true);
        formula.setCircuit(ADD22_ID, deployer, true, 2, 2, FORMULA_GATES);
        formula.setCircuit(GE32_ID, deployer, false, 3, 2, FORMULA_GATES);
        formula.setCircuit(GE32_WRONG_ID, deployer, false, 3, 2, FORMULA_GATES);
        formula.setWrongAt(GE32_WRONG_ID, GE32_WRONG_CASE);
        formula.setCircuit(GE66_ID, deployer, false, 6, 6, FORMULA_GATES);

        LatheOrders lathe = new LatheOrders(address(factory), address(usdt), deployer, TESTNET_FEE_BPS);
        usdt.mint(deployer, MINT);
        vm.stopBroadcast();

        console2.log("LATHE", address(lathe));
        console2.log("USDT", address(usdt));
        console2.log("FACTORY", address(factory));
        console2.log("PROCESSOR", address(processor));
        console2.log("XOR_ID", XOR_ID);
        console2.log("WRONG_ID", WRONG_ID);
        console2.log("TOGGLE_ID", TOGGLE_ID);
        console2.log("WRONG_TOGGLE_ID", WRONG_TOGGLE_ID);
        console2.log("FORMULA_PROCESSOR", address(formula));
        console2.log("ADD22_ID", ADD22_ID);
        console2.log("GE32_ID", GE32_ID);
        console2.log("GE32_WRONG_ID", GE32_WRONG_ID);
        console2.log("GE66_ID", GE66_ID);
    }
}
