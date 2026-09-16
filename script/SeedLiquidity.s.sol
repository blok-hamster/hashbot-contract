// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HashToken} from "../src/HashToken.sol";
import {Pool} from "../src/Pool.sol";

/// @notice Reports the liquidity-bootstrapping state and the exact manual steps for the
///         $BOT/WETH Uniswap V3 pool. Deliberately has NO privileged withdraw: the 1M
///         genesis $BOT lives in Pool as buyback-burn + liquidity reserve and can only be
///         spent through the LP program described in docs/BUILD_SPEC.md §Liquidity.
///
///   forge script script/SeedLiquidity.s.sol:SeedLiquidity --rpc-url base_sepolia
contract SeedLiquidity is Script {
    function run() external {
        address tokenAddr = vm.envAddress("TOKEN");
        address poolAddr = vm.envAddress("POOL");
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        HashToken bot = HashToken(tokenAddr);
        Pool pool = Pool(payable(poolAddr));

        console.log("deployer         :", deployer);
        console.log("Pool $BOT balance:", bot.balanceOf(poolAddr), "(should be 1,000,000e18)");
        console.log("Pool ETH balance :", address(pool).balance);
        console.log("Pool is idle-owner wired:", address(pool.powBots()) != address(0));
        console.log("");
        console.log("Liquidity bootstrap (manual, Uniswap UI / SDK):");
        console.log("  1. Create the $BOT/WETH pool at a price pinning $BOT ~= entry/mint cost.");
        console.log("  2. Add liquidity against Pool's BOT via the LP program (see BUILD_SPEC).");
        console.log("  3. Ensure Pool.swapRouter is a router exposing exactInputSingle() for the");
        console.log("     buyback; router is owner-settable via Pool.setSwapRouter().");
    }
}