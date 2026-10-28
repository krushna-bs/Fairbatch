```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestUSDC
/// @notice Faucet-style USDC mock used only for the FairBatch Base Sepolia MVP.
/// @dev This is NOT real USDC and has no mainnet value.
contract TestUSDC is ERC20 {
    uint8 private constant TOKEN_DECIMALS = 6;
    uint256 public constant FAUCET_AMOUNT = 10_000 * 10 ** TOKEN_DECIMALS;

    constructor() ERC20("FairBatch Test USDC", "tUSDC") {}

    function decimals() public pure override returns (uint8) {
        return TOKEN_DECIMALS;
    }

    /// @notice Mint test tokens for Base Sepolia development/testing.
    /// @dev Permissionless by design for the hackathon testnet MVP.
    function mint() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
```
