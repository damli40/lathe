// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TableLib} from "./TableLib.sol";

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

    event OrderCreated(uint256 indexed orderId, address indexed buyer, uint96 amount, uint64 deadline);

    error FeeTooHigh();
    error ZeroAddress();
    error TooManyCases();
    error TooManyOutputs();
    error WrongTableLength();
    error DeadlinePassed();
    error ZeroAmount();
    error ReceivedLessThanAmount();

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
}
