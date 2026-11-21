// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Piece, PieceKind} from "../src/FormulaLib.sol";
import {Wire, WIRE_TOP} from "../src/NetlistLib.sol";
import {RefProcessor} from "../test/mocks/RefProcessor.sol";
import {MockProcessor} from "../test/mocks/MockProcessor.sol";

/// @notice Testnet smoke run (chain 1952) against the contracts DeployTestnet made.
/// Env: LATHE, USDT, PROCESSOR, XOR_ID, WRONG_ID, FORMULA_PROCESSOR, REF_PROCESSOR; optional TOGGLE_ID (default 3),
/// WRONG_TOGGLE_ID (default 4), ADD22_ID (1), GE32_ID (2), GE32_WRONG_ID (3), GE66_ID (4), GE23_ID (5),
/// REFUND_DELAY (seconds, default 900: on a slow public RPC the script takes several minutes to simulate before it sends, and a 300 s deadline had already passed when the order was sent).
/// The broadcaster must be the deployer (it owns the mock circuits and holds the mUSDT). Every order names the
/// broadcaster as its builder: the contract refuses an order without one (BuilderRequired).
///   (a) 2-input XOR order + deliver the honest circuit. deliver checks small circuits inline, so it pays at once.
///   (b) same order + deliver the wrong circuit. That reverts WrongAnswer(3), and forge does not broadcast a
///       call that reverts, so the order is created on chain and the wrong delivery is SIMULATED here and its
///       revert reason checked. The log prints a cast command that sends it on chain anyway, for a failed tx hash.
///   (c) order with a short deadline; the log prints the exact refund command to run after it passes.
///   (d) memory order (1 input, 1 output, 1 memory bit) with input names "flip" and "mem" + deliver the honest
///       toggle circuit: Paid inside the delivery.
///   (e) a second memory order + the wrong toggle (wrong in case 3 only): simulated like (b), must revert
///       WrongAnswer(3); the order stays Open.
///   (f) on the paid orders (a) and (d), read receipts, ruleOf and labelsOf, and call run (a) and runStep (d)
///       on every case; each answer must equal the table. These are free reads, never sent.
///   (g) two-piece order: piece 0 = Add(2, 2) (a + b, 3 bits), piece 1 = GreaterOrEqual(3, 2). The order has 6
///       inputs x0..x5: piece 0 gets x0..x3 (a = x0 x1, b = x2 x3), piece 1 gets piece 0's sum as its a and x4 x5 as
///       its b. So the order answers 1 when (x0x1 + x2x3) >= x4x5, each number LSB first. Both pieces are small
///       enough to be checked inside deliverPiece, so the second delivery pays.
///   (h) the same two-piece order with piece 0 delivered honestly (passed) and piece 1 offered the wrong
///       GreaterOrEqual(3, 2) circuit (wrong in case 5): simulated like (b), must revert WrongAnswer(5); piece 0
///       stays passed and the order stays Open.
///   (i) reads on (g): piecesOf, receipts (no single circuit: processor 0; fingerprint = piecedHash =
///       keccak256(abi.encode(pieces, tables))), ruleOf reverts NoSingleCircuit, and run on all 64 inputs must
///       equal the formula above (inputs where bit order matters are logged).
///   (j) a one-piece order GreaterOrEqual(6, 6) (12 inputs, 4,096 cases) delivered with formula circuit 4: too many
///       cases to check inside the delivery, so the log prints the scripts/crank.mjs command that checks it.
///   (k) daily-cap-shaped order with explicit wires, "Lathe joins": inputs x0x1 = spent, x2x3 = amount, x4x5 = cap
///       (2-bit numbers, LSB first). Piece 0 = Add(2, 2) on spent and amount (3-bit sum); piece 1 =
///       GreaterOrEqual(2, 3): a = cap, b = the sum. Allowed = cap >= spent + amount. Pays when piece 1 passes;
///       run on all 64 inputs must equal that rule.
///   (l) the same order as "needs a top circuit": both pieces pass but it stays Open; the script reads
///       expectedTopNetlist, mints a top with those bytes (6 inputs, 1 output) on the REF_PROCESSOR, and
///       deliverTop pays. ruleOf names the top; run (one eval of the top) must equal the rule on all 64 inputs.
///   (m) a third needs-top order, both pieces passed; two bad tops are minted: the right bytes with the wrong shape
///       (7 inputs) and wrong bytes (the comparator's five input wires rotated by one). Both deliverTop
///       calls are simulated like (b) and must revert ShapeMismatch and WrongTopCircuit; the order stays Open.
///   (n) a "needs a top circuit" order of 6 one-gate XOR pieces in a chain (parity of 7 inputs). The script sets up
///       circuit 9 on the mock PROCESSOR as a 1-gate XOR, delivers it as every piece, mints the top on the
///       REF_PROCESSOR and delivers it. run on all 128 inputs must equal the parity. The REF processor charges about
///       what a real REF record costs, so this run fails if the top's run budget ever drops back to
///       evalBudget(gates) alone (6 one-gate pieces get 190,000 then, far below 6 REFs).
contract Smoke is Script {
    bytes internal constant XOR_TABLE = hex"06"; // cases 0..3 -> 0,1,1,0, LSB first
    /// Toggle: case c = x0 + 2s; new memory = s XOR x0, output = new memory; answers 0,3,3,0 = 0x3c.
    bytes internal constant TOGGLE_TABLE = hex"3c";
    uint96 internal constant AMOUNT = 1e6; // 1 mUSDT
    uint256 internal constant DELIVER_GAS = 1_000_000;
    /// run / runStep refuse (InsufficientGasForCase) unless they can give the circuit its whole per-case budget
    /// (100,000 + 15,000 per gate, x64/63, + 20,000; about 183,000 for these 4-gate circuits), so they get an
    /// explicit limit too, the same idea as the page's RUN_OVERHEAD + hold.
    uint256 internal constant RUN_GAS = 1_000_000;
    /// deliverPiece checks a small piece inline: 16 or 32 cases x ~182,500 gas hold (4-gate circuits) + overhead.
    uint256 internal constant PIECE_GAS = 10_000_000;
    /// Two-piece run: two evals, each with its full hold free (web/gas.js runPiecedGasLimit is about 760,000).
    uint256 internal constant PIECED_RUN_GAS = 2_000_000;
    /// (n): the top of 6 pieces gets 100,000 + 15,000 x 6 + 150,000 x 6 = 1,090,000 (web/gas.js runTopGasLimit is
    /// about 1.5M).
    uint256 internal constant TOP_RUN_GAS = 3_000_000;
    uint256 internal constant PARITY_PIECE_ID = 9; // on the mock PROCESSOR, set up by (n)
    uint256 internal parityId;
    uint256 internal parityTop;

    /// Ids of the two memory orders, (d) and (e). Kept in the script's storage to keep run()'s stack small.
    uint256 internal memPaidId;
    uint256 internal memOpenId;
    /// Ids of the pieced orders (g), (h), (j).
    uint256 internal piecedPaidId;
    uint256 internal piecedHalfId;
    uint256 internal crankId;
    /// Ids for (k), (l), (m), and the tops minted for (l) and (m).
    uint256 internal joinedId;
    uint256 internal toppedId;
    uint256 internal badTopId;
    uint256 internal goodTop;
    uint256 internal wrongShapeTop;
    uint256 internal wrongBytesTop;

    function run() external {
        require(block.chainid == 1952, "Smoke: not X Layer testnet (1952)");
        LatheOrders lathe = LatheOrders(vm.envAddress("LATHE"));
        IERC20 usdt = IERC20(vm.envAddress("USDT"));
        address processor = vm.envAddress("PROCESSOR");
        uint256 xorId = vm.envUint("XOR_ID");
        uint256 wrongId = vm.envUint("WRONG_ID");
        uint256 refundDelay = vm.envOr("REFUND_DELAY", uint256(900));
        require(address(lathe.usdt()) == address(usdt), "Smoke: USDT does not match LATHE.usdt()");

        uint64 deadline = uint64(block.timestamp + 1 days);
        uint64 shortDeadline = uint64(block.timestamp + refundDelay);

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        usdt.approve(address(lathe), 12 * uint256(AMOUNT));

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

        // (d) and (e) are sent here too. Every transaction goes out before the simulated wrong deliveries below:
        // a pranked call from the broadcaster uses up one of its nonces in the simulation, so a transaction
        // queued after it would be sent with a nonce the chain skips (seen on the local anvil run).
        _sendMemoryOrders(lathe, me, processor);
        _sendPiecedOrders(lathe);
        _sendWiredOrders(lathe);
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

        _memoryAndReads(lathe, me, processor, xorId, a);
        _piecedChecks(lathe, me);
        _wiredChecks(lathe, me);
        _parityChecks(lathe);
    }

    /// The daily-cap shape on 2-bit numbers. Wires listed in sorted form: piece 0's inputs, piece 1's, the output.
    function _dailyCapSpec(bool top) internal pure returns (LatheOrders.PiecedSpec memory s) {
        s.pieces = new Piece[](2);
        s.pieces[0] = Piece(PieceKind.Add, 4, 3, 2, 2);
        s.pieces[1] = Piece(PieceKind.GreaterOrEqual, 5, 1, 2, 3);
        s.tables = new bytes[](2);
        s.maxGates = new uint32[](2);
        s.labels = new bytes32[](0);
        s.wires = new Wire[](10);
        for (uint8 j = 0; j < 4; ++j) {
            s.wires[j] = Wire(WIRE_TOP, j, 0, j); // spent, amount -> the adder
        }
        s.wires[4] = Wire(WIRE_TOP, 4, 1, 0); // cap -> comparator a
        s.wires[5] = Wire(WIRE_TOP, 5, 1, 1);
        for (uint8 j = 0; j < 3; ++j) {
            s.wires[6 + j] = Wire(0, j, 1, 2 + j); // sum -> comparator b
        }
        s.wires[9] = Wire(1, 0, WIRE_TOP, 0);
        s.needsTop = top;
    }

    /// cap >= spent + amount, each a 2-bit number LSB first in x.
    function _expectedDailyCap(uint256 x) internal pure returns (uint8) {
        return ((x >> 4) & 3) >= (x & 3) + ((x >> 2) & 3) ? 1 : 0;
    }

    /// (k), (l), (m), sent inside run()'s broadcast (before any simulated call, see run()).
    function _sendWiredOrders(LatheOrders lathe) internal {
        (, address me,) = vm.readCallers();
        address fp = vm.envAddress("FORMULA_PROCESSOR");
        RefProcessor rp = RefProcessor(vm.envAddress("REF_PROCESSOR"));
        uint256 add22 = vm.envOr("ADD22_ID", uint256(1));
        uint256 ge23 = vm.envOr("GE23_ID", uint256(5));
        uint64 deadline = uint64(block.timestamp + 1 days);
        joinedId = lathe.createPiecedOrder(_dailyCapSpec(false), AMOUNT, deadline, me);
        toppedId = lathe.createPiecedOrder(_dailyCapSpec(true), AMOUNT, deadline, me);
        badTopId = lathe.createPiecedOrder(_dailyCapSpec(true), AMOUNT, deadline, me);
        uint256[3] memory ids = [joinedId, toppedId, badTopId];
        for (uint256 i = 0; i < 3; ++i) {
            lathe.deliverPiece{gas: PIECE_GAS}(ids[i], 0, fp, add22);
            lathe.deliverPiece{gas: PIECE_GAS}(ids[i], 1, fp, ge23);
        }
        bytes memory nl = lathe.expectedTopNetlist(toppedId);
        goodTop = rp.mint(nl, 6, 1, me);
        lathe.deliverTop(toppedId, address(rp), goodTop);
        wrongShapeTop = rp.mint(nl, 7, 1, me);
        wrongBytesTop = rp.mint(_swappedTop(lathe, badTopId), 6, 1, me);
        _sendParityTop(lathe, me, rp, deadline);
    }

    /// (n), sent inside run()'s broadcast.
    function _sendParityTop(LatheOrders lathe, address me, RefProcessor rp, uint64 deadline) internal {
        MockProcessor mp = MockProcessor(vm.envAddress("PROCESSOR"));
        mp.setCircuit(PARITY_PIECE_ID, me, 2, 1, 0, 1);
        bytes[] memory o = new bytes[](4);
        o[0] = hex"00";
        o[1] = hex"01";
        o[2] = hex"01";
        o[3] = hex"00";
        mp.setOuts(PARITY_PIECE_ID, o);
        LatheOrders.PiecedSpec memory s;
        s.pieces = new Piece[](6);
        s.tables = new bytes[](6);
        s.maxGates = new uint32[](6);
        s.labels = new bytes32[](0);
        s.wires = new Wire[](13);
        for (uint8 k = 0; k < 6; ++k) {
            s.pieces[k] = Piece(PieceKind.Table, 2, 1, 0, 0);
            s.tables[k] = XOR_TABLE;
            s.wires[2 * k] = k == 0 ? Wire(WIRE_TOP, 0, 0, 0) : Wire(k - 1, 0, k, 0);
            s.wires[2 * k + 1] = Wire(WIRE_TOP, k + 1, k, 1);
        }
        s.wires[12] = Wire(5, 0, WIRE_TOP, 0);
        s.needsTop = true;
        parityId = lathe.createPiecedOrder(s, AMOUNT, deadline, me);
        for (uint256 k = 0; k < 6; ++k) {
            lathe.deliverPiece{gas: PIECE_GAS}(parityId, k, address(mp), PARITY_PIECE_ID);
        }
        parityTop = rp.mint(lathe.expectedTopNetlist(parityId), 7, 1, me);
        lathe.deliverTop(parityId, address(rp), parityTop);
    }

    /// Checks for (n).
    function _parityChecks(LatheOrders lathe) internal view {
        _logStatus("(n) top of 6 one-gate XOR pieces, expect Paid(2)", lathe, parityId);
        require(_status(lathe, parityId) == LatheOrders.Status.Paid, "Smoke (n): not Paid");
        (address tp, uint256 tc) = lathe.ruleOf(parityId);
        require(tp == vm.envAddress("REF_PROCESSOR") && tc == parityTop, "Smoke (n): ruleOf is not the top");
        for (uint256 x = 0; x < 128; ++x) {
            uint8 p;
            for (uint256 b = 0; b < 7; ++b) {
                p ^= uint8((x >> b) & 1);
            }
            bytes memory t = lathe.run{gas: TOP_RUN_GAS}(parityId, abi.encodePacked(uint8(x)));
            require(t.length == 1 && uint8(t[0]) == p, "Smoke (n): run via the top disagrees with the parity");
        }
        console2.log("    run(n) on all 128 inputs = parity of x0..x6 (6 REFs, gas", TOP_RUN_GAS, ")");
    }

    /// The bad top's bytes: the order's own expected bytes with the comparator's five input wires rotated by one
    /// (cap bit 1, sum bits 0-2, cap bit 0). Still a valid netlist (every wire points backwards), but not the wiring
    /// ordered, so its hash differs.
    function _swappedTop(LatheOrders lathe, uint256 id) internal view returns (bytes memory) {
        bytes memory nl = lathe.expectedTopNetlist(id);
        // Piece 1's record starts after piece 0's (31 + 3 x 4 bytes); its 5 input wires follow its 31-byte head.
        // Rotate them: the wire numbers stay valid (all point backwards), only the wiring changes.
        uint256 at = 43 + 31;
        bytes memory out = nl;
        bytes memory first = new bytes(3);
        for (uint256 i = 0; i < 3; ++i) {
            first[i] = nl[at + i];
        }
        for (uint256 i = 0; i < 12; ++i) {
            out[at + i] = nl[at + 3 + i];
        }
        for (uint256 i = 0; i < 3; ++i) {
            out[at + 12 + i] = first[i];
        }
        return out;
    }

    /// Checks for (k), (l), (m). Split out of run() to keep the stack small.
    function _wiredChecks(LatheOrders lathe, address me) internal {
        address rp = vm.envAddress("REF_PROCESSOR");
        _logStatus("(k) daily-cap shape, explicit wires, Lathe joins, expect Paid(2)", lathe, joinedId);
        require(_status(lathe, joinedId) == LatheOrders.Status.Paid, "Smoke (k): not Paid");
        require(!lathe.needsTop(joinedId), "Smoke (k): needsTop");
        require(lathe.wiresOf(joinedId).length == 10, "Smoke (k): wiresOf");
        _logStatus("(l) the same as needs a top circuit, top minted and delivered, expect Paid(2)", lathe, toppedId);
        require(_status(lathe, toppedId) == LatheOrders.Status.Paid, "Smoke (l): not Paid");
        (address tp, uint256 tc) = lathe.ruleOf(toppedId);
        require(tp == rp && tc == goodTop, "Smoke (l): ruleOf is not the top");
        (address rpr, uint256 rc, bytes32 rh,) = lathe.receipts(toppedId);
        require(rpr == rp && rc == goodTop && rh == lathe.piecedHash(toppedId), "Smoke (l): receipt");
        for (uint256 x = 0; x < 64; ++x) {
            bytes memory inp = abi.encodePacked(uint8(x));
            bytes memory j = lathe.run{gas: PIECED_RUN_GAS}(joinedId, inp);
            bytes memory t = lathe.run{gas: PIECED_RUN_GAS}(toppedId, inp);
            require(j.length == 1 && uint8(j[0]) == _expectedDailyCap(x), "Smoke (k): run disagrees");
            require(keccak256(t) == keccak256(j), "Smoke (l): run via the top disagrees");
        }
        console2.log("    top circuit", goodTop, "on the REF processor; ruleOf names it");
        console2.log("    run(k) and run(l) on all 64 inputs = cap >= spent + amount; x=0x25 -> 1, x=0x27 -> 0");

        _expectTopRefused(lathe, me, wrongShapeTop, LatheOrders.ShapeMismatch.selector, "ShapeMismatch");
        _expectTopRefused(lathe, me, wrongBytesTop, LatheOrders.WrongTopCircuit.selector, "WrongTopCircuit");
        _logStatus("(m) both bad tops refused (simulated, not sent), order stays Open(0)", lathe, badTopId);
        require(_status(lathe, badTopId) == LatheOrders.Status.Open, "Smoke (m): not Open");
    }

    function _expectTopRefused(LatheOrders lathe, address me, uint256 top, bytes4 sel, string memory name) internal {
        vm.prank(me);
        try lathe.deliverTop(badTopId, vm.envAddress("REF_PROCESSOR"), top) {
            revert(string.concat("Smoke (m): bad top accepted, wanted ", name));
        } catch (bytes memory err) {
            require(bytes4(err) == sel, string.concat("Smoke (m): reverted, but not with ", name));
            console2.log(string.concat("(m) bad top ", vm.toString(top), ": deliverTop reverts ", name));
        }
    }

    /// Piece 0 = Add(2, 2): 4 inputs, 3 outputs. Piece 1 = GreaterOrEqual(3, 2): 5 inputs, 1 output.
    function _twoPieces() internal pure returns (Piece[] memory ps, bytes[] memory ts) {
        ps = new Piece[](2);
        ps[0] = Piece(PieceKind.Add, 4, 3, 2, 2);
        ps[1] = Piece(PieceKind.GreaterOrEqual, 5, 1, 3, 2);
        ts = new bytes[](2); // formula pieces have no table
    }

    /// (g), (h) and (j), sent inside run()'s broadcast (before any simulated call, see run()).
    function _sendPiecedOrders(LatheOrders lathe) internal {
        (, address me,) = vm.readCallers();
        address fp = vm.envAddress("FORMULA_PROCESSOR");
        uint64 deadline = uint64(block.timestamp + 1 days);
        (Piece[] memory ps, bytes[] memory ts) = _twoPieces();
        uint32[] memory caps = new uint32[](2);
        bytes32[] memory none = new bytes32[](0);
        piecedPaidId = lathe.createPiecedOrder(ps, ts, AMOUNT, deadline, me, caps, none);
        lathe.deliverPiece{gas: PIECE_GAS}(piecedPaidId, 0, fp, vm.envOr("ADD22_ID", uint256(1)));
        lathe.deliverPiece{gas: PIECE_GAS}(piecedPaidId, 1, fp, vm.envOr("GE32_ID", uint256(2)));
        piecedHalfId = lathe.createPiecedOrder(ps, ts, AMOUNT, deadline, me, caps, none);
        lathe.deliverPiece{gas: PIECE_GAS}(piecedHalfId, 0, fp, vm.envOr("ADD22_ID", uint256(1)));

        Piece[] memory one = new Piece[](1);
        one[0] = Piece(PieceKind.GreaterOrEqual, 12, 1, 6, 6);
        crankId = lathe.createPiecedOrder(one, new bytes[](1), AMOUNT, deadline, me, new uint32[](1), none);
        // 4,096 cases x 160,000 gas budget is above the 30M inline limit: deliverPiece only records it.
        lathe.deliverPiece{gas: PIECE_GAS}(crankId, 0, fp, vm.envOr("GE66_ID", uint256(4)));
    }

    /// (x0x1 + x2x3) >= x4x5, each 2-bit number LSB first.
    function _expectedTwoPiece(uint256 x) internal pure returns (uint8) {
        return ((x & 3) + ((x >> 2) & 3)) >= ((x >> 4) & 3) ? 1 : 0;
    }

    /// Checks for (g) to (j). Split out of run() to keep the stack small.
    function _piecedChecks(LatheOrders lathe, address me) internal {
        address fp = vm.envAddress("FORMULA_PROCESSOR");
        uint256 g = piecedPaidId;
        uint256 h = piecedHalfId;

        _logStatus("(g) two-piece order Add(2,2) then GreaterOrEqual(3,2), expect Paid(2)", lathe, g);
        require(_status(lathe, g) == LatheOrders.Status.Paid, "Smoke (g): not Paid");

        vm.prank(me);
        try lathe.deliverPiece(h, 1, fp, vm.envOr("GE32_WRONG_ID", uint256(3))) {
            revert("Smoke (h): wrong piece was accepted");
        } catch (bytes memory err) {
            require(
                keccak256(err) == keccak256(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, uint256(5))),
                "Smoke (h): reverted, but not with WrongAnswer(5)"
            );
            console2.log("(h) wrong piece 1: deliverPiece reverts WrongAnswer(5) (simulated, not sent)");
        }
        (address p0,,,,, uint32 n0) = lathe.pieceOf(h, 0);
        (address p1,,,,,) = lathe.pieceOf(h, 1);
        require(p0 == fp && n0 == 16, "Smoke (h): piece 0 is not passed (16 of 16)");
        require(p1 == address(0), "Smoke (h): piece 1 should have no delivery");
        _logStatus("(h) piece 0 passed 16/16, piece 1 not delivered, order stays Open(0)", lathe, h);
        require(_status(lathe, h) == LatheOrders.Status.Open, "Smoke (h): not Open");
        _piecedReads(lathe, g);
        _crankLine(lathe, fp);
    }

    /// (i): piecesOf, the receipt, ruleOf and run on the paid two-piece order g.
    function _piecedReads(LatheOrders lathe, uint256 g) internal view {
        console2.log("(i) reads on the paid two-piece order");
        Piece[] memory got = lathe.piecesOf(g);
        (Piece[] memory want, bytes[] memory ts) = _twoPieces();
        require(keccak256(abi.encode(got)) == keccak256(abi.encode(want)), "Smoke (i): piecesOf");
        (address rp, uint256 rc, bytes32 rh, uint64 rb) = lathe.receipts(g);
        require(rp == address(0) && rc == 0 && rb != 0, "Smoke (i): a two-piece receipt names no single circuit");
        require(rh == lathe.piecedHash(g) && rh == keccak256(abi.encode(want, ts)), "Smoke (i): receipt fingerprint");
        try lathe.ruleOf(g) {
            revert("Smoke (i): ruleOf answered for a two-piece order");
        } catch (bytes memory err) {
            require(bytes4(err) == LatheOrders.NoSingleCircuit.selector, "Smoke (i): ruleOf, not NoSingleCircuit");
        }
        console2.log("    piecesOf ok; receipt: processor 0, fingerprint = piecedHash; ruleOf reverts NoSingleCircuit");
        for (uint256 x = 0; x < 64; ++x) {
            bytes memory out = lathe.run{gas: PIECED_RUN_GAS}(g, abi.encodePacked(uint8(x)));
            require(out.length == 1 && uint8(out[0]) == _expectedTwoPiece(x), "Smoke (i): run(g) disagrees");
        }
        // Bit order: x = 0b000001 (a = 1) gives 1 >= 0 = 1; x = 0b100000 (b' = 2) gives 0 >= 2 = 0; x = 0b010011
        // (a = 3, b' = 1) gives 1. Reading any number MSB first would flip at least one of these.
        console2.log("    run(g) on all 64 inputs = (x0x1 + x2x3) >= x4x5; x=0x01 -> 1, x=0x20 -> 0, x=0x13 -> 1");
    }

    /// (j): the 12-input piece is recorded at 0/4096; print the crank command.
    function _crankLine(LatheOrders lathe, address fp) internal view {

        (address cp,,, uint32 cg,, uint32 cn) = lathe.pieceOf(crankId, 0);
        require(cp == fp && cn == 0, "Smoke (j): GreaterOrEqual(6, 6) piece not recorded at 0/4096");
        _logStatus("(j) one-piece GreaterOrEqual(6,6), 4,096 cases, recorded at 0/4096, expect Open(0)", lathe, crankId);
        console2.log("    gates", uint256(cg), "- check it with the crank (from the repo folder):");
        console2.log(
            string.concat(
                "    node scripts/crank.mjs --lathe ",
                vm.toString(address(lathe)),
                " --order ",
                vm.toString(crankId),
                " --piece 0 --batch 1000 --rpc https://testrpc.xlayer.tech/terigon --chain-id 1952",
                " --account <name> --password-file <path>"
            )
        );
    }

    /// (d) memory order with names + honest toggle (explicit gas, same reason as (a)); (e) the second memory order.
    /// Called inside run()'s broadcast; the approve there covers both orders.
    function _sendMemoryOrders(LatheOrders lathe, address me, address processor) internal {
        bytes32[] memory names = new bytes32[](2);
        names[0] = bytes32("flip");
        names[1] = bytes32("mem");
        uint64 deadline = uint64(block.timestamp + 1 days);
        memPaidId = lathe.createStatefulOrder(1, 1, 1, TOGGLE_TABLE, AMOUNT, deadline, me, 0, names);
        lathe.deliver{gas: DELIVER_GAS}(memPaidId, processor, vm.envOr("TOGGLE_ID", uint256(3)));
        memOpenId = lathe.createStatefulOrder(1, 1, 1, TOGGLE_TABLE, AMOUNT, deadline, me, 0);
    }

    /// Checks for (d), (e) and (f). Split out of run() to keep the stack small.
    function _memoryAndReads(LatheOrders lathe, address me, address processor, uint256 xorId, uint256 a) internal {
        uint256 toggleId = vm.envOr("TOGGLE_ID", uint256(3));
        uint256 wrongToggleId = vm.envOr("WRONG_TOGGLE_ID", uint256(4));
        uint256 d = memPaidId;
        uint256 e = memOpenId;

        _logStatus("(d) memory toggle with names, expect Paid(2)", lathe, d);
        require(_status(lathe, d) == LatheOrders.Status.Paid, "Smoke (d): not Paid");

        vm.prank(me);
        try lathe.deliver(e, processor, wrongToggleId) {
            revert("Smoke (e): wrong toggle was accepted");
        } catch (bytes memory err) {
            require(
                keccak256(err) == keccak256(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, uint256(3))),
                "Smoke (e): reverted, but not with WrongAnswer(3)"
            );
            console2.log("(e) wrong toggle: deliver reverts WrongAnswer(3) (simulated, not sent)");
        }
        _logStatus("(e) memory order stays Open(0)", lathe, e);
        require(_status(lathe, e) == LatheOrders.Status.Open, "Smoke (e): not Open");

        console2.log("(f) reads on the paid orders");
        _checkReceipt(lathe, a, processor, xorId, abi.encodePacked(uint8(2), uint8(1), uint8(0), XOR_TABLE));
        _checkReceipt(lathe, d, processor, toggleId, abi.encodePacked(uint8(1), uint8(1), uint8(1), TOGGLE_TABLE));
        require(lathe.labelsOf(a).length == 0, "Smoke (f): order (a) has no names");
        bytes32[] memory got = lathe.labelsOf(d);
        require(got.length == 2 && got[0] == bytes32("flip") && got[1] == bytes32("mem"), "Smoke (f): labelsOf(d)");
        console2.log("    labelsOf: (a) none, (d) flip, mem");

        // run(a): XOR on every input pair, two inputs packed LSB first in one byte
        for (uint256 x = 0; x < 4; ++x) {
            bytes memory out = lathe.run{gas: RUN_GAS}(a, abi.encodePacked(uint8(x)));
            require(out.length == 1 && uint8(out[0]) == ((x & 1) ^ (x >> 1)), "Smoke (f): run(a) disagrees with XOR");
        }
        console2.log("    run(a): y0 = x0 XOR x1 on all 4 cases");
        // runStep(d): returns (new memory, outputs); both must be s XOR x0
        for (uint256 c = 0; c < 4; ++c) {
            uint8 x0 = uint8(c & 1);
            uint8 s0 = uint8(c >> 1);
            (bytes memory ns, bytes memory out) =
                lathe.runStep{gas: RUN_GAS}(d, abi.encodePacked(s0), abi.encodePacked(x0));
            require(ns.length == 1 && uint8(ns[0]) == (s0 ^ x0), "Smoke (f): runStep(d) new memory");
            require(out.length == 1 && uint8(out[0]) == (s0 ^ x0), "Smoke (f): runStep(d) output");
        }
        console2.log("    runStep(d): new memory = output = s XOR x0 on all 4 cases");
    }

    /// The receipt names the delivered circuit, its fingerprint covers shape + table, and ruleOf agrees.
    function _checkReceipt(LatheOrders lathe, uint256 id, address processor, uint256 circuitId, bytes memory shapeAndTable)
        internal
        view
    {
        (address rp, uint256 rc, bytes32 rh, uint64 rb) = lathe.receipts(id);
        require(rp == processor && rc == circuitId && rb != 0, "Smoke (f): receipt");
        require(rh == keccak256(shapeAndTable), "Smoke (f): receipt fingerprint");
        (address p, uint256 cid) = lathe.ruleOf(id);
        require(p == processor && cid == circuitId, "Smoke (f): ruleOf");
        console2.log("    receipt + ruleOf ok for order", id, "block", uint256(rb));
    }

    function _status(LatheOrders lathe, uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function _logStatus(string memory label, LatheOrders lathe, uint256 id) internal view {
        console2.log(label);
        console2.log("    order id", id, "status", uint256(_status(lathe, id)));
    }
}
