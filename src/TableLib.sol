// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BitLib} from "./BitLib.sol";

/// @notice The truth-table encoding shared by every Lathe version.
/// Case c runs 0 .. 2^(nIn+nState) - 1; inputs = c & (2^nIn - 1), state = c >> nIn.
/// Each case's answer is w = nOut + nState bits (outputs low, new state above). The table is every
/// answer concatenated LSB first: case c's answer starts at bit c*w.
library TableLib {
    /// @notice The expected answer for case `c` when each answer is `w` bits wide.
    function expected(bytes memory table, uint256 c, uint256 w) internal pure returns (uint256) {
        return BitLib.readBits(table, c * w, w);
    }

    /// @notice How many bytes a table of `cases` answers of `w` bits takes.
    function byteLength(uint256 cases, uint256 w) internal pure returns (uint256) {
        return (cases * w + 7) / 8;
    }
}
