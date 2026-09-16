// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HashToken} from "../src/HashToken.sol";
import {Pool} from "../src/Pool.sol";
import {PowBots} from "../src/PowBots.sol";

/// @notice Read-only sanity check of a deployed HashBots stack.
///         Requires TOKEN/POOL/POWBOTS env vars (set from the Deploy output).
///
///   forge script script/Verify.s.sol:Verify --rpc-url base_sepolia
contract Verify is Script {
    function run() external {
        address tokenAddr = vm.envOr("TOKEN", address(0));
        address poolAddr = vm.envOr("POOL", address(0));
        address botsAddr = vm.envOr("POWBOTS", address(0));

        require(tokenAddr != address(0) && poolAddr != address(0) && botsAddr != address(0), "Please set TOKEN, POOL, and POWBOTS env vars or deploy first");

        HashToken bot = HashToken(tokenAddr);
        Pool pool = Pool(payable(poolAddr));
        PowBots bots = PowBots(payable(botsAddr));

        console.log("--- TESTNET VERIFICATION ---");
        console.log("name  :", bots.name());
        console.log("symbol:", bots.symbol());
        console.log("bot   :", address(bot));
        console.log("pool  :", address(pool));
        console.log("token powBots ==", address(bot.powBots()));
        console.log("pool powBots  ==", address(pool.powBots()));
        console.log("floorBits     ==", bots.floorBits());
        console.log("baseTarget    ==", bots.baseTarget());
        console.log("epoch         ==", bots.currentEpoch());
        console.log("totalMinted   ==", bots.totalMinted());
        console.log("uniquesRemain ==", bots.uniquesRemaining());
        console.log("mintPrice     ==", bots.mintPrice());
        console.log("pool BOT bal  ==", bot.balanceOf(poolAddr));
        console.log("lastWork      == 0 (unmined):", bots.lastWork() == 0);
    }
}