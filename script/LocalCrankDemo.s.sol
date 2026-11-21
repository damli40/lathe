// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece, PieceKind} from "../src/FormulaLib.sol";
import {MockFactory} from "../test/mocks/MockProcessor.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";
import {FormulaProcessor} from "../test/mocks/FormulaProcessor.sol";

/// @notice LOCAL ANVIL ONLY (chain id 31337): sets up two 16-input pieced orders for trying scripts/crank.mjs.
/// It refuses any other chain. Start anvil with `--chain-id 31337` (also when forking X Layer).
/// Deploys MockUSDT, MockFactory, FormulaProcessor (mock circuits, no access control) and LatheOrders, then:
///   - order A: one GreaterOrEqual(8, 8) piece (16 inputs, 65,536 cases), delivered with circuit 1, which answers
///     correctly, reports 70 gates (budget 1,150,000 gas per case) and burns about 162,000 gas per case
///     (70 gates x ~2,320 gas per real gate, evidence/2026-11-20-eval-gas-budget.md);
///   - order B: the same piece delivered with circuit 2, which answers case 300 wrong, so the crank must stop
///     with Rejected.
/// The sender is buyer, builder and circuit owner. Run:
///   forge script script/LocalCrankDemo.s.sol --rpc-url http://127.0.0.1:8545 --unlocked --sender <anvil account> --broadcast
contract LocalCrankDemo is Script {
    function run() external {
        require(block.chainid == 31337, "LocalCrankDemo: local anvil (31337) only");
        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        MockUSDT usdt = new MockUSDT();
        MockFactory factory = new MockFactory();
        FormulaProcessor fp = new FormulaProcessor();
        factory.setCPU(address(fp), true);
        LatheOrders lathe = new LatheOrders(address(factory), address(usdt), me, 100);
        fp.setCircuit(1, me, false, 8, 8, 70);
        fp.setEvalGasCost(1, 162_000);
        fp.setCircuit(2, me, false, 8, 8, 70);
        fp.setEvalGasCost(2, 162_000);
        fp.setWrongAt(2, 300);
        usdt.mint(me, 10e6);
        usdt.approve(address(lathe), type(uint256).max);

        Piece[] memory ps = new Piece[](1);
        ps[0] = Piece(PieceKind.GreaterOrEqual, 16, 1, 8, 8);
        uint64 deadline = uint64(block.timestamp + 2 days);
        uint256 a = lathe.createPiecedOrder(ps, new bytes[](1), 1e6, deadline, me, new uint32[](1), new bytes32[](0));
        lathe.deliverPiece(a, 0, address(fp), 1);
        uint256 b = lathe.createPiecedOrder(ps, new bytes[](1), 1e6, deadline, me, new uint32[](1), new bytes32[](0));
        lathe.deliverPiece(b, 0, address(fp), 2);
        vm.stopBroadcast();

        console2.log("LATHE", address(lathe));
        console2.log("ORDER_OK", a);
        console2.log("ORDER_WRONG", b);
    }
}
