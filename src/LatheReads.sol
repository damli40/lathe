// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Piece} from "./FormulaLib.sol";
import {BitLib} from "./BitLib.sol";
import {IProcessor} from "./ITapeOut.sol";
import {LatheOrders} from "./LatheOrders.sol";
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
    /// @notice LatheOrders.run. `ps` is the order's pieces (empty for a V0-V2 order), `d` its V0 delivery and
    /// `pds` its piece deliveries.
    function run(
        LatheOrders.Order storage o,
        Piece[] storage ps,
        LatheOrders.Delivery storage d,
        mapping(uint256 => LatheOrders.Delivery) storage pds,
        bytes calldata inputs
    ) external view returns (bytes memory) {
        if (o.status != LatheOrders.Status.Paid) revert LatheOrders.NotPaid();
        if (o.nState != 0 || !_fits(inputs, o.nIn)) revert LatheOrders.BadInputs();
        if (ps.length != 0) return _runPieces(ps, pds, BitLib.readBits(inputs, 0, o.nIn));
        uint256 budget = _paidBudget(o, d);
        return _low(IProcessor(d.processor).eval{gas: budget}(d.circuitId, inputs), o.nOut);
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
        uint256 budget = _paidBudget(o, d);
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

    /// @dev The circuit must be the one delivered, and the caller must leave room for its full budget.
    function _paidBudget(LatheOrders.Order storage o, LatheOrders.Delivery storage d)
        private
        view
        returns (uint256 budget)
    {
        _requireSame(d, o.nIn, o.nOut, o.nState);
        budget = _evalBudget(d.gateCount);
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
