// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain ERC-20 for tests. Configurable decimals + a configurable
///         optional fee-on-transfer.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;
    uint256 public feeBps; // 0 = no fee; 100 = 1%

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setFee(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /// @dev Apply fee-on-transfer if `feeBps > 0`. Sender gets `amount`,
    ///      recipient gets `amount * (BPS - feeBps) / BPS`. BPS = 10_000.
    function _update(address from, address to, uint256 value) internal override {
        if (feeBps > 0 && from != address(0) && to != address(0)) {
            uint256 fee = (value * feeBps) / 10_000;
            uint256 net = value - fee;
            // Move `value` from sender to this contract; send `net` to recipient,
            // burn the fee.
            super._update(from, address(this), value);
            super._update(address(this), to, net);
            // Burn `fee` by sending to a sink.
            super._update(address(this), address(0xdead), fee);
            return;
        }
        super._update(from, to, value);
    }
}