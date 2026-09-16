// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PowBots} from "../src/PowBots.sol";
import {HashBotsRenderer} from "../src/HashBotsRenderer.sol";
import {SSTORE2Read} from "../src/libraries/SSTORE2Read.sol";
import {LOOKUP_TABLE} from "../src/LookupTable.sol";

contract DeployArtClean is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address powBotsAddr = vm.envAddress("POWBOTS");
        address sender = vm.addr(pk);

        vm.startBroadcast(pk);

        address[8] memory chunkAddrs;

        // Deploy each chunk individually with explicit nonce tracking
        for (uint256 i = 0; i < 8; i++) {
            bytes memory data = vm.readFileBinary(
                string(abi.encodePacked("images/handoff/chunks/chunk-0", bytes1(uint8(48 + i)), ".bin"))
            );
            // Compute expected CREATE address from sender + current nonce
            uint256 nonce = vm.getNonce(sender);
            chunkAddrs[i] = vm.computeCreateAddress(sender, nonce);

            bytes memory initcode = abi.encodePacked(
                hex"63",
                uint32(data.length),
                hex"80600e6000396000f3",
                data
            );
            address deployed;
            assembly {
                deployed := create(0, add(initcode, 0x20), mload(initcode))
            }
            require(deployed == chunkAddrs[i], "address mismatch");
            console.log("Chunk %d: %s (nonce %d)", i, chunkAddrs[i], nonce);
        }

        // Deploy renderer with all 8 chunk addresses
        HashBotsRenderer renderer = new HashBotsRenderer(
            chunkAddrs[0], chunkAddrs[1], chunkAddrs[2], chunkAddrs[3],
            chunkAddrs[4], chunkAddrs[5], chunkAddrs[6], chunkAddrs[7],
            LOOKUP_TABLE
        );
        console.log("Renderer: %s", address(renderer));

        // Wire renderer into PowBots
        PowBots(payable(powBotsAddr)).setRenderer(renderer);
        console.log("Renderer wired to PowBots");

        vm.stopBroadcast();
    }
}
