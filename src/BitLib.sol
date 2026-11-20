// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Bit packing for TapeOut inputs and outputs.
/// Bit order is least significant bit first (TAP-02 section 5): bit k lives in byte k/8, at position k%8.
library BitLib {
    /// @notice The low `nBits` of `value` as ceil(nBits/8) bytes, LSB first. Empty for nBits == 0.
    /// Bits of `value` above `nBits` are dropped.
    function pack(uint256 value, uint256 nBits) internal pure returns (bytes memory out) {
        require(nBits <= 256, "BitLib: nBits");
        uint256 len = (nBits + 7) / 8;
        out = new bytes(len);
        if (nBits < 256) value &= (uint256(1) << nBits) - 1;
        for (uint256 i = 0; i < len; ++i) {
            out[i] = bytes1(uint8(value >> (8 * i)));
        }
    }

    /// @notice Read `nBits` bits starting at bit `offset`, LSB first. Bits past the end of `data` read as 0.
    function readBits(bytes memory data, uint256 offset, uint256 nBits) internal pure returns (uint256 v) {
        require(nBits <= 256, "BitLib: nBits");
        uint256 len = data.length;
        for (uint256 i = 0; i < nBits; ++i) {
            uint256 bit = offset + i;
            uint256 byteIndex = bit >> 3;
            if (byteIndex >= len) break;
            v |= ((uint256(uint8(data[byteIndex])) >> (bit & 7)) & 1) << i;
        }
    }

    /// @notice The low `nBits` bits of `data`. Used on `eval` output so padding bits above nOut are ignored.
    function lowBits(bytes memory data, uint256 nBits) internal pure returns (uint256) {
        return readBits(data, 0, nBits);
    }
}
