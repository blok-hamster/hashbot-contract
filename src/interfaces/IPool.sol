// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPool {
    /// @notice PowBots forwards the 30% buyback share to the pool with native ETH.
    function deposit() external payable;

    /// @notice Dispense $BOT from Pool's reserve to a user who burned a HashBot NFT.
    function dispenseBot(address to, uint256 amount) external;
}