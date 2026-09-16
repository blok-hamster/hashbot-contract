// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IHashToken is IERC20Metadata {
    /// @notice Mint new supply — callable ONLY by PowBots (on burn). No other issuance path.
    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;
}