// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HashToken} from "../src/HashToken.sol";
import {Pool} from "../src/Pool.sol";
import {PowBots} from "../src/PowBots.sol";
import {IHashToken} from "../src/interfaces/IHashToken.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";

/// @notice One-shot production deploy: HashToken -> Pool -> PowBots, wire the minter roles,
///         then seed the 1M genesis $BOT into Pool (buyback-burn + liquidity reserve).
///
///   forge script script/Deploy.s.sol:Deploy \
///       --rpc-url base_sepolia --broadcast --verify -vvvv
///
///   Outputs the three addresses; record them in .env (TOKEN/POOL/POWBOTS) for Verify/SeedLiquidity.
contract Deploy is Script {
    // Base L2 chain constants
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        // Uniswap V3 SwapRouter02 (Base Sepolia) — exposes exactInputSingle() used by
        // Pool.swapAndBurn. Override via SWAP_ROUTER env for a different chain/router:
        //   Base mainnet SwapRouter02 = 0x2626664c2603336E57B271c5C0b26F421741e481
        address router = vm.envOr(
            "SWAP_ROUTER", address(0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4)
        );

        HashToken bot = new HashToken();
        Pool pool = new Pool(IHashToken(address(bot)), WETH, ISwapRouter(router), 3000, 500);
        PowBots bots = new PowBots(
            "HashBots",
            "HASHBOTS",
            IHashToken(address(bot)),
            IPool(address(pool)),
            26,    // floorBits — full difficulty floor at epoch 0
            4444,  // wallFrom — 4444 collection wall
            200,   // wallDiv
            1024,  // uniqueWindow
            16,    // uniqueTotal
            4096   // supplyFloor — forging refused below this live count (doc:134)
        );

        bot.setPowBots(address(bots));
        pool.setPowBots(address(bots));

        // Genesis: 1M $BOT -> Pool (buyback-burn reserve + LP seed material).
        bot.transfer(address(pool), bot.GENESIS_SUPPLY());

        vm.stopBroadcast();

        console.log("HashToken:", address(bot));
        console.log("Pool:", address(pool));
        console.log("PowBots:", address(bots));
        console.log("Genesis BOT seeded to Pool:", bot.GENESIS_SUPPLY());

        _exportAddressesToUI(block.chainid, address(bot), address(pool), address(bots));
    }

    function _exportAddressesToUI(
        uint256 chainId,
        address token,
        address pool,
        address powbots
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
            '    "hashbots": "', vm.toString(powbots), '"\n  }\n}\n'
        );
        try vm.writeFile("../ui/src/lib/addresses.json", string(abi.encodePacked(part1, part2))) {
            console.log("Successfully exported addresses to ../ui/src/lib/addresses.json!");
        } catch {
            console.log("Notice: Write to ../ui/src/lib/addresses.json skipped.");
        }
    }
}