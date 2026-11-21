// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TableLib} from "./TableLib.sol";
import {FormulaLib, Piece, PieceKind} from "./FormulaLib.sol";
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
    /// @notice A pieced order has 1 or 2 pieces (V3a). Chains of more pieces need a wiring map (later version).
    uint256 public constant MAX_PIECES = 2;
    /// @notice Formula pieces have at most 17 inputs (131,072 cases), checked in batches with checkPiece.
    uint256 public constant MAX_FORMULA_BITS = 17;

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
    /// @dev The pieces of a pieced order; empty for V0-V2 orders, which keep using tableOf and deliveries.
    mapping(uint256 => Piece[]) internal _pieces;
    /// @notice A pieced order's piece i delivery and check cursor, the same fields as deliveries. Piece states:
    /// no delivery (processor == 0), being checked (nextCase < 2^nIn), passed (nextCase == 2^nIn).
    mapping(uint256 => mapping(uint256 => Delivery)) public pieceOf;
    /// @notice The truth table of a Table piece (empty for formula pieces).
    mapping(uint256 => mapping(uint256 => bytes)) public pieceTableOf;
    /// @notice Gate cap per piece (zero = no cap).
    mapping(uint256 => mapping(uint256 => uint32)) public pieceMaxGatesOf;

    event OrderCreated(uint256 indexed orderId, address indexed buyer, uint96 amount, uint64 deadline);
    event Delivered(uint256 indexed orderId, address indexed builder, address processor, uint256 circuitId);
    event Rejected(uint256 indexed orderId, uint256 caseIndex);
    event Paid(uint256 indexed orderId, address indexed builder, address processor, uint256 circuitId);
    event Refunded(uint256 indexed orderId, address indexed buyer, uint96 amount);
    event FeesClaimed(address indexed to, uint256 amount);
    event Receipt(uint256 indexed orderId, address processor, uint256 circuitId, bytes32 tableHash);
    event PieceDelivered(uint256 indexed orderId, uint256 indexed pieceIndex, address processor, uint256 circuitId);
    event PieceRejected(uint256 indexed orderId, uint256 indexed pieceIndex, uint256 caseIndex);
    event PiecePassed(uint256 indexed orderId, uint256 indexed pieceIndex);

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
    error WrongOrderKind();
    error BadPiece();
    error BadPieceCount();
    error NoSuchPiece();
    error PieceAlreadyPassed();
    error NoSingleCircuit();

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
        _checkTable(nIn, nOut, nState, table);
        orderId = _newOrder(nIn, nOut, nState, t);
        tableOf[orderId] = table;
    }

    /// @dev The V0 table rules, shared by Table pieces (with nState 0).
    function _checkTable(uint8 nIn, uint8 nOut, uint8 nState, bytes calldata table) internal pure {
        if (uint256(nIn) + nState > MAX_CASE_BITS) revert TooManyCases();
        if (nOut == 0 || uint256(nOut) + nState > MAX_ANSWER_BITS) revert TooManyOutputs();
        uint256 cases = uint256(1) << (uint256(nIn) + nState);
        uint256 tableBits = cases * (uint256(nOut) + nState);
        if (table.length != TableLib.byteLength(cases, uint256(nOut) + nState)) revert WrongTableLength();
        // Unused high bits of the last byte must be zero, so each rule has exactly one valid table.
        if (tableBits % 8 != 0 && uint8(table[table.length - 1]) >> (tableBits % 8) != 0) {
            revert TablePaddingNotZero();
        }
    }

    function _newOrder(uint8 nIn, uint8 nOut, uint8 nState, Terms memory t) internal returns (uint256 orderId) {
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
        Order storage o = _openOrder(orderId, false);
        uint32 gates = _acceptCircuit(o, processor, circuitId, o.nIn, o.nOut, o.nState, o.maxGates);
        _record(deliveries[orderId], processor, circuitId, gates);
        o.status = Status.Checking;
        emit Delivered(orderId, msg.sender, processor, circuitId);

        _checkInlineIfSmall(orderId, o, gates);
    }

    /// @dev The order exists, is of the expected kind (pieced or not), is Open and the deadline has not passed.
    /// A pieced order has no table in tableOf, so the V0 path must never check one (an all-zero circuit would match
    /// its empty table); a V0 order has no pieces.
    function _openOrder(uint256 orderId, bool pieced) internal view returns (Order storage o) {
        o = orders[orderId];
        if (o.buyer == address(0)) revert NoSuchOrder();
        if ((_pieces[orderId].length != 0) != pieced) revert WrongOrderKind();
        if (o.status != Status.Open) revert NotOpen();
        if (block.timestamp > o.deadline) revert DeadlinePassed();
    }

    /// @dev The delivery guards shared by deliver and deliverPiece: a TapeOut processor, the named builder, who owns
    /// the circuit, the right shape, under the gate cap, and small enough that one case fits in a transaction.
    function _acceptCircuit(
        Order storage o,
        address processor,
        uint256 circuitId,
        uint256 wantIn,
        uint256 wantOut,
        uint256 wantState,
        uint32 maxGates
    ) internal view returns (uint32 gates) {
        if (!IProcessorFactory(factory).isCPU(processor)) revert NotProcessor();
        if (o.builder != address(0) && msg.sender != o.builder) revert NotBuilder();
        // ownerOf reverts for an id that does not exist; treat that as "not yours".
        try IProcessor(processor).ownerOf(circuitId) returns (address owner) {
            if (owner != msg.sender) revert NotCircuitOwner();
        } catch {
            revert NotCircuitOwner();
        }
        uint32 nIn;
        uint32 nOut;
        uint32 nState;
        (nIn, nOut, nState, gates) = IProcessor(processor).circuitInfo(circuitId);
        if (nIn != wantIn || nOut != wantOut || nState != wantState) revert ShapeMismatch();
        if (maxGates != 0 && gates > maxGates) revert TooManyGates();
        if (evalBudget(gates) > MAX_CASE_GAS) revert CircuitTooBigToCheck();
    }

    /// @dev Record a delivery with its gate count and netlist hash, cursor at case 0.
    function _record(Delivery storage d, address processor, uint256 circuitId, uint32 gates) internal {
        d.processor = processor;
        d.circuitId = circuitId;
        d.builder = msg.sender;
        d.gateCount = gates;
        d.netlistHash = keccak256(IProcessor(processor).netlist(circuitId));
        d.nextCase = 0;
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
        uint256 n = _pieces[orderId].length;
        bool allowed = n == 0
            ? (o.status == Status.Open && t > o.deadline) || (o.status == Status.Checking && t > uint256(o.deadline) + GRACE)
            : o.status == Status.Open && t > o.deadline && (t > uint256(o.deadline) + GRACE || !_allDelivered(orderId, n));
        if (!allowed) revert RefundNotAllowed();
        o.status = Status.Refunded;
        delete deliveries[orderId];
        for (uint256 i = 0; i < n; ++i) {
            delete pieceOf[orderId][i];
        }
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

    // ---- pieced orders (V3a: two-piece rules, Lathe joins the pieces) ----

    /// @notice Lock `amount` for a rule made of 1 or 2 pieces. Each piece is its own circuit with no memory, delivered
    /// with deliverPiece and checked on every one of its 2^nIn cases like a V0 delivery. The order pays the named
    /// builder once every piece has passed. `tables[i]` is piece i's truth table for a Table piece (V0 rules, at
    /// most 6 inputs) and empty for a formula piece (at most 17 inputs; the contract computes the answer, see
    /// FormulaLib for the a / b bit layout). `maxGates[i]` caps piece i's gates (0 = no cap). `labels` names the
    /// order's top-level inputs (nIn entries) or is empty.
    /// Join of two pieces A = pieces[0], B = pieces[1] (B.nIn >= A.nOut): the order's input x has
    /// nIn = A.nIn + B.nIn - A.nOut bits, LSB first. A gets x's bits 0 .. A.nIn-1. B gets A's outputs in its low
    /// A.nOut input bits and x's remaining bits (x >> A.nIn) above them: B.in = outA | ((x >> A.nIn) << A.nOut).
    /// The order's outputs are B's outputs. orders(id) records the top-level nIn, B's nOut, nState 0, maxGates 0.
    function createPiecedOrder(
        Piece[] calldata pieces,
        bytes[] calldata tables,
        uint96 amount,
        uint64 deadline,
        address builder,
        uint32[] calldata maxGates,
        bytes32[] calldata labels
    ) external nonReentrant returns (uint256 orderId) {
        (uint8 nIn, uint8 nOut) = _checkPieces(pieces, tables, maxGates);
        orderId = _newOrder(nIn, nOut, 0, Terms(amount, deadline, builder, 0));
        for (uint256 i = 0; i < pieces.length; ++i) {
            _pieces[orderId].push(pieces[i]);
            pieceTableOf[orderId][i] = tables[i];
            pieceMaxGatesOf[orderId][i] = maxGates[i];
        }
        _setLabels(orderId, labels, nIn);
        _pull(amount);
    }

    /// @dev Returns the order's top-level shape.
    function _checkPieces(Piece[] calldata pieces, bytes[] calldata tables, uint32[] calldata maxGates)
        internal
        pure
        returns (uint8 nIn, uint8 nOut)
    {
        uint256 n = pieces.length;
        if (n == 0 || n > MAX_PIECES || tables.length != n || maxGates.length != n) revert BadPieceCount();
        for (uint256 i = 0; i < n; ++i) {
            _checkPiece(pieces[i], tables[i]);
        }
        nIn = pieces[0].nIn;
        nOut = pieces[n - 1].nOut;
        if (n == 2) {
            if (pieces[1].nIn < pieces[0].nOut) revert BadPiece();
            nIn = pieces[0].nIn + pieces[1].nIn - pieces[0].nOut;
        }
    }

    function _checkPiece(Piece calldata p, bytes calldata table) internal pure {
        if (p.kind == PieceKind.Table) {
            if (p.widthA != 0 || p.widthB != 0) revert BadPiece();
            _checkTable(p.nIn, p.nOut, 0, table);
            return;
        }
        if (table.length != 0) revert WrongTableLength();
        uint256 w = uint256(p.widthA) + p.widthB;
        if (w > MAX_FORMULA_BITS) revert TooManyCases();
        uint256 out = p.kind == PieceKind.Add ? uint256(p.widthA) + 1 : 1;
        if (p.widthA == 0 || p.widthB == 0 || p.nIn != w || p.nOut != out) revert BadPiece();
        if (p.kind == PieceKind.Add && p.widthA < p.widthB) revert BadPiece();
    }

    /// @notice Offer circuit `circuitId` on `processor` as piece `pieceIndex` of a pieced order. Same guards as
    /// deliver (named builder, owns the circuit, shape = the piece's nIn / nOut with no memory, gate cap, per-case
    /// budget). A piece with no delivery can be delivered until the deadline; a piece being checked cannot
    /// (NotOpen) and a passed piece never can (PieceAlreadyPassed). When 2^nIn x evalBudget(gates) <= 30M the piece
    /// is checked here and a wrong answer reverts; otherwise anyone pushes the check with checkPiece.
    function deliverPiece(uint256 orderId, uint256 pieceIndex, address processor, uint256 circuitId)
        external
        nonReentrant
    {
        Order storage o = _openOrder(orderId, true);
        Piece memory p = _undeliveredPiece(orderId, pieceIndex);
        uint32 gates = _acceptCircuit(o, processor, circuitId, p.nIn, p.nOut, 0, pieceMaxGatesOf[orderId][pieceIndex]);
        Delivery storage d = pieceOf[orderId][pieceIndex];
        _record(d, processor, circuitId, gates);
        emit PieceDelivered(orderId, pieceIndex, processor, circuitId);
        _checkPieceInlineIfSmall(orderId, pieceIndex, o, p, d);
    }

    function _undeliveredPiece(uint256 orderId, uint256 pieceIndex) internal view returns (Piece memory p) {
        p = _piece(orderId, pieceIndex);
        Delivery storage d = pieceOf[orderId][pieceIndex];
        if (d.processor != address(0)) {
            if (d.nextCase == uint256(1) << p.nIn) revert PieceAlreadyPassed();
            revert NotOpen();
        }
    }

    /// @dev Same rule as deliver: small enough means every case now, and a wrong answer reverts the delivery.
    function _checkPieceInlineIfSmall(
        uint256 orderId,
        uint256 pieceIndex,
        Order storage o,
        Piece memory p,
        Delivery storage d
    ) internal {
        uint256 total = uint256(1) << p.nIn;
        uint256 budget = evalBudget(d.gateCount);
        if (total * budget > INLINE_CHECK_MAX_GAS) return;
        (bool ok, uint256 c) = _runPieceCases(orderId, pieceIndex, p, d, 0, total, budget);
        if (!ok) revert WrongAnswer(c);
        _piecePassed(orderId, pieceIndex, o, d, total);
    }

    /// @notice Run up to `maxCases` more cases of piece `pieceIndex`. Anyone may call, until deadline + GRACE. Each
    /// case needs evalBudget(gateCount) gas or the whole call reverts (InsufficientGasForCase) and nothing changes,
    /// so too little gas can never mark an honest piece wrong. A wrong case clears only this piece's delivery
    /// (PieceRejected); the other piece keeps its state. When this piece passes and every piece has passed, the
    /// order pays.
    /// @return done true when this piece's check finished (passed or rejected) in this call.
    /// @return passed true when this piece matched on every case.
    function checkPiece(uint256 orderId, uint256 pieceIndex, uint256 maxCases)
        external
        nonReentrant
        returns (bool done, bool passed)
    {
        Order storage o = orders[orderId];
        if (_pieces[orderId].length == 0) revert WrongOrderKind();
        Piece memory p = _piece(orderId, pieceIndex);
        Delivery storage d = pieceOf[orderId][pieceIndex];
        uint256 total = uint256(1) << p.nIn;
        if (o.status != Status.Open || d.processor == address(0) || d.nextCase >= total) revert NotChecking();
        if (block.timestamp > uint256(o.deadline) + GRACE) revert GraceOver();
        _requireSame(d, p.nIn, p.nOut, 0);

        uint256 start = d.nextCase;
        uint256 end = maxCases >= total - start ? total : start + maxCases;
        (bool ok, uint256 c) = _runPieceCases(orderId, pieceIndex, p, d, start, end, evalBudget(d.gateCount));
        if (!ok) {
            delete pieceOf[orderId][pieceIndex];
            emit PieceRejected(orderId, pieceIndex, c);
            return (true, false);
        }
        d.nextCase = uint32(end);
        if (end < total) return (false, false);
        _piecePassed(orderId, pieceIndex, o, d, total);
        return (true, true);
    }

    /// @notice The pieces of a pieced order (empty for a V0-V2 order).
    function piecesOf(uint256 orderId) external view returns (Piece[] memory) {
        return _pieces[orderId];
    }

    /// @notice A pieced order's fingerprint, the tableHash in its receipt: keccak256(abi.encode(pieces, tables)) with
    /// tables[i] = pieceTableOf(orderId, i). It cannot equal a V0 tableHash preimage: abi.encode starts with the
    /// 32-byte offset 0x40, so its first bytes would read as nIn = nOut = 0, which no V0 order has.
    function piecedHash(uint256 orderId) public view returns (bytes32) {
        Piece[] memory ps = _pieces[orderId];
        bytes[] memory ts = new bytes[](ps.length);
        for (uint256 i = 0; i < ps.length; ++i) {
            ts[i] = pieceTableOf[orderId][i];
        }
        return keccak256(abi.encode(ps, ts));
    }

    function _piece(uint256 orderId, uint256 pieceIndex) internal view returns (Piece memory) {
        if (pieceIndex >= _pieces[orderId].length) revert NoSuchPiece();
        return _pieces[orderId][pieceIndex];
    }

    /// @dev Mark the piece passed; when every piece has passed, check every piece's circuit again (gate count and
    /// netlist hash, so a piece that passed earlier and then changed is never paid for) and pay. A change reverts
    /// CircuitChanged: the order cannot pay and the buyer refunds after deadline + GRACE.
    /// Receipt: a 1-piece order names its circuit; a 2-piece order has no single circuit, so processor and id are 0.
    function _piecePassed(uint256 orderId, uint256 pieceIndex, Order storage o, Delivery storage d, uint256 total)
        internal
    {
        d.nextCase = uint32(total);
        emit PiecePassed(orderId, pieceIndex);
        if (!_allPassedUnchanged(orderId)) return;
        Delivery storage first = pieceOf[orderId][0];
        bool single = _pieces[orderId].length == 1;
        _payOut(
            orderId,
            o,
            o.builder,
            single ? first.processor : address(0),
            single ? first.circuitId : 0,
            piecedHash(orderId)
        );
    }

    /// @dev False while any piece has not passed. Once all have, reverts CircuitChanged if any piece's circuit
    /// changed since its delivery.
    function _allPassedUnchanged(uint256 orderId) internal view returns (bool) {
        Piece[] storage ps = _pieces[orderId];
        uint256 n = ps.length;
        for (uint256 i = 0; i < n; ++i) {
            Delivery storage e = pieceOf[orderId][i];
            if (e.processor == address(0) || e.nextCase != uint256(1) << ps[i].nIn) return false;
        }
        for (uint256 i = 0; i < n; ++i) {
            _requireSame(pieceOf[orderId][i], ps[i].nIn, ps[i].nOut, 0);
        }
        return true;
    }

    function _allDelivered(uint256 orderId, uint256 n) internal view returns (bool) {
        for (uint256 i = 0; i < n; ++i) {
            if (pieceOf[orderId][i].processor == address(0)) return false;
        }
        return true;
    }

    /// @dev Run piece cases [from, to). Case c's inputs are c's low nIn bits, LSB first; its expected answer is the
    /// piece's table entry (Table) or FormulaLib.expected (formula), compared on the low nOut output bits.
    function _runPieceCases(
        uint256 orderId,
        uint256 pieceIndex,
        Piece memory p,
        Delivery storage d,
        uint256 from,
        uint256 to,
        uint256 budget
    ) internal view returns (bool, uint256) {
        bytes memory table = p.kind == PieceKind.Table ? pieceTableOf[orderId][pieceIndex] : bytes("");
        for (uint256 c = from; c < to; ++c) {
            if (!_pieceCaseMatches(d, p, table, c, budget)) return (false, c);
        }
        return (true, to);
    }

    function _pieceCaseMatches(Delivery storage d, Piece memory p, bytes memory table, uint256 c, uint256 budget)
        internal
        view
        returns (bool)
    {
        bytes memory inputs = BitLib.pack(c, p.nIn);
        _requireCaseGas(budget);
        (bool ok, uint256 got) = _evalAnswer(IProcessor(d.processor), d.circuitId, inputs, p.nOut, budget);
        uint256 want = p.kind == PieceKind.Table ? TableLib.expected(table, c, p.nOut) : FormulaLib.expected(p, c);
        return ok && got == want;
    }

    /// @dev run for a pieced order: A on x's low A.nIn bits, then B on outA | ((x >> A.nIn) << A.nOut).
    function _runPieces(uint256 orderId, uint256 x) internal view returns (bytes memory) {
        Piece[] storage ps = _pieces[orderId];
        Piece memory a = ps[0];
        uint256 out = _evalPiece(pieceOf[orderId][0], a, x & ((uint256(1) << a.nIn) - 1));
        if (ps.length == 1) return BitLib.pack(out, a.nOut);
        Piece memory b = ps[1];
        out = _evalPiece(pieceOf[orderId][1], b, out | ((x >> a.nIn) << a.nOut));
        return BitLib.pack(out, b.nOut);
    }

    /// @dev One eval of a paid piece with run's guards: unchanged circuit, full budget, enough output bytes.
    function _evalPiece(Delivery storage d, Piece memory p, uint256 x) internal view returns (uint256) {
        _requireSame(d, p.nIn, p.nOut, 0);
        uint256 budget = evalBudget(d.gateCount);
        bytes memory inputs = BitLib.pack(x, p.nIn);
        _requireCaseGas(budget);
        bytes memory out = IProcessor(d.processor).eval{gas: budget}(d.circuitId, inputs);
        if (out.length < (uint256(p.nOut) + 7) / 8) revert ShortOutput();
        return BitLib.lowBits(out, p.nOut);
    }

    /// @dev The processor is upgradeable; refuse to judge a circuit that is no longer the one delivered.
    function _requireUnchanged(Order storage o, Delivery storage d) internal view {
        _requireSame(d, o.nIn, o.nOut, o.nState);
    }

    function _requireSame(Delivery storage d, uint256 wantIn, uint256 wantOut, uint256 wantState) internal view {
        IProcessor p = IProcessor(d.processor);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = p.circuitInfo(d.circuitId);
        if (gates != d.gateCount || nIn != wantIn || nOut != wantOut || nState != wantState) revert CircuitChanged();
        if (keccak256(p.netlist(d.circuitId)) != d.netlistHash) revert CircuitChanged();
    }

    /// @dev Status and fee bookkeeping first, then the one transfer to the builder (checks-effects-interactions).
    /// Fee rounds down. The fee is only recorded here; claimFees sends it.
    /// The receipt fingerprint covers the order's shape as well as the table bytes: the same bytes mean a different
    /// rule under a different shape (0x06 is XOR for 2 inputs and 1 output, something else for 2 inputs and 2
    /// outputs). nIn, nOut, nState are uint8, so this hashes 3 bytes and then the table.
    function _pay(uint256 orderId, Order storage o, Delivery storage d) internal {
        bytes32 h = keccak256(abi.encodePacked(o.nIn, o.nOut, o.nState, tableOf[orderId]));
        _payOut(orderId, o, d.builder, d.processor, d.circuitId, h);
    }

    /// @dev The receipt is written once, here, before the transfer.
    function _payOut(uint256 orderId, Order storage o, address payee, address processor, uint256 circuitId, bytes32 h)
        internal
    {
        o.status = Status.Paid;
        uint256 fee = uint256(o.amount) * feeBps / 10_000;
        feesOwed += fee;
        receipts[orderId] = PaidReceipt(processor, circuitId, h, uint64(block.number));
        emit Receipt(orderId, processor, circuitId, h);
        emit Paid(orderId, payee, processor, circuitId);
        usdt.safeTransfer(payee, o.amount - fee);
    }

    /// @notice The rule a paid order bought: the circuit that passed every case. Reverts NotPaid otherwise.
    /// A 2-piece order has no single circuit (Lathe joins its pieces in run), so it reverts NoSingleCircuit; read
    /// piecesOf and pieceOf instead. A 1-piece order returns its piece's circuit.
    function ruleOf(uint256 orderId) external view returns (address processor, uint256 circuitId) {
        if (orders[orderId].status != Status.Paid) revert NotPaid();
        if (_pieces[orderId].length > 1) revert NoSingleCircuit();
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
        if (_pieces[orderId].length != 0) return _runPieces(orderId, BitLib.readBits(inputs, 0, o.nIn));
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
