// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PowBots} from "../src/PowBots.sol";
import {HashBotsRenderer} from "../src/HashBotsRenderer.sol";
import {SSTORE2Read} from "../src/libraries/SSTORE2Read.sol";
import {LOOKUP_TABLE} from "../src/LookupTable.sol";

/// @notice Deploy the on-chain art: 8 SSTORE2 chunk contracts + the renderer.
///
///   forge script script/DeployArt.s.sol:DeployArt \
///       --rpc-url base_sepolia --broadcast -vvvv
///
/// Requires POWBOTS address in env (the already-deployed PowBots contract).
/// The 8 chunk .bin files live in images/handoff/chunks/.
contract DeployArt is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address powBotsAddr = vm.envAddress("POWBOTS");

        vm.startBroadcast(pk);

        // ── 1. Deploy the 8 chunk contracts via SSTORE2 (CREATE with data as runtime code) ──
        address[8] memory chunkAddrs;
        chunkAddrs[0] = _deployChunk("chunk-00.bin");
        chunkAddrs[1] = _deployChunk("chunk-01.bin");
        chunkAddrs[2] = _deployChunk("chunk-02.bin");
        chunkAddrs[3] = _deployChunk("chunk-03.bin");
        chunkAddrs[4] = _deployChunk("chunk-04.bin");
        chunkAddrs[5] = _deployChunk("chunk-05.bin");
        chunkAddrs[6] = _deployChunk("chunk-06.bin");
        chunkAddrs[7] = _deployChunk("chunk-07.bin");

        for (uint256 i = 0; i < 8; i++) {
            console.log("Chunk %d: %s", i, chunkAddrs[i]);
        }

        // ── 2. Deploy the renderer with chunk addresses + lookup table ──
        HashBotsRenderer renderer = new HashBotsRenderer(
            chunkAddrs[0],
            chunkAddrs[1],
            chunkAddrs[2],
            chunkAddrs[3],
            chunkAddrs[4],
            chunkAddrs[5],
            chunkAddrs[6],
            chunkAddrs[7],
            LOOKUP_TABLE
        );
        console.log("Renderer: %s", address(renderer));

        // ── 3. Wire the renderer into PowBots (one-time setter) ──
        PowBots(payable(powBotsAddr)).setRenderer(renderer);
        console.log("Renderer wired to PowBots");

        vm.stopBroadcast();
    }

    /// @dev Deploy a single chunk via SSTORE2 (runtime code = the chunk bytes).
    function _deployChunk(string memory filename) internal returns (address deployed) {
        bytes memory data = vm.readFileBinary(
            string(abi.encodePacked("images/handoff/chunks/", filename))
        );
        return SSTORE2Read.write(data);
    }
}
