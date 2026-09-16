// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Rarity} from "../src/Rarity.sol";

contract DeployRarity is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address renderer = vm.envAddress("RENDERER");
        address powbots  = vm.envAddress("POWBOTS");

        vm.startBroadcast(pk);
        Rarity r = new Rarity(renderer, powbots);
        vm.stopBroadcast();

        console.log("Rarity", address(r));
    }
}
