// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece, PieceKind} from "../src/FormulaLib.sol";
import {Wire} from "../src/NetlistLib.sol";
import {MockFactory} from "../test/mocks/MockProcessor.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";
import {FormulaProcessor} from "../test/mocks/FormulaProcessor.sol";

/// @notice LOCAL ANVIL ONLY (chain id 31337): the daily-cap order from examples/daily-cap.json, with both pieces
/// delivered, ready for `scripts/crank.mjs --dry` (evidence/2026-11-21-daily-cap-check-cost.md). Refuses any other
/// chain. Start anvil with `--chain-id 31337` (also when forking X Layer).
/// Deploys MockUSDT, MockFactory, FormulaProcessor (mock circuits, no access control) and LatheOrders, then creates
/// the order exactly as the JSON says and delivers:
///   - piece 0, Add(8, 8): formula circuit 1, reports ADD_GATES gates and burns ADD_GATES x 2,320 gas per case;
///   - piece 1, GreaterOrEqual(8, 9): formula circuit 2, reports GE_GATES gates and burns GE_GATES x 2,320.
/// 2,320 gas per real gate is the X Layer measurement in evidence/2026-11-20-eval-gas-budget.md. The gate counts
/// are estimates for NAND-only circuits (an 8-bit ripple-carry adder of 8 full adders x 9 NANDs = 72; a 9-bit
/// against 8-bit comparator of about 70), not real TapeOut circuits: none exist yet.
/// Env (optional): ADD_GATES (default 72), GE_GATES (default 70).
/// Run: forge script script/LocalDailyCap.s.sol --rpc-url http://127.0.0.1:8545 --unlocked --sender <anvil account> --broadcast
contract LocalDailyCap is Script {
    uint256 constant GAS_PER_GATE = 2_320;

    function run() external {
        require(block.chainid == 31337, "LocalDailyCap: local anvil (31337) only");
        uint32 addGates = uint32(vm.envOr("ADD_GATES", uint256(72)));
        uint32 geGates = uint32(vm.envOr("GE_GATES", uint256(70)));
        LatheOrders.PiecedSpec memory s = dailyCap();
        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        MockUSDT usdt = new MockUSDT();
        MockFactory factory = new MockFactory();
        FormulaProcessor fp = new FormulaProcessor();
        factory.setCPU(address(fp), true);
        LatheOrders lathe = new LatheOrders(address(factory), address(usdt), me, 100);
        fp.setCircuit(1, me, true, 8, 8, addGates);
        fp.setEvalGasCost(1, GAS_PER_GATE * addGates);
        fp.setCircuit(2, me, false, 8, 9, geGates);
        fp.setEvalGasCost(2, GAS_PER_GATE * geGates);
        usdt.mint(me, 10e6);
        usdt.approve(address(lathe), type(uint256).max);
        uint256 id = lathe.createPiecedOrder(s, 1e6, uint64(block.timestamp + 2 days), me);
        lathe.deliverPiece(id, 0, address(fp), 1);
        lathe.deliverPiece(id, 1, address(fp), 2);
        vm.stopBroadcast();

        console2.log("LATHE", address(lathe));
        console2.log("ORDER", id);
        console2.log("NEEDS_TOP", s.needsTop);
    }

    /// examples/daily-cap.json, field by field (the same reading as test/LatheOrders.chain.t.sol).
    function dailyCap() internal view returns (LatheOrders.PiecedSpec memory s) {
        string memory j = vm.readFile("examples/daily-cap.json");
        uint256 np = count(j, ".pieces");
        s.pieces = new Piece[](np);
        s.tables = new bytes[](np);
        s.maxGates = new uint32[](np);
        for (uint256 i = 0; i < np; ++i) {
            string memory p = string.concat(".pieces[", vm.toString(i), "]");
            s.pieces[i] = Piece(
                PieceKind(u(j, p, ".kind")), uint8(u(j, p, ".nIn")), uint8(u(j, p, ".nOut")), uint8(u(j, p, ".widthA")),
                uint8(u(j, p, ".widthB"))
            );
            s.tables[i] = vm.parseJsonBytes(j, string.concat(".tables[", vm.toString(i), "]"));
            s.maxGates[i] = uint32(u(j, string.concat(".maxGates[", vm.toString(i), "]"), ""));
        }
        uint256 nw = count(j, ".wires");
        s.wires = new Wire[](nw);
        for (uint256 i = 0; i < nw; ++i) {
            string memory p = string.concat(".wires[", vm.toString(i), "]");
            s.wires[i] =
                Wire(uint8(u(j, p, ".fromPiece")), uint8(u(j, p, ".fromBit")), uint8(u(j, p, ".toPiece")), uint8(u(j, p, ".toBit")));
        }
        s.labels = new bytes32[](0);
        s.needsTop = vm.parseJsonBool(j, ".needsTop");
    }

    function u(string memory j, string memory p, string memory f) internal pure returns (uint256) {
        return vm.parseJsonUint(j, string.concat(p, f));
    }

    function count(string memory j, string memory p) internal view returns (uint256 n) {
        while (vm.keyExistsJson(j, string.concat(p, "[", vm.toString(n), "]"))) ++n;
    }
}
