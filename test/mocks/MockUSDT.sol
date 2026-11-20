// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 6-decimal test token. Can simulate two things the real USD₮0 proxy could do after an upgrade:
/// a blacklist (transfers to or from a listed address revert) and a fee taken on transfer.
contract MockUSDT is ERC20 {
    mapping(address => bool) public blacklisted;
    uint256 public transferFeeBps;

    constructor() ERC20("Mock USDT", "mUSDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// Same name as the real USD₮0 getter.
    function isBlocked(address who) external view returns (bool) {
        return blacklisted[who];
    }

    function setBlacklisted(address who, bool on) external {
        blacklisted[who] = on;
    }

    function setTransferFeeBps(uint256 bps) external {
        transferFeeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[from] && !blacklisted[to], "blacklisted");
        if (transferFeeBps > 0 && from != address(0) && to != address(0)) {
            uint256 fee = (value * transferFeeBps) / 10_000;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
