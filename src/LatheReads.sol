// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Piece} from "./FormulaLib.sol";
import {BitLib} from "./BitLib.sol";
import {IProcessor} from "./ITapeOut.sol";
import {LatheOrders} from "./LatheOrders.sol";
import {NetlistLib, Wire, WIRE_TOP} from "./NetlistLib.sol";
import "./LatheConstants.sol";

/// @notice The read-only path of LatheOrders (run, runStep and the piece join). LatheOrders keeps the same
/// external functions and passes its storage here, so callers see the same signatures, results and errors.
/// A separate (linked) library only to keep LatheOrders under the 24,576-byte contract size limit. Nothing here
/// writes storage or moves money: the library is reached by DELEGATECALL from view functions.
///
/// Gas: LatheOrders forwards 63/64 of its gas to this library (EIP-150). The per-case gas guard (gasleft() >=
/// budget * 64/63 + GAS_RESERVE) runs here, right before the circuit call, so it measures the gas this frame
/// really has: a caller with too little gas still gets InsufficientGasForCase, never an answer.
library LatheReads {
    /// @notice LatheOrders.run. `ps` is the order's pieces (empty for a V0-V2 order), `d` its V0 delivery (for an
    /// order that needs a top circuit: the top, once delivered), `pds` its piece deliveries and `ws` its stored
    /// wires (empty for a pieced order created without wires).
    /// - V0-V2 order, or a pieced order paid with a top circuit: one eval of that circuit. For a top, every piece
    ///   is first checked to be unchanged as well (a REF runs the piece's current circuit, and the top's own
    ///   netlist bytes would not show a change inside a piece).
    /// - Pieced order without a top: Lathe joins the pieces, either the V3a A -> B join (no wires stored) or along
    ///   the wires, in piece-index order (_runChain).
    function run(
        LatheOrders.Order storage o,
        Piece[] storage ps,
        LatheOrders.Delivery storage d,
        mapping(uint256 => LatheOrders.Delivery) storage pds,
        Wire[] storage ws,
        bytes calldata inputs
    ) external view returns (bytes memory) {
        if (o.status != LatheOrders.Status.Paid) revert LatheOrders.NotPaid();
        if (o.nState != 0 || !_fits(inputs, o.nIn)) revert LatheOrders.BadInputs();
        if (ps.length != 0 && d.processor == address(0)) {
            uint256 x = BitLib.readBits(inputs, 0, o.nIn);
            if (ws.length == 0) return _runPieces(ps, pds, x);
            return BitLib.pack(_runChain(ps, pds, ws, x, o.nOut), o.nOut);
        }
        for (uint256 k = 0; k < ps.length; ++k) {
            _requireSame(pds[k], ps[k].nIn, ps[k].nOut, 0);
        }
        uint256 budget = _paidBudget(o, d, ps.length);
        return _low(IProcessor(d.processor).eval{gas: budget}(d.circuitId, inputs), o.nOut);
    }

    /// @notice The netlist bytes the top circuit of an order must have (NetlistLib.encodeRefTop over the delivered
    /// pieces and the stored wires). Reverts PiecesNotPassed while any piece has no delivery: before that the
    /// bytes are not fixed yet.
    function expectedTop(
        Piece[] storage ps,
        mapping(uint256 => LatheOrders.Delivery) storage pds,
        Wire[] storage ws,
        uint8 nIn,
        uint8 nOut
    ) external view returns (bytes memory) {
        uint256 n = ps.length;
        address[] memory procs = new address[](n);
        uint256[] memory ids = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            procs[k] = pds[k].processor;
            ids[k] = pds[k].circuitId;
            if (procs[k] == address(0)) revert LatheOrders.PiecesNotPassed();
        }
        return NetlistLib.encodeRefTop(procs, ids, ps, ws, nIn, nOut);
    }

    /// @notice The circuit a "Lathe joins" pieced order's receipt names, or (0, 0) when it has none. An order has a
    /// single circuit only when that circuit computes the order's rule exactly as it is: 1 piece, and either no
    /// stored wires (created without wires) or the identity wiring (order input i feeds pin i for every pin, piece
    /// output j is order output j for every output, nothing else). Any other 1-piece wiring (inputs swapped, one
    /// input fanned out to two pins, an output left unused) computes a different rule, or has a different shape,
    /// from the piece's circuit, so the receipt names none and ruleOf reverts NoSingleCircuit, as for 2+ pieces.
    /// `ws` is sorted (LatheChecks._sortWires): slot j < nIn is pin j of piece 0, slot nIn + j is order output j.
    function singleCircuit(Piece[] storage ps, mapping(uint256 => LatheOrders.Delivery) storage pds, Wire[] storage ws)
        external
        view
        returns (address, uint256)
    {
        if (ps.length != 1) return (address(0), 0);
        Piece memory p = ps[0];
        if (ws.length != 0) {
            if (ws.length != uint256(p.nIn) + p.nOut) return (address(0), 0);
            for (uint256 j = 0; j < ws.length; ++j) {
                Wire memory e = ws[j];
                bool pin = j < p.nIn;
                if (e.fromPiece != (pin ? WIRE_TOP : 0) || e.fromBit != (pin ? j : j - p.nIn)) return (address(0), 0);
            }
        }
        return (pds[0].processor, pds[0].circuitId);
    }

    /// @notice LatheOrders.wiresOf: the stored wires, or for a pieced order created without wires the V3a join
    /// written as wires (1 piece: order inputs -> the piece -> order outputs; 2 pieces: order inputs 0 .. A.nIn-1
    /// -> A, A's outputs -> B's low inputs, the remaining order inputs -> B's inputs above them, B -> order
    /// outputs), sorted the same way. Empty for a V0-V2 order.
    function wiresOf(Piece[] storage ps, Wire[] storage ws) external view returns (Wire[] memory out) {
        if (ws.length != 0 || ps.length == 0) return ws;
        Piece memory a = ps[0];
        Piece memory b = ps.length == 2 ? ps[1] : a;
        uint256 last = ps.length - 1;
        out = new Wire[](uint256(a.nIn) + (last == 1 ? b.nIn : 0) + b.nOut);
        uint256 w;
        for (uint256 j = 0; j < a.nIn; ++j) {
            out[w++] = Wire(WIRE_TOP, uint8(j), 0, uint8(j));
        }
        if (last == 1) {
            for (uint256 j = 0; j < b.nIn; ++j) {
                out[w++] = j < a.nOut ? Wire(0, uint8(j), 1, uint8(j)) : Wire(WIRE_TOP, uint8(a.nIn + j - a.nOut), 1, uint8(j));
            }
        }
        for (uint256 j = 0; j < b.nOut; ++j) {
            out[w++] = Wire(uint8(last), uint8(j), WIRE_TOP, uint8(j));
        }
    }

    /// @notice LatheOrders.runStep.
    function runStep(
        LatheOrders.Order storage o,
        LatheOrders.Delivery storage d,
        bytes calldata state,
        bytes calldata inputs
    ) external view returns (bytes memory newState, bytes memory outputs) {
        if (o.status != LatheOrders.Status.Paid) revert LatheOrders.NotPaid();
        if (o.nState == 0 || !_fits(inputs, o.nIn) || !_fits(state, o.nState)) revert LatheOrders.BadInputs();
        uint256 budget = _paidBudget(o, d, 0);
        (newState, outputs) = IProcessor(d.processor).step{gas: budget}(d.circuitId, state, inputs);
        return (_low(newState, o.nState), _low(outputs, o.nOut));
    }

    /// @dev run for a pieced order: A on x's low A.nIn bits, then B on outA | ((x >> A.nIn) << A.nOut).
    function _runPieces(Piece[] storage ps, mapping(uint256 => LatheOrders.Delivery) storage pds, uint256 x)
        private
        view
        returns (bytes memory)
    {
        Piece memory a = ps[0];
        uint256 out = _evalPiece(pds[0], a, x & ((uint256(1) << a.nIn) - 1));
        if (ps.length == 1) return BitLib.pack(out, a.nOut);
        Piece memory b = ps[1];
        out = _evalPiece(pds[1], b, out | ((x >> a.nIn) << a.nOut));
        return BitLib.pack(out, b.nOut);
    }

    /// @dev run along stored (sorted) wires: piece 0, then 1, .., each fed from the order's input bits and earlier
    /// pieces' answers; then the order's output bits. Each piece eval has the same guards as the V3a join.
    function _runChain(
        Piece[] storage ps,
        mapping(uint256 => LatheOrders.Delivery) storage pds,
        Wire[] storage ws,
        uint256 x,
        uint256 nOut
    ) private view returns (uint256 y) {
        uint256 n = ps.length;
        uint256[] memory outs = new uint256[](n);
        uint256 w;
        for (uint256 k = 0; k < n; ++k) {
            Piece memory p = ps[k];
            uint256 xin;
            for (uint256 j = 0; j < p.nIn; ++j) {
                xin |= _bit(ws[w++], x, outs) << j;
            }
            outs[k] = _evalPiece(pds[k], p, xin);
        }
        for (uint256 j = 0; j < nOut; ++j) {
            y |= _bit(ws[w + j], x, outs) << j;
        }
    }

    /// @dev The bit a wire carries: order input bit fromBit, or bit fromBit of piece fromPiece's answer.
    function _bit(Wire storage e, uint256 x, uint256[] memory outs) private view returns (uint256) {
        uint256 v = e.fromPiece == WIRE_TOP ? x : outs[e.fromPiece];
        return (v >> e.fromBit) & 1;
    }

    /// @dev One eval of a paid piece with run's guards: unchanged circuit, full budget, enough output bytes.
    function _evalPiece(LatheOrders.Delivery storage d, Piece memory p, uint256 x) private view returns (uint256) {
        _requireSame(d, p.nIn, p.nOut, 0);
        uint256 budget = _evalBudget(d.gateCount);
        bytes memory inputs = BitLib.pack(x, p.nIn);
        _requireCaseGas(budget);
        bytes memory out = IProcessor(d.processor).eval{gas: budget}(d.circuitId, inputs);
        if (out.length < (uint256(p.nOut) + 7) / 8) revert LatheOrders.ShortOutput();
        return BitLib.lowBits(out, p.nOut);
    }

    /// @dev The circuit must be the one delivered, and the caller must leave room for its full budget:
    /// evalBudget(gateCount), plus EVAL_GAS_PER_REF for each of the `refs` REF records of a top circuit (one per
    /// piece; 0 for a V0-V2 circuit). See LatheOrders.EVAL_GAS_PER_REF.
    function _paidBudget(LatheOrders.Order storage o, LatheOrders.Delivery storage d, uint256 refs)
        private
        view
        returns (uint256 budget)
    {
        _requireSame(d, o.nIn, o.nOut, o.nState);
        budget = _evalBudget(d.gateCount) + LATHE_EVAL_GAS_PER_REF * refs;
        _requireCaseGas(budget);
    }

    /// @dev The same rule as LatheOrders._requireSame: the processor is upgradeable, so refuse to run a circuit
    /// that is no longer the one delivered.
    function _requireSame(LatheOrders.Delivery storage d, uint256 wantIn, uint256 wantOut, uint256 wantState)
        private
        view
    {
        IProcessor p = IProcessor(d.processor);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = p.circuitInfo(d.circuitId);
        if (gates != d.gateCount || nIn != wantIn || nOut != wantOut || nState != wantState) {
            revert LatheOrders.CircuitChanged();
        }
        if (keccak256(p.netlist(d.circuitId)) != d.netlistHash) revert LatheOrders.CircuitChanged();
    }

    /// @dev The same rule as LatheOrders._requireCaseGas, measured in this library's own frame.
    function _requireCaseGas(uint256 budget) private view {
        if (gasleft() < budget * 64 / 63 + LATHE_GAS_RESERVE) revert LatheOrders.InsufficientGasForCase();
    }

    /// @dev LatheOrders.evalBudget.
    function _evalBudget(uint256 gateCount) private pure returns (uint256) {
        return LATHE_EVAL_BASE_GAS + LATHE_EVAL_GAS_PER_GATE * gateCount;
    }

    /// @dev Exactly ceil(nBits/8) bytes and no bit set above nBits.
    function _fits(bytes calldata b, uint256 nBits) private pure returns (bool) {
        if (b.length != (nBits + 7) / 8) return false;
        return nBits % 8 == 0 || uint8(b[b.length - 1]) >> (nBits % 8) == 0;
    }

    /// @dev The low nBits of b, packed again so the padding is zero. Too few bytes is an error, never zeros.
    function _low(bytes memory b, uint256 nBits) private pure returns (bytes memory) {
        if (b.length < (nBits + 7) / 8) revert LatheOrders.ShortOutput();
        return BitLib.pack(BitLib.lowBits(b, nBits), nBits);
    }
}
