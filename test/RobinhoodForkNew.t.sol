// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {HashToken} from "../src/HashToken.sol";
import {Pool} from "../src/Pool.sol";
import {PowBots} from "../src/PowBots.sol";
import {HashBotsRenderer} from "../src/HashBotsRenderer.sol";
import {SSTORE2Read} from "../src/libraries/SSTORE2Read.sol";
import {LOOKUP_TABLE} from "../src/LookupTable.sol";
import {IHashToken} from "../src/interfaces/IHashToken.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Robinhood Mainnet/Testnet DEX Constants
address constant RH_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
address constant RH_V3_SWAP_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
address constant RH_V3_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
uint24 constant FEE_TIER = 3000; // 0.30%

interface IWETH9 {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IUniswapV3Factory {
    function getPool(address, address, uint24) external view returns (address);
    function createPool(address, address, uint24) external returns (address);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function liquidity() external view returns (uint128);
}

contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance low");
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal low");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal low");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockSwapRouter {
    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        amountOut = params.amountIn * 100;
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }
}

/// @notice End-to-end Fork Test targeting live Robinhood Chain (chainId 46630 / 4663).
///         Tests Hard-Capped 1M $BOT Token, Pool Dispenser, $0 Out-of-Pocket LP Seeding,
///         and DEX Swap-and-Burn Flywheel.
contract RobinhoodForkNewTest is Test {
    address internal weth;
    HashToken internal token;
    Pool internal pool;
    PowBots internal bots;

    address[8] internal chunks;

    function setUp() public {
        string memory rpc_ = vm.envOr("ROBINHOOD_RPC", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 block_ = vm.envOr("ROBINHOOD_BLOCK", uint256(0));
        if (block_ > 0) {
            vm.createSelectFork(rpc_, block_);
        } else {
            vm.createSelectFork(rpc_);
        }

        weth = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
        address routerAddr = RH_V3_SWAP_ROUTER;

        if (weth.code.length == 0) {
            weth = address(new MockWETH());
        }

        // Etch MockSwapRouter so swapAndBurn succeeds without needing a live DEX pool for fresh $BOT token
        MockSwapRouter mr = new MockSwapRouter();
        vm.etch(routerAddr, address(mr).code);

        // 1. Deploy contracts
        token = new HashToken();
        pool = new Pool(
            IHashToken(address(token)),
            weth,
            ISwapRouter(routerAddr),
            FEE_TIER,
            500 // maxSlippageBps = 5%
        );
        bots = new PowBots(
            "HashBots", "HASHBOTS", IHashToken(address(token)), IPool(address(pool)),
            1, 4444, 200, 1024, 16, 1
        );

        // 2. Wire roles
        token.setPowBots(address(bots));
        pool.setPowBots(address(bots));
        pool.setKeeper(address(this), true);

        // 3. Seed 1M genesis $BOT into Pool
        token.transfer(address(pool), token.GENESIS_SUPPLY());
        assertEq(token.balanceOf(address(pool)), 1_000_000e18, "Genesis supply in Pool");

        vm.deal(address(this), 100 ether);
    }

    /// @notice Full End-to-End Test: PoW Mining -> Pool Fee Accumulation -> NFT Burning (Pool Dispenser)
    ///         -> $0 Out-of-Pocket Liquidity Seeding -> DEX Swap & Burn (Deflation).
    function test_RobinhoodFork_EndToEnd_LiquidityAndBurn() public {
        console.log("=== STARTING ROBINHOOD FORK END-TO-END TEST ===");

        // 1. Verify Hard-Capped 1M Supply
        assertEq(token.totalSupply(), 1_000_000e18, "Initial supply is exactly 1,000,000 $BOT");
        vm.expectRevert(bytes("Hard Cap: 1M Total Supply Capped"));
        token.mint(address(this), 100e18);

        // 2. Mine 5 HashBot NFTs & accumulate 30% protocol fees in Pool.sol
        console.log("Mining 5 HashBot NFTs...");
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 65);
            _mintBot(address(this));
        }
        assertEq(bots.aliveCount(), 5, "5 live bots mined");
        uint256 accumulatedEth = address(pool).balance;
        assertGt(accumulatedEth, 0, "Pool accumulated native ETH from 30% fee share");
        console.log("Accumulated Pool ETH balance:", accumulatedEth);

        // 3. Burn NFT #1 & NFT #2 (Verifying Pool Dispenser)
        console.log("Warping past burn delay and burning 2 NFTs...");
        vm.warp(block.timestamp + 701);
        uint256 poolBotBefore = token.balanceOf(address(pool));
        bots.burn(1);
        bots.burn(2);

        // Verify tokens were transferred FROM Pool reserve, NOT minted
        assertEq(token.balanceOf(address(this)), 2_000e18, "Burner received 2,000 $BOT");
        assertEq(token.balanceOf(address(pool)), poolBotBefore - 2_000e18, "Tokens transferred out of Pool reserve");
        assertEq(token.totalSupply(), 1_000_000e18, "Total supply remains hard-capped at 1M (zero inflation)");

        // 4. Test $0 Out-of-Pocket Liquidity Seeding
        console.log("Testing $0 Out-of-Pocket Liquidity Seeding in Pool.sol...");
        uint256 seedEth = accumulatedEth;
        assertFalse(pool.lpSeeded(), "LP not seeded yet");

        // Execute seedUniswapLiquidity using stored protocol ETH + 200k $BOT
        pool.seedUniswapLiquidity(seedEth);
        assertTrue(pool.lpSeeded(), "LP successfully seeded");
        console.log("Liquidity seeded with", seedEth, "ETH + 200,000 $BOT!");

        // 5. Mine 5 more bots & execute DEX Swap & Burn
        console.log("Mining 5 more bots to accumulate new buyback ETH...");
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 65);
            _mintBot(address(this));
        }

        uint256 freshPoolEth = address(pool).balance;
        assertGt(freshPoolEth, 0, "Fresh buyback ETH accumulated");

        // Wrap WETH for Mock DEX Swap
        vm.deal(address(this), 10 ether);
        (bool okWeth,) = weth.call{value: 2 ether}(abi.encodeWithSignature("deposit()"));
        require(okWeth, "WETH wrap failed");

        // Setup mock DEX Router swap return
        uint256 supplyBeforeBuyback = token.totalSupply();
        console.log("Executing swapAndBurn on Pool...");

        // Fund mock DEX router with $BOT to sell back to Pool
        deal(address(token), address(pool.swapRouter()), 5_000e18);

        // Call swapAndBurn
        uint256 amountBurned = pool.swapAndBurn(0);
        console.log("DEX Swap & Burn destroyed", amountBurned, "$BOT tokens!");

        // 6. Verify Deflation: Total supply MUST decrease below 1M!
        assertLt(token.totalSupply(), supplyBeforeBuyback, "Total supply decreased (Strict Deflation)");
        assertEq(address(pool).balance, 0, "Pool ETH balance fully spent on buyback");

        console.log("=== ROBINHOOD FORK END-TO-END TEST PASSED SUCCESSFULLY! ===");
    }

    function _mintBot(address miner) internal returns (uint256 id) {
        (uint256 anchorNum, bytes32 anchor) = (block.number - 1, blockhash(block.number - 1));
        uint256 prev = bots.lastWork();
        uint64 nonce = 0;

        for (uint256 attempt = 0; attempt < 10; attempt++) {
            uint256 target = bots.targetFor(miner);
            while (true) {
                uint256 h;
                assembly {
                    mstore(0x80, shl(96, miner))
                    mstore(0x94, shl(192, nonce))
                    mstore(0x9c, prev)
                    mstore(0xbc, anchor)
                    h := keccak256(0x80, 92)
                }
                if (h < target) break;
                nonce++;
            }

            uint256 price = bots.mintPrice();
            vm.deal(miner, price + 1 ether);
            vm.prank(miner);
            try bots.mint{value: price}(nonce, prev, anchorNum, anchor) returns (uint256 mintedId) {
                return mintedId;
            } catch {
                nonce++;
            }
        }
        revert("Mint failed after 10 attempts");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    receive() external payable {}
}
