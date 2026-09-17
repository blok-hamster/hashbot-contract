// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHashToken} from "./interfaces/IHashToken.sol";

/// @notice $BOT. After the 1M genesis seed to Pool, the ONLY path that creates new supply is
///         burning a HashBot. The pool's buyback-burn is the only path that destroys it.
contract HashToken is ERC20, Ownable, IHashToken {
    uint256 public constant GENESIS_SUPPLY = 1_000_000e18;

    address public powBots;

    event MinterSet(address indexed minter);
    event Minted(address indexed to, uint256 amount);

    /// @dev 1M seeded to the deployer; the Deploy script immediately forwards it to Pool.
    constructor() ERC20("PixelBots", "PIXELBOTS") Ownable(msg.sender) {
        _mint(msg.sender, GENESIS_SUPPLY);
    }

    /// @notice One-time, owner-set link to the PowBots contract.
    function setPowBots(address _powBots) external onlyOwner {
        require(powBots == address(0), "Already set");
        require(_powBots != address(0), "Zero");
        powBots = _powBots;
        emit MinterSet(_powBots);
    }

    /// @notice Deprecated mint path — $BOT is hard-capped at 1,000,000 genesis supply.
    function mint(address to, uint256 amount) external pure {
        revert("Hard Cap: 1M Total Supply Capped");
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}