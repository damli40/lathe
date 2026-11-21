// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TableLib} from "./TableLib.sol";
import {BitLib} from "./BitLib.sol";
import {IProcessor, IProcessorFactory} from "./ITapeOut.sol";

/// @title LatheOrders
/// @notice A buyer locks USD₮0 for a truth table. A builder delivers a TapeOut circuit. The contract runs
/// every case through the circuit and pays the builder on a full match, or lets the buyer refund.
/// No owner, no admin, no pause, no upgrade. The fee rate and fee recipient are fixed at deploy.
contract LatheOrders is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Open,
        Checking,
        Paid,
        Refunded
    }

    struct Order {
        address buyer;
        address builder; // the only address that may deliver; never zero (see _create)
        uint96 amount;
        uint64 deadline;
        uint32 maxGates; // zero = no cap
        uint8 nIn;
        uint8 nOut;
        uint8 nState;
        Status status;
    }

    struct Delivery {
        address processor;
        uint256 circuitId;
        address builder; // who delivered; the one paid
        uint32 gateCount; // recorded at delivery; check reverts if it changes
        bytes32 netlistHash; // keccak256(netlist(circuitId)) at delivery; same rule
        uint32 nextCase; // the next case check will run
    }

    /// @notice What was paid for, written once at payout: which circuit, the hash of the table it matched, and
    /// the block. Never changed afterwards. (Named PaidReceipt because Solidity forbids a struct and the Receipt
    /// event sharing one name; the event name is the one in the ABI.)
    struct PaidReceipt {
        address processor;
        uint256 circuitId;
        bytes32 tableHash; // keccak256(abi.encodePacked(nIn, nOut, nState, tableOf[orderId])), see _writeReceipt
        uint64 blockNumber;
    }

    /// @dev Create arguments grouped to keep the stack small.
    struct Terms {
        uint96 amount;
        uint64 deadline;
        address builder;
        uint32 maxGates;
    }

    uint256 public constant GRACE = 1 days;
    uint16 public constant MAX_FEE_BPS = 500;
    uint256 public constant MAX_CASE_BITS = 6; // nIn + nState <= 6, so at most 64 cases
    uint256 public constant MAX_ANSWER_BITS = 16; // nOut + nState <= 16

    /// @notice Each case's eval gets exactly evalBudget(gateCount) gas, never the caller's leftover gas, so a
    /// case's result cannot depend on how much gas the caller sent. Running out of the budget is a wrong answer.
    /// Measured on X Layer (evidence/2026-11-20-eval-gas-budget.md): ~2,320 gas per real gate, ~10,000 per gate
    /// for circuits built from REFs to the 4-gate XOR. The per-gate figure covers the REF-heavy case with 1.5x.
    uint256 public constant EVAL_BASE_GAS = 100_000;
    uint256 public constant EVAL_GAS_PER_GATE = 15_000;
    /// @notice Gas kept back for the work between the gas check and the call, so eval really gets its budget.
    uint256 public constant GAS_RESERVE = 20_000;
    /// @notice Largest budget for one case. A circuit above it could never be checked in one X Layer
    /// transaction (block gas limit 210M) and would hold the order until deadline + grace, so deliver refuses it.
    uint256 public constant MAX_CASE_GAS = 100_000_000;
    /// @notice When cases x evalBudget(gateCount) is at most this, deliver checks every case in the same
    /// transaction: a wrong answer reverts the delivery, so junk can never hold the order. Larger circuits are
    /// recorded and checked in batches with check().
    uint256 public constant INLINE_CHECK_MAX_GAS = 30_000_000;

    address public immutable factory;
    IERC20 public immutable usdt;
    address public immutable feeRecipient;
    uint16 public immutable feeBps;

    uint256 public nextOrderId = 1;
    /// @notice Fees earned but not yet sent. Pulled with claimFees, so a fee recipient the token blocks can
    /// never stop a builder's payout.
    uint256 public feesOwed;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => bytes) public tableOf;
    mapping(uint256 => Delivery) public deliveries;
    mapping(uint256 => PaidReceipt) public receipts;
    /// @dev Optional names for the inputs (then the memory bits), one bytes32 each; empty when none were given.
    mapping(uint256 => bytes32[]) internal _labels;

    event OrderCreated(uint256 indexed orderId, address indexed buyer, uint96 amount, uint64 deadline);
    event Delivered(uint256 indexed orderId, address indexed builder, address processor, uint256 circuitId);
    event Rejected(uint256 indexed orderId, uint256 caseIndex);
    event Paid(uint256 indexed orderId, address indexed builder, address processor, uint256 circuitId);
    event Refunded(uint256 indexed orderId, address indexed buyer, uint96 amount);
    event FeesClaimed(address indexed to, uint256 amount);
    event Receipt(uint256 indexed orderId, address processor, uint256 circuitId, bytes32 tableHash);

    error FeeTooHigh();
    error ZeroAddress();
    error BuilderRequired();
    error TooManyCases();
    error TooManyOutputs();
    error WrongTableLength();
    error TablePaddingNotZero();
    error DeadlinePassed();
    error ZeroAmount();
    error ReceivedLessThanAmount();
    error NoSuchOrder();
    error NotOpen();
    error NotChecking();
    error NotProcessor();
    error NotBuilder();
    error NotCircuitOwner();
    error ShapeMismatch();
    error TooManyGates();
    error CircuitChanged();
    error InsufficientGasForCase();
    error CircuitTooBigToCheck();
    error WrongAnswer(uint256 caseIndex);
    error GraceOver();
    error NotBuyer();
    error RefundNotAllowed();
    error UnsupportedStateBits();
    error NotPaid();
    error WrongLabelCount();
    error BadInputs();
    error ShortOutput();

    constructor(address factory_, address usdt_, address feeRecipient_, uint16 feeBps_) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (factory_ == address(0) || usdt_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        factory = factory_;
        usdt = IERC20(usdt_);
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    /// @notice Lock `amount` for a circuit with `nIn` inputs and `nOut` outputs that matches `table`.
    /// `builder` must be named: only that address may deliver. Open orders (anyone delivers) are not offered,
    /// because anyone could mint a copy of, or wrap, the honest builder's circuit and deliver it first.
    function createOrder(
        uint8 nIn,
        uint8 nOut,
        bytes calldata table,
        uint96 amount,
        uint64 deadline,
        address builder,
        uint32 maxGates
    ) external nonReentrant returns (uint256 orderId) {
        orderId = _create(nIn, nOut, 0, table, Terms(amount, deadline, builder, maxGates));
        _pull(amount);
    }

    /// @notice createOrder with names for the inputs: `labels` has nIn entries (input x0 first), or none.
    function createOrder(
        uint8 nIn,
        uint8 nOut,
        bytes calldata table,
        uint96 amount,
        uint64 deadline,
        address builder,
        uint32 maxGates,
        bytes32[] calldata labels
    ) external nonReentrant returns (uint256 orderId) {
        orderId = _create(nIn, nOut, 0, table, Terms(amount, deadline, builder, maxGates));
        _setLabels(orderId, labels, nIn);
        _pull(amount);
    }

    /// @notice Lock `amount` for a memory circuit: `nIn` inputs, `nOut` outputs and `nState` memory bits, checked
    /// with TapeOut's `step`. Only nState == 1 is offered (use createOrder for no memory).
    /// Packing: the table has 2^(nIn + nState) cases. Case c's inputs are c & (2^nIn - 1) (the low bits of c) and
    /// its starting state is c >> nIn (the bits above). Its expected answer is nOut + nState bits: the outputs in
    /// the low nOut bits, the new state in the nState bits above them. Answers are concatenated LSB first, so case
    /// c's answer starts at table bit c * (nOut + nState). See TableLib.
    function createStatefulOrder(
        uint8 nIn,
        uint8 nOut,
        uint8 nState,
        bytes calldata table,
        uint96 amount,
        uint64 deadline,
        address builder,
        uint32 maxGates
    ) external nonReentrant returns (uint256 orderId) {
        if (nState != 1) revert UnsupportedStateBits();
        orderId = _create(nIn, nOut, nState, table, Terms(amount, deadline, builder, maxGates));
        _pull(amount);
    }

    /// @notice createStatefulOrder with names: `labels` has nIn + nState entries (inputs x0.. first, then the
    /// memory bit), or none.
    function createStatefulOrder(
        uint8 nIn,
        uint8 nOut,
        uint8 nState,
        bytes calldata table,
        uint96 amount,
        uint64 deadline,
        address builder,
        uint32 maxGates,
        bytes32[] calldata labels
    ) external nonReentrant returns (uint256 orderId) {
        if (nState != 1) revert UnsupportedStateBits();
        Terms memory t = Terms(amount, deadline, builder, maxGates);
        orderId = _createLabelled(nIn, nOut, nState, table, t, labels);
    }

    /// @notice The input names given at creation (empty when none were given).
    function labelsOf(uint256 orderId) external view returns (bytes32[] memory) {
        return _labels[orderId];
    }

    function _createLabelled(
        uint8 nIn,
        uint8 nOut,
        uint8 nState,
        bytes calldata table,
        Terms memory t,
        bytes32[] calldata labels
    ) internal returns (uint256 orderId) {
        orderId = _create(nIn, nOut, nState, table, t);
        _setLabels(orderId, labels, uint256(nIn) + nState);
        _pull(t.amount);
    }

    function _setLabels(uint256 orderId, bytes32[] calldata labels, uint256 n) internal {
        if (labels.length == 0) return;
        if (labels.length != n) revert WrongLabelCount();
        _labels[orderId] = labels;
    }

    function _create(
        uint8 nIn,
        uint8 nOut,
        uint8 nState,
        bytes calldata table,
        Terms memory t
    ) internal returns (uint256 orderId) {
        if (uint256(nIn) + nState > MAX_CASE_BITS) revert TooManyCases();
        if (nOut == 0 || uint256(nOut) + nState > MAX_ANSWER_BITS) revert TooManyOutputs();
        uint256 cases = uint256(1) << (uint256(nIn) + nState);
        uint256 tableBits = cases * (uint256(nOut) + nState);
        if (table.length != TableLib.byteLength(cases, uint256(nOut) + nState)) revert WrongTableLength();
        // Unused high bits of the last byte must be zero, so each rule has exactly one valid table.
        if (tableBits % 8 != 0 && uint8(table[table.length - 1]) >> (tableBits % 8) != 0) {
            revert TablePaddingNotZero();
        }
        if (t.deadline <= block.timestamp) revert DeadlinePassed();
        if (t.amount == 0) revert ZeroAmount();
        if (t.builder == address(0)) revert BuilderRequired();

        orderId = nextOrderId++;
        orders[orderId] = Order({
            buyer: msg.sender,
            builder: t.builder,
            amount: t.amount,
            deadline: t.deadline,
            maxGates: t.maxGates,
            nIn: nIn,
            nOut: nOut,
            nState: nState,
            status: Status.Open
        });
        tableOf[orderId] = table;
        emit OrderCreated(orderId, msg.sender, t.amount, t.deadline);
    }

    /// @dev Every create function calls this last, after all state is written: pull the money and check the full
    /// amount arrived (guards against a fee-on-transfer upgrade).
    function _pull(uint96 amount) internal {
        uint256 before = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        if (usdt.balanceOf(address(this)) - before != amount) revert ReceivedLessThanAmount();
    }

    /// @notice Offer circuit `circuitId` on `processor` for order `orderId`. The caller must be the order's named
    /// builder and must own the circuit.
    function deliver(uint256 orderId, address processor, uint256 circuitId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.buyer == address(0)) revert NoSuchOrder();
        if (o.status != Status.Open) revert NotOpen();
        if (block.timestamp > o.deadline) revert DeadlinePassed();
        if (!IProcessorFactory(factory).isCPU(processor)) revert NotProcessor();
        if (o.builder != address(0) && msg.sender != o.builder) revert NotBuilder();
        // ownerOf reverts for an id that does not exist; treat that as "not yours".
        try IProcessor(processor).ownerOf(circuitId) returns (address owner) {
            if (owner != msg.sender) revert NotCircuitOwner();
        } catch {
            revert NotCircuitOwner();
        }
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = IProcessor(processor).circuitInfo(circuitId);
        if (nIn != o.nIn || nOut != o.nOut || nState != o.nState) revert ShapeMismatch();
        if (o.maxGates != 0 && gates > o.maxGates) revert TooManyGates();
        if (evalBudget(gates) > MAX_CASE_GAS) revert CircuitTooBigToCheck();

        deliveries[orderId] = Delivery({
            processor: processor,
            circuitId: circuitId,
            builder: msg.sender,
            gateCount: gates,
            netlistHash: keccak256(IProcessor(processor).netlist(circuitId)),
            nextCase: 0
        });
        o.status = Status.Checking;
        emit Delivered(orderId, msg.sender, processor, circuitId);

        _checkInlineIfSmall(orderId, o, gates);
    }

    /// @dev Small circuit: check every case now and pay. Any wrong answer reverts the whole delivery.
    function _checkInlineIfSmall(uint256 orderId, Order storage o, uint256 gates) internal {
        uint256 total = _cases(o);
        uint256 budget = evalBudget(gates);
        if (total * budget > INLINE_CHECK_MAX_GAS) return;
        Delivery storage d = deliveries[orderId];
        (bool ok, uint256 c) = _runCases(o, d, tableOf[orderId], 0, total, budget);
        if (!ok) revert WrongAnswer(c);
        d.nextCase = uint32(total);
        _pay(orderId, o, d);
    }

    /// @notice Run up to `maxCases` more cases of a delivered circuit. Anyone may call.
    /// @return done true when the check finished (passed or rejected) in this call.
    /// @return passed true when every case matched and the builder was paid.
    function check(uint256 orderId, uint256 maxCases) external nonReentrant returns (bool done, bool passed) {
        Order storage o = orders[orderId];
        if (o.status != Status.Checking) revert NotChecking();
        // A check under way at the deadline may finish during the grace period, not after it.
        if (block.timestamp > uint256(o.deadline) + GRACE) revert GraceOver();
        Delivery storage d = deliveries[orderId];
        _requireUnchanged(o, d);

        uint256 total = _cases(o);
        uint256 start = d.nextCase;
        uint256 end = maxCases >= total - start ? total : start + maxCases;

        (bool ok, uint256 c) = _runCases(o, d, tableOf[orderId], start, end, evalBudget(d.gateCount));
        if (!ok) {
            delete deliveries[orderId];
            o.status = Status.Open;
            emit Rejected(orderId, c);
            return (true, false);
        }
        d.nextCase = uint32(end);
        if (end < total) return (false, false);

        _pay(orderId, o, d);
        return (true, true);
    }

    /// @notice The buyer takes the money back: after the deadline when no delivery is being checked, or after
    /// deadline + GRACE when one still is.
    function refund(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyer();
        uint256 t = block.timestamp;
        bool allowed = (o.status == Status.Open && t > o.deadline)
            || (o.status == Status.Checking && t > uint256(o.deadline) + GRACE);
        if (!allowed) revert RefundNotAllowed();
        o.status = Status.Refunded;
        delete deliveries[orderId];
        emit Refunded(orderId, msg.sender, o.amount);
        usdt.safeTransfer(msg.sender, o.amount);
    }

    /// @notice Send all owed fees to the fixed fee recipient. Anyone may call.
    function claimFees() external nonReentrant {
        uint256 amount = feesOwed;
        feesOwed = 0;
        emit FeesClaimed(feeRecipient, amount);
        if (amount > 0) usdt.safeTransfer(feeRecipient, amount);
    }

    /// @dev The processor is upgradeable; refuse to judge a circuit that is no longer the one delivered.
    function _requireUnchanged(Order storage o, Delivery storage d) internal view {
        IProcessor p = IProcessor(d.processor);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = p.circuitInfo(d.circuitId);
        if (gates != d.gateCount || nIn != o.nIn || nOut != o.nOut || nState != o.nState) revert CircuitChanged();
        if (keccak256(p.netlist(d.circuitId)) != d.netlistHash) revert CircuitChanged();
    }

    /// @dev Status and fee bookkeeping first, then the one transfer to the builder (checks-effects-interactions).
    /// Fee rounds down. The fee is only recorded here; claimFees sends it.
    function _pay(uint256 orderId, Order storage o, Delivery storage d) internal {
        o.status = Status.Paid;
        address payee = d.builder;
        uint256 fee = uint256(o.amount) * feeBps / 10_000;
        feesOwed += fee;
        _writeReceipt(orderId, d);
        emit Paid(orderId, payee, d.processor, d.circuitId);
        usdt.safeTransfer(payee, o.amount - fee);
    }

    /// @dev Written once, at payout, before the transfer. The fingerprint covers the order's shape as well as the
    /// table bytes: the same bytes mean a different rule under a different shape (0x06 is XOR for 2 inputs and 1
    /// output, something else for 2 inputs and 2 outputs). nIn, nOut, nState are uint8, so this hashes 3 bytes and
    /// then the table.
    function _writeReceipt(uint256 orderId, Delivery storage d) internal {
        PaidReceipt storage r = receipts[orderId];
        Order storage o = orders[orderId];
        r.processor = d.processor;
        r.circuitId = d.circuitId;
        r.tableHash = keccak256(abi.encodePacked(o.nIn, o.nOut, o.nState, tableOf[orderId]));
        r.blockNumber = uint64(block.number);
        emit Receipt(orderId, r.processor, r.circuitId, r.tableHash);
    }

    /// @notice The rule a paid order bought: the circuit that passed every case. Reverts NotPaid otherwise.
    function ruleOf(uint256 orderId) external view returns (address processor, uint256 circuitId) {
        if (orders[orderId].status != Status.Paid) revert NotPaid();
        PaidReceipt storage r = receipts[orderId];
        return (r.processor, r.circuitId);
    }

    /// @notice Run the paid circuit of an order without memory on `inputs` (ceil(nIn/8) bytes, LSB first, bits
    /// above nIn zero). Returns the outputs as ceil(nOut/8) bytes with the padding bits above nOut zeroed, which
    /// is exactly what check compared. The same guards as check apply: the order must be Paid, the circuit must be
    /// unchanged since delivery (else CircuitChanged), and eval gets exactly evalBudget(gateCount) gas, so a caller
    /// with too little gas (for example an RPC that caps eth_call) gets InsufficientGasForCase, never an answer.
    /// Any revert inside eval reverts this call.
    function run(uint256 orderId, bytes calldata inputs) external view returns (bytes memory outputs) {
        Order storage o = _paidOrder(orderId);
        if (o.nState != 0 || !_fits(inputs, o.nIn)) revert BadInputs();
        Delivery storage d = deliveries[orderId];
        uint256 budget = _paidBudget(o, d);
        return _low(IProcessor(d.processor).eval{gas: budget}(d.circuitId, inputs), o.nOut);
    }

    /// @notice runStep for an order with memory: one tick of the paid circuit from memory `state` (ceil(nState/8)
    /// bytes) on `inputs`. Returns (newState, outputs), the same order as TapeOut's step, each with padding zeroed.
    /// Same guards as run.
    function runStep(uint256 orderId, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs)
    {
        Order storage o = _paidOrder(orderId);
        if (o.nState == 0 || !_fits(inputs, o.nIn) || !_fits(state, o.nState)) revert BadInputs();
        Delivery storage d = deliveries[orderId];
        uint256 budget = _paidBudget(o, d);
        (newState, outputs) = IProcessor(d.processor).step{gas: budget}(d.circuitId, state, inputs);
        return (_low(newState, o.nState), _low(outputs, o.nOut));
    }

    function _paidOrder(uint256 orderId) internal view returns (Order storage o) {
        o = orders[orderId];
        if (o.status != Status.Paid) revert NotPaid();
    }

    /// @dev The circuit must be the one delivered, and the caller must leave room for its full budget.
    function _paidBudget(Order storage o, Delivery storage d) internal view returns (uint256 budget) {
        _requireUnchanged(o, d);
        budget = evalBudget(d.gateCount);
        _requireCaseGas(budget);
    }

    /// @dev Exactly ceil(nBits/8) bytes and no bit set above nBits.
    function _fits(bytes calldata b, uint256 nBits) internal pure returns (bool) {
        if (b.length != (nBits + 7) / 8) return false;
        return nBits % 8 == 0 || uint8(b[b.length - 1]) >> (nBits % 8) == 0;
    }

    /// @dev The low nBits of b, packed again so the padding is zero. Too few bytes is an error, never zeros.
    function _low(bytes memory b, uint256 nBits) internal pure returns (bytes memory) {
        if (b.length < (nBits + 7) / 8) revert ShortOutput();
        return BitLib.pack(BitLib.lowBits(b, nBits), nBits);
    }

    /// @dev A call can pass on at most 63/64 of the gas left (EIP-150); keep enough so the circuit gets all of
    /// `budget`. Shared by check, deliver's inline check, run and runStep.
    function _requireCaseGas(uint256 budget) internal view {
        if (gasleft() < budget * 64 / 63 + GAS_RESERVE) revert InsufficientGasForCase();
    }

    /// @notice The gas each case's eval gets for a circuit of `gateCount` gates (REF'd gates included).
    function evalBudget(uint256 gateCount) public pure returns (uint256) {
        return EVAL_BASE_GAS + EVAL_GAS_PER_GATE * gateCount;
    }

    /// @dev Every order has 2^(nIn + nState) cases (memory bits count as inputs to the table).
    function _cases(Order storage o) internal view returns (uint256) {
        return uint256(1) << (uint256(o.nIn) + o.nState);
    }

    /// @dev Run cases [from, to). Returns (true, to) if all match, else (false, first wrong case).
    function _runCases(
        Order storage o,
        Delivery storage d,
        bytes memory table,
        uint256 from,
        uint256 to,
        uint256 budget
    ) internal view returns (bool, uint256) {
        uint256 w = uint256(o.nOut) + o.nState;
        for (uint256 c = from; c < to; ++c) {
            if (!_caseMatches(d, c, o, table, w, budget)) return (false, c);
        }
        return (true, to);
    }

    /// @dev The circuit's answer to case c, packed the way the table packs it: outputs in the low nOut bits, new
    /// state in the nState bits above. Inputs are c & (2^nIn - 1), state is c >> nIn, each packed LSB first.
    /// No memory: eval(id, inputs). Memory: step(id, state, inputs). The call gets exactly `budget` gas. If the
    /// caller cannot give it that much, the whole call reverts and nothing is recorded. A revert inside the call
    /// (including running out of the budget) or a short return is ok == false, a wrong answer: it is the circuit's
    /// own fault and the same for every caller. Padding bits above nOut and above nState are ignored.
    function _caseMatches(
        Delivery storage d,
        uint256 c,
        Order storage o,
        bytes memory table,
        uint256 w,
        uint256 budget
    ) internal view returns (bool) {
        (bool ok, uint256 got) = _answer(IProcessor(d.processor), d.circuitId, c, o, budget);
        return ok && got == TableLib.expected(table, c, w);
    }

    function _answer(IProcessor p, uint256 id, uint256 c, Order storage o, uint256 budget)
        internal
        view
        returns (bool, uint256)
    {
        bytes memory inputs = BitLib.pack(c, o.nIn); // pack keeps only the low nIn bits
        bytes memory state = BitLib.pack(c >> o.nIn, o.nState); // empty when there is no memory
        _requireCaseGas(budget);
        if (state.length == 0) return _evalAnswer(p, id, inputs, o.nOut, budget);
        return _stepAnswer(p, id, state, inputs, o, budget);
    }

    function _evalAnswer(IProcessor p, uint256 id, bytes memory inputs, uint256 nOut, uint256 budget)
        internal
        view
        returns (bool, uint256)
    {
        try p.eval{gas: budget}(id, inputs) returns (bytes memory out) {
            if (out.length < (nOut + 7) / 8) return (false, 0);
            return (true, BitLib.lowBits(out, nOut));
        } catch {
            return (false, 0);
        }
    }

    function _stepAnswer(
        IProcessor p,
        uint256 id,
        bytes memory state,
        bytes memory inputs,
        Order storage o,
        uint256 budget
    ) internal view returns (bool, uint256) {
        try p.step{gas: budget}(id, state, inputs) returns (bytes memory newState, bytes memory out) {
            return _packStep(newState, out, o.nOut, o.nState);
        } catch {
            return (false, 0);
        }
    }

    /// @dev outputs low, new state above; too few bytes in either is a wrong answer.
    function _packStep(bytes memory newState, bytes memory out, uint256 nOut, uint256 nState)
        internal
        pure
        returns (bool, uint256)
    {
        if (out.length < (nOut + 7) / 8 || newState.length < (nState + 7) / 8) return (false, 0);
        return (true, BitLib.lowBits(out, nOut) | (BitLib.lowBits(newState, nState) << nOut));
    }
}
