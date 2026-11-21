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
uint256 constant LATHE_MAX_PIECES = 2;
uint256 constant LATHE_MAX_FORMULA_BITS = 17;
