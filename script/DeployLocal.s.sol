// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HashToken} from "../src/HashToken.sol";
import {Pool} from "../src/Pool.sol";
import {PowBots} from "../src/PowBots.sol";
import {HashBotsRenderer} from "../src/HashBotsRenderer.sol";
import {Rarity} from "../src/Rarity.sol";
import {SSTORE2Read} from "../src/libraries/SSTORE2Read.sol";
import {LOOKUP_TABLE} from "../src/LookupTable.sol";
import {IHashToken} from "../src/interfaces/IHashToken.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";

/// @dev Local/anvil deploy script with Renderer and Rarity oracle enabled for UI testing.
contract DeployLocal is Script {
    address[8] internal chunks;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        address weth = address(0x4200000000000000000000000000000000000006);

        HashToken bot = new HashToken();
        Pool pool = new Pool(IHashToken(address(bot)), weth, ISwapRouter(address(0xdead)), 3000, 500);
        PowBots bots = new PowBots(
            "HashBots", "HASHBOTS", IHashToken(address(bot)), IPool(address(pool)),
            9, 4444, 200, 1024, 16, 1
        );

        // Deploy HashBotsRenderer with on-chain SVG chunk files
        for (uint256 i = 0; i < 8; i++) {
            string memory chunkName = _chunkName(i);
            bytes memory data = vm.readFileBinary(string(abi.encodePacked("images/handoff/chunks/", chunkName)));
            chunks[i] = SSTORE2Read.write(data);
        }

        HashBotsRenderer renderer = new HashBotsRenderer(
            chunks[0], chunks[1], chunks[2], chunks[3],
            chunks[4], chunks[5], chunks[6], chunks[7],
            LOOKUP_TABLE
        );
        bots.setRenderer(renderer);

        // Deploy Rarity oracle contract
        Rarity rarity = new Rarity(address(renderer), address(bots));

        bot.setPowBots(address(bots));
        pool.setPowBots(address(bots));
        bot.transfer(address(pool), bot.GENESIS_SUPPLY());

        vm.stopBroadcast();
        console.log("HashToken        =", address(bot));
        console.log("Pool             =", address(pool));
        console.log("PowBots          =", address(bots));
        console.log("HashBotsRenderer =", address(renderer));
        console.log("Rarity           =", address(rarity));

        _exportAddressesToUI(
            block.chainid,
            address(bot),
            address(pool),
            address(bots),
            address(rarity),
            address(renderer)
        );
    }

    function _exportAddressesToUI(
        uint256 chainId,
        address token,
        address pool,
        address powbots,
        address rarity,
        address renderer
    ) internal {
        bytes memory part1 = abi.encodePacked(
            "{\n",
            '  "', vm.toString(chainId), '": {\n',
            '    "token": "', vm.toString(token), '",\n',
            '    "hashtoken": "', vm.toString(token), '",\n',
            '    "pool": "', vm.toString(pool), '",\n'
        );
        bytes memory part2 = abi.encodePacked(
            '    "powbots": "', vm.toString(powbots), '",\n',
            '    "hashbots": "', vm.toString(powbots), '",\n',
            '    "rarity": "', vm.toString(rarity), '",\n',
            '    "renderer": "', vm.toString(renderer), '",\n',
            '    "hashbotsrenderer": "', vm.toString(renderer), '"\n  }\n}\n'
        );
        try vm.writeFile("../ui/src/lib/addresses.json", string(abi.encodePacked(part1, part2))) {
            console.log("Successfully exported addresses to ../ui/src/lib/addresses.json!");
        } catch {
            console.log("Notice: Write to ../ui/src/lib/addresses.json skipped.");
        }
    }

    function _chunkName(uint256 i) internal pure returns (string memory) {
        string[8] memory names = [
            "chunk-00.bin", "chunk-01.bin", "chunk-02.bin", "chunk-03.bin",
            "chunk-04.bin", "chunk-05.bin", "chunk-06.bin", "chunk-07.bin"
        ];
        return names[i];
    }
}