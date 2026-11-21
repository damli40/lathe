// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// The numbers LatheOrders and its two linked libraries (LatheChecks, LatheReads) must agree on. LatheOrders
// exposes each one as a public constant of the same name without the LATHE_ prefix; see LatheOrders for what each
// one means. One copy here, so the contract and the libraries can never disagree.

uint256 constant LATHE_MAX_CASE_BITS = 6;
uint256 constant LATHE_MAX_ANSWER_BITS = 16;
uint256 constant LATHE_EVAL_BASE_GAS = 100_000;
uint256 constant LATHE_EVAL_GAS_PER_GATE = 15_000;
uint256 constant LATHE_GAS_RESERVE = 20_000;
// Pieces per order created with explicit wires (V4). 8 is plenty for the target rules (daily cap: 2, two of three:
// 2, payee guard: a few comparisons joined by yes/no logic). It bounds the work that grows with the piece count:
// run calls every piece once (8 evals, each within its own per-case budget), payout and deliverTop re-read every
// piece's netlist (8 reads), and a REF-only top is 31 + 3 x inputs bytes per piece (under 700 bytes for 8 pieces).
// The value 255 is reserved in a Wire for "the order itself", so it must stay below 255.
uint256 constant LATHE_MAX_PIECES = 8;
// Pieces per order created without wires (the default A -> B join, V3a): 1 or 2, as before.
uint256 constant LATHE_MAX_JOIN_PIECES = 2;
// Top-level inputs and outputs of an order created with wires. run reads the inputs as one number, and the
// payee guard (about 33 inputs) is the largest rule in view; 64 leaves room. Each input bit must feed something.
uint256 constant LATHE_MAX_ORDER_BITS = 64;
uint256 constant LATHE_MAX_FORMULA_BITS = 17;
