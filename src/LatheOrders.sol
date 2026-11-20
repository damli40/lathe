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
        address builder; // zero = anyone may deliver
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

    event OrderCreated(uint256 indexed orderId, address indexed buyer, uint96 amount, uint64 deadline);
    event Delivered(uint256 indexed orderId, address indexed builder, address processor, uint256 circuitId);
    event Rejected(uint256 indexed orderId, uint256 caseIndex);
    event Paid(uint256 indexed orderId, address indexed builder, address processor, uint256 circuitId);
    event Refunded(uint256 indexed orderId, address indexed buyer, uint96 amount);
    event FeesClaimed(address indexed to, uint256 amount);

    error FeeTooHigh();
    error ZeroAddress();
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
    error GraceOver();
    error NotBuyer();
    error RefundNotAllowed();

    constructor(address factory_, address usdt_, address feeRecipient_, uint16 feeBps_) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (factory_ == address(0) || usdt_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        factory = factory_;
        usdt = IERC20(usdt_);
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    /// @notice Lock `amount` for a circuit with `nIn` inputs and `nOut` outputs that matches `table`.
    function createOrder(
        uint8 nIn,
        uint8 nOut,
        bytes calldata table,
        uint96 amount,
        uint64 deadline,
        address builder,
        uint32 maxGates
    ) external nonReentrant returns (uint256 orderId) {
        return _create(nIn, nOut, 0, table, amount, deadline, builder, maxGates);
    }

    function _create(
        uint8 nIn,
        uint8 nOut,
        uint8 nState,
        bytes calldata table,
        uint96 amount,
        uint64 deadline,
        address builder,
        uint32 maxGates
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
        if (deadline <= block.timestamp) revert DeadlinePassed();
        if (amount == 0) revert ZeroAmount();

        orderId = nextOrderId++;
        orders[orderId] = Order({
            buyer: msg.sender,
            builder: builder,
            amount: amount,
            deadline: deadline,
            maxGates: maxGates,
            nIn: nIn,
            nOut: nOut,
            nState: nState,
            status: Status.Open
        });
        tableOf[orderId] = table;
        emit OrderCreated(orderId, msg.sender, amount, deadline);

        // Pull the money last, and check the full amount arrived (guards against a fee-on-transfer upgrade).
        uint256 before = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        if (usdt.balanceOf(address(this)) - before != amount) revert ReceivedLessThanAmount();
    }

    /// @notice Offer circuit `circuitId` on `processor` for order `orderId`. The caller must own the circuit.
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

        // V0 orders have no memory bits: cases = 2^nIn and answers are nOut bits. V1 (memory) needs step() and
        // 2^(nIn+nState) cases with nOut+nState-bit answers; this loop must not be reused for it as is.
        assert(o.nState == 0);
        uint256 total = uint256(1) << o.nIn;
        uint256 c = d.nextCase;
        uint256 end = maxCases >= total - c ? total : c + maxCases;
        bytes memory table = tableOf[orderId];
        uint256 budget = evalBudget(d.gateCount);

        for (; c < end; ++c) {
            if (!_caseMatches(IProcessor(d.processor), d.circuitId, c, o.nIn, o.nOut, table, budget)) {
                delete deliveries[orderId];
                o.status = Status.Open;
                emit Rejected(orderId, c);
                return (true, false);
            }
        }
        d.nextCase = uint32(c);
        if (c < total) return (false, false);

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
        emit Paid(orderId, payee, d.processor, d.circuitId);
        usdt.safeTransfer(payee, o.amount - fee);
    }

    /// @notice The gas each case's eval gets for a circuit of `gateCount` gates (REF'd gates included).
    function evalBudget(uint256 gateCount) public pure returns (uint256) {
        return EVAL_BASE_GAS + EVAL_GAS_PER_GATE * gateCount;
    }

    /// @dev One case. eval gets exactly `budget` gas. If the caller cannot give it that much, the whole call
    /// reverts and nothing is recorded. A revert inside eval (including running out of the budget) or a short
    /// output is a wrong answer: it is the circuit's own fault and the same for every caller.
    function _caseMatches(
        IProcessor p,
        uint256 id,
        uint256 c,
        uint256 nIn,
        uint256 nOut,
        bytes memory table,
        uint256 budget
    ) internal view returns (bool) {
        bytes memory inputs = BitLib.pack(c, nIn);
        // A call can pass on at most 63/64 of the gas left (EIP-150); keep enough so eval gets all of `budget`.
        if (gasleft() < budget * 64 / 63 + GAS_RESERVE) revert InsufficientGasForCase();
        try p.eval{gas: budget}(id, inputs) returns (bytes memory out) {
            if (out.length < (nOut + 7) / 8) return false;
            return BitLib.lowBits(out, nOut) == TableLib.expected(table, c, nOut);
        } catch {
            return false;
        }
    }
}
