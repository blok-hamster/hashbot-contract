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

/// @notice Production deployment script targeting Robinhood Chain (chainId 4663).
///         Deploys HashToken -> Pool -> PowBots -> HashBotsRenderer -> Rarity,
///         wires minter/owner roles, and seeds 1M genesis $BOT into Pool.
///
///   ROBINHOOD_BLOCK=$(cast block-number --rpc-url robinhood) forge script script/DeployRobinhood.s.sol:DeployRobinhood \
///       --rpc-url robinhood --broadcast -vvvv
contract DeployRobinhood is Script {
    // Robinhood Chain canonical DEX addresses
    address internal constant RH_V3_SWAP_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    address[8] internal chunks;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console.log("Deploying from address:", deployer);
        console.log("Chain ID              :", block.chainid);

        vm.startBroadcast(pk);

        address router = vm.envOr("SWAP_ROUTER", RH_V3_SWAP_ROUTER);
        address weth = vm.envOr("WETH", RH_WETH);

        // 1. Deploy Core Token and Pool
        HashToken bot = new HashToken();
        Pool pool = new Pool(IHashToken(address(bot)), weth, ISwapRouter(router), 3000, 500);

        // 2. Deploy main PowBots game contract
        PowBots bots = new PowBots(
            "HashBots",
            "HASHBOTS",
            IHashToken(address(bot)),
            IPool(address(pool)),
            4,     // floorBits (4 bits target for fast instant mining)
            16376, // wallFrom
            200,   // wallDiv
            1024,  // uniqueWindow
            16,    // uniqueTotal
            4096   // supplyFloor
        );

        // 3. Deploy and wire Art Renderer
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

        // 4. Deploy Rarity oracle contract
        Rarity rarity = new Rarity(address(renderer), address(bots));

        // 5. Wire minter roles & genesis supply
        bot.setPowBots(address(bots));
        pool.setPowBots(address(bots));
        bot.transfer(address(pool), bot.GENESIS_SUPPLY());

        vm.stopBroadcast();

        console.log("--- DEPLOYMENT COMPLETE ---");
        console.log("TOKEN   =", address(bot));
        console.log("POOL    =", address(pool));
        console.log("POWBOTS =", address(bots));
        console.log("RENDERER=", address(renderer));
        console.log("RARITY  =", address(rarity));
        console.log("Genesis $BOT balance in Pool:", bot.balanceOf(address(pool)));

        // 6. Automatically sync addresses to UI addresses.json
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
