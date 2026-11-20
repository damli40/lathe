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

    address public immutable factory;
    IERC20 public immutable usdt;
    address public immutable feeRecipient;
    uint16 public immutable feeBps;

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => bytes) public tableOf;
    mapping(uint256 => Delivery) public deliveries;

    event OrderCreated(uint256 indexed orderId, address indexed buyer, uint96 amount, uint64 deadline);
    event Delivered(uint256 indexed orderId, address indexed builder, address processor, uint256 circuitId);
    event Rejected(uint256 indexed orderId, uint256 caseIndex);
    event Paid(uint256 indexed orderId, address indexed builder, address processor, uint256 circuitId);

    error FeeTooHigh();
    error ZeroAddress();
    error TooManyCases();
    error TooManyOutputs();
    error WrongTableLength();
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
    error EvalOutOfGas();

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
        if (table.length != TableLib.byteLength(cases, uint256(nOut) + nState)) revert WrongTableLength();
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
        Delivery storage d = deliveries[orderId];
        _requireUnchanged(o, d);

        uint256 total = uint256(1) << o.nIn;
        uint256 c = d.nextCase;
        uint256 end = maxCases >= total - c ? total : c + maxCases;
        bytes memory table = tableOf[orderId];

        for (; c < end; ++c) {
            if (!_caseMatches(IProcessor(d.processor), d.circuitId, c, o.nIn, o.nOut, table)) {
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

    /// @dev The processor is upgradeable; refuse to judge a circuit that is no longer the one delivered.
    function _requireUnchanged(Order storage o, Delivery storage d) internal view {
        IProcessor p = IProcessor(d.processor);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = p.circuitInfo(d.circuitId);
        if (gates != d.gateCount || nIn != o.nIn || nOut != o.nOut || nState != o.nState) revert CircuitChanged();
        if (keccak256(p.netlist(d.circuitId)) != d.netlistHash) revert CircuitChanged();
    }

    /// @dev Status first, then the transfers (checks-effects-interactions). Fee rounds down.
    function _pay(uint256 orderId, Order storage o, Delivery storage d) internal {
        o.status = Status.Paid;
        address payee = d.builder;
        uint256 fee = uint256(o.amount) * feeBps / 10_000;
        emit Paid(orderId, payee, d.processor, d.circuitId);
        usdt.safeTransfer(payee, o.amount - fee);
        if (fee > 0) usdt.safeTransfer(feeRecipient, fee);
    }

    /// @dev One case. A revert inside eval counts as a wrong answer, except when eval ran out of gas: then the
    /// whole call reverts, so a caller who sends too little gas cannot get an honest delivery rejected.
    function _caseMatches(
        IProcessor p,
        uint256 id,
        uint256 c,
        uint256 nIn,
        uint256 nOut,
        bytes memory table
    ) internal view returns (bool) {
        bytes memory inputs = BitLib.pack(c, nIn);
        uint256 gasBefore = gasleft();
        try p.eval(id, inputs) returns (bytes memory out) {
            if (out.length < (nOut + 7) / 8) return false;
            return BitLib.lowBits(out, nOut) == TableLib.expected(table, c, nOut);
        } catch {
            // After a call runs out of gas, at most 1/64 of the gas before it is left (EIP-150).
            if (gasleft() <= gasBefore / 63) revert EvalOutOfGas();
            return false;
        }
    }
}
