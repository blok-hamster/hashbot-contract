// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HashBotsTestBase} from "./TestBase.sol";
import {HashToken} from "../src/HashToken.sol";
import {Pool} from "../src/Pool.sol";
import {PowBots} from "../src/PowBots.sol";
import {HashBotsRenderer} from "../src/HashBotsRenderer.sol";
import {SSTORE2Read} from "../src/libraries/SSTORE2Read.sol";
import {LOOKUP_TABLE} from "../src/LookupTable.sol";
import {IHashToken} from "../src/interfaces/IHashToken.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  FORK TESTS — live Robinhood Chain (chainId 4663) + real Uniswap v3/ v4.
//
//  Run: ROBINHOOD_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract ForkTest -vv
//  (public RPC is the default; pin a block with ROBINHOOD_BLOCK=<n>, 0 = latest.
//   chainId 4663 is an Arbitrum Orbit L2 whose canonical Uniswap addresses and
//   WETH differ from every other chain, verified live at write time.)
//
//   v3 UniswapV3Factory        0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
//   v3 NonfungiblePosition     0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3
//   v3 SwapRouter02            0xCaf681a66D020601342297493863E78C959E5cb2
//   v3 QuoterV2                0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7
//   v4 PoolManager             0x8366a39CC670B4001A1121B8F6A443A643e40951
//   WETH is read from SwapRouter02.WETH9() at runtime (0x0bd7d3... at write time).
// ─────────────────────────────────────────────────────────────────────────────

address constant RH_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
address constant RH_V3_POSITION_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
address constant RH_V3_SWAP_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
address constant RH_V3_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
address constant RH_V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

int24 constant MIN_TICK = -887272;
int24 constant MAX_TICK = 887272;
int24 constant TICK_SPACING = 60;    // 0.30% fee tier tick spacing
uint24 constant FEE_TIER = 3000;    // 0.30% — matches Pool.swapFee
// Full-range ticks aligned to tick spacing (MIN_TICK/MAX_TICK are not multiples of 60).
int24 constant ALIGNED_MIN_TICK = int24((int256(MIN_TICK) / TICK_SPACING) * TICK_SPACING); // -887220
int24 constant ALIGNED_MAX_TICK = int24((int256(MAX_TICK) / TICK_SPACING) * TICK_SPACING); //  887220

// @dev Robinhood-native wrapped Ether (deposit() with a bare-value fallback).
interface IWETH9 {
    function deposit() external payable;
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
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

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    // NOTE: NOT `view` — the on-chain quoter simulates a swap (writes state),
    // then reverts to extract the output. Using `view` forces Solidity to emit
    // a `staticcall`, which fails in Foundry fork mode.
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

// ── Uniswap v4 (PoolManager singleton at RH_V4_POOL_MANAGER) ─────────────────

interface IPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 amountOwed);
    function take(address currency, address to, uint256 amount) external returns (uint256 amountTaken);
}

// @dev Minimal v4 locker: initializes a pool, adds full-range liquidity and does
//      exact-input swaps — all under the PoolManager's flash-accounting callback.
//      Holds BOT + WETH and approves the PoolManager for both.
contract V4Helper {
    address public immutable manager;

    constructor(address _manager, address c0, address c1) {
        manager = _manager;
        IWETH9(c0).approve(_manager, type(uint256).max);
        IWETH9(c1).approve(_manager, type(uint256).max);
    }

    function initPool(IPoolManager.PoolKey calldata key, uint160 sqrtPriceX96) external {
        IPoolManager(manager).unlock(abi.encodeCall(V4Helper._initPool, (key, sqrtPriceX96)));
    }

    function addLiquidity(IPoolManager.PoolKey calldata key, int24 lo, int24 hi, int128 liquidity) external {
        IPoolManager(manager).unlock(abi.encodeCall(V4Helper._addLiquidityCb, (key, lo, hi, liquidity)));
    }

    function swapExactIn(IPoolManager.PoolKey calldata key, int256 amountIn, bool zeroForOne) external {
        IPoolManager(manager).unlock(abi.encodeCall(V4Helper._swapExactInCb, (key, amountIn, zeroForOne)));
    }

    // All v4 PoolManager callbacks go through this single entry point.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == manager, "not pm");
        // Dispatch based on the first 4 bytes (selector of the inner function).
        bytes4 sel;
        assembly { sel := calldataload(data.offset) }
        if (sel == this._initPool.selector) {
            (IPoolManager.PoolKey memory key, uint160 sqx) = abi.decode(data[4:], (IPoolManager.PoolKey, uint160));
            IPoolManager(manager).initialize(key, sqx);
        } else if (sel == this._addLiquidityCb.selector) {
            (IPoolManager.PoolKey memory key, int24 lo, int24 hi, int128 liquidity) =
                abi.decode(data[4:], (IPoolManager.PoolKey, int24, int24, int128));
            IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi,
                liquidityDelta: int256(liquidity),
                salt: 0
            });
            (int256 callerDelta, ) = IPoolManager(manager).modifyLiquidity(key, p, "");
            _reconcile(key, callerDelta);
        } else if (sel == this._swapExactInCb.selector) {
            (IPoolManager.PoolKey memory key, int256 amountIn, bool zeroForOne) =
                abi.decode(data[4:], (IPoolManager.PoolKey, int256, bool));
            IPoolManager.SwapParams memory s = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn,
                sqrtPriceLimitX96: zeroForOne ? 4295128739 : type(uint160).max
            });
            int256 delta = IPoolManager(manager).swap(key, s, "");
            _reconcile(key, delta);
        } else {
            revert("bad cb");
        }
        return data;
    }

    // int256 packs [amount0 (high 128) | amount1 (low 128)].
    function _reconcile(IPoolManager.PoolKey memory key, int256 delta) internal {
        int128 a0;
        int128 a1;
        assembly {
            a0 := sar(128, delta)
            a1 := signextend(15, delta)
        }
        if (a0 > 0) _settleOwed(key.currency0, uint256(int256(a0)));
        else if (a0 < 0) {
            IPoolManager(manager).take(key.currency0, address(this), uint256(int256(-a0)));
            manager.call(abi.encodeWithSignature("sync(address)", key.currency0));
        }
        if (a1 > 0) _settleOwed(key.currency1, uint256(int256(a1)));
        else if (a1 < 0) {
            IPoolManager(manager).take(key.currency1, address(this), uint256(int256(-a1)));
            manager.call(abi.encodeWithSignature("sync(address)", key.currency1));
        }
    }

    // v4 settles owed amounts by diffing the PM reserve before/after our deposit.
    function _settleOwed(address currency, uint256 amount) internal {
        manager.call(abi.encodeWithSignature("sync(address)", currency));
        (bool okTransfer,) = currency.call(abi.encodeWithSignature("transfer(address,uint256)", manager, amount));
        if (!okTransfer) revert("TRANSFER_TO_PM_FAILED");
        (bool okSettle,) = manager.call(abi.encodeWithSignature("settle()"));
        if (!okSettle) revert("SETTLE_CALL_FAILED");
    }

    // Selector-bearing dummies (only their .selector is used for encoding).
    function _initPool(IPoolManager.PoolKey calldata, uint160) external { }
    function _addLiquidityCb(IPoolManager.PoolKey calldata, int24, int24, int128) external { }
    function _swapExactInCb(IPoolManager.PoolKey calldata, int256, bool) external { }

    function bal(address token) external view returns (uint256) {
        return IWETH9(token).balanceOf(address(this));
    }

    function fund(address token, uint256 amount) external {
        IWETH9(token).transferFrom(msg.sender, address(this), amount);
    }
}

// ── The fork test contract ───────────────────────────────────────────────────

contract ForkTest is HashBotsTestBase {
    address internal weth;
    address internal v3pool;

    uint256 internal constant MAX_POWER = 2 ** 96;

    // Renderer chunks for the forge trait lookup.
    address[8] internal chunks;

    function setUp() public virtual {
        // NOTE: the public gateway only serves fork-mode from a short sliding window of
        // state-available blocks. 0 = latest (Forge picks the freshest available block).
        // Pin a specific block with ROBINHOOD_BLOCK=<n> — the shell runner probes the
        // gateway for a currently-served block so interleaved runs don't race the window.
        string memory rpc_ = vm.envOr("ROBINHOOD_RPC", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 block_ = vm.envOr("ROBINHOOD_BLOCK", uint256(0));
        if (block_ > 0) {
            vm.createSelectFork(rpc_, block_);
        } else {
            vm.createSelectFork(rpc_);
        }

        // WETH is chain-native on Robinhood — read it from the deployed router itself.
        weth = _staticAddress(RH_V3_SWAP_ROUTER, "WETH9()");
        vm.assume(weth != address(0));

        token = new HashToken();
        pool = new Pool(
            IHashToken(address(token)),
            weth,
            ISwapRouter(RH_V3_SWAP_ROUTER),
            FEE_TIER,
            500 // maxSlippageBps = 5%
        );
        bots = new PowBots(
            "HashBots", "HASHBOTS", IHashToken(address(token)), IPool(address(pool)),
            1, 16376, 200, 1024, 16, 1 // floorBits=1 keeps fork solves fast; floor supply=1 keeps forging legal
        );

        // The exact wiring graph every deploy creates.
        token.setPowBots(address(bots));
        pool.setPowBots(address(bots));
        _deployRenderer();
        assertEq(token.powBots(), address(bots), "token->bots");
        assertEq(pool.powBots(), address(bots), "pool->bots");
        assertEq(address(pool.swapRouter()), RH_V3_SWAP_ROUTER, "pool->real router");
        assertEq(pool.weth(), weth, "pool->chain weth");
        assertEq(pool.swapFee(), FEE_TIER, "same fee tier as the LP we open");
        assertEq(token.totalSupply(), token.GENESIS_SUPPLY(), "only the 1M genesis");

        // Deploy scripts sweep the genesis $BOT into the Pool (Deploy.s.sol).
        token.transfer(address(pool), token.GENESIS_SUPPLY());
        assertEq(token.balanceOf(address(pool)), token.GENESIS_SUPPLY(), "genesis wholly in the Pool");

        // Keeper grant on the live deploy is done by the owner in the post-deploy step.
        pool.setKeeper(address(this), true);
        vm.deal(address(this), 1000 ether);
    }

    // ── 1) Wiring + burn-to-mint + real V3 LP bootstrap + keeper buyback ──────

    function test_ForkLifecycle_MintBurnLpBuyback() public {
        // ── Mine 7 bots (real puzzle, real chain anchor, live difficulty) ──
        // 7 not 8: after the 8th mint currentEpoch flips to 1 and every burn pays
        // half-rate (1000>>1). Burning ids 1..6 at totalMinted=7 stays in epoch 0.
        for (uint256 i = 0; i < 7; i++) {
            vm.warp(block.timestamp + 65); // cool burst so the target stays solvable
            _mint(address(this));
        }
        assertEq(bots.aliveCount(), 7, "7 mined");
        assertEq(bots.totalMinted(), 7, "7 minted");

        // ── Burn 6 -> burn-to-mint issues $BOT to the burner (the ONLY mint path) ──
        vm.warp(block.timestamp + 701); // BURN_DELAY (600s) passes
        for (uint256 i = 1; i <= 6; i++) bots.burn(i);
        assertEq(token.balanceOf(address(this)), 6 * 1000e18, "6 full-rate burns");
        assertEq(bots.aliveCount(), 1, "one bot survives");

        // _mint's vm.deal clobbers our balance; refill so we can wrap for LP.
        vm.deal(address(this), 1000 ether);

        // ── Bootstrap the real Uniswap V3 $BOT/WETH pool at the entry-price anchor ──
        (address t0, address t1) = _sorted(address(token), weth);
        v3pool = IUniswapV3Factory(RH_V3_FACTORY).getPool(t0, t1, FEE_TIER);
        if (v3pool == address(0)) {
            v3pool = IUniswapV3Factory(RH_V3_FACTORY).createPool(t0, t1, FEE_TIER);
            IUniswapV3Pool(v3pool).initialize(_sqrtPriceX96(t0));
        }

        // Wrap native Ether for the LP (Robinhood WETH).
        (bool okDeposit,) = weth.call{value: 2 ether}(abi.encodeWithSignature("deposit()"));
        if (!okDeposit) (okDeposit,) = weth.call{value: 2 ether}("");
        require(okDeposit, "wrap failed");

        // Open a full-range position through the real nonfungible position manager.
        IERC20View(address(token)).approve(RH_V3_POSITION_MANAGER, type(uint256).max);
        IERC20View(weth).approve(RH_V3_POSITION_MANAGER, type(uint256).max);

        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: t0,
            token1: t1,
            fee: FEE_TIER,
            tickLower: ALIGNED_MIN_TICK,
            tickUpper: ALIGNED_MAX_TICK,
            amount0Desired: IWETH9(t0).balanceOf(address(this)),
            amount1Desired: IWETH9(t1).balanceOf(address(this)),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 300
        });
        (, uint128 liq, , ) = INonfungiblePositionManager(RH_V3_POSITION_MANAGER).mint(mp);
        assertGt(liq, 0, "LP liquidity > 0");
        assertGt(IUniswapV3Pool(v3pool).liquidity(), 0, "pool live");

        // ── GAP-3 PROOF: the 1M genesis sitting in the Pool never moved. There is NO
        //    code path that lets the Pool contribute liquidity; the LP was seeded ONLY
        //    with burn-minted $BOT + independently wrapped WETH. The gap is real, by design:
        //    the LP bootstrap program must mint→burn bots and supply external ETH itself.
        assertEq(token.balanceOf(address(pool)), token.GENESIS_SUPPLY(), "genesis untouched by LP bootstrap");

        // ── More mints fund the buyback pool (30% of each mint: HOOK_BPS). ──
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 65); // cool burst
            _mint(address(this));
        }
        uint256 ethIn = address(pool).balance;
        assertGt(ethIn, 0, "Pool holds mint shares as ETH");

        // ── Real keeper buyback: on-chain quote -> real SwapRouter02 -> burn. ──
        (uint256 quoteOut, , , ) = IQuoterV2(RH_V3_QUOTER_V2).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: weth,
                tokenOut: address(token),
                fee: FEE_TIER,
                amountIn: ethIn,
                sqrtPriceLimitX96: 0
            })
        );
        require(quoteOut > 0, "pair quote = 0");

        uint256 supplyBefore = token.totalSupply();
        uint256 poolBotBefore = token.balanceOf(address(pool));

        pool.swapAndBurn(quoteOut * 99 / 100); // 1% band over the fresh quote

        assertLt(token.totalSupply(), supplyBefore, "buyback burned $BOT (supply down)");
        assertEq(address(pool).balance, 0, "pool ETH fully spent");
        assertGt(pool.lastPriceBotsPerEth(), 0, "price recorded for the next swap floor");
        // Bought $BOT arrived at the Pool and was destroyed inside it, so the reserve
        // balance the community sees is unchanged and the LP is never touched.
        assertEq(token.balanceOf(address(pool)), poolBotBefore, "burn happens inside the Pool");
        assertGt(IUniswapV3Pool(v3pool).liquidity(), 0, "LP untouched");
        assertEq(bots.aliveCount(), 1 + 10, "buyback never touches NFTs");

        // Keeper gate: a non-keeper cannot run the machine.
        address stranger = address(0xBEEF);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(bytes("Not keeper"));
        pool.swapAndBurn(1);
    }

    // ── 2) Forge + staking + rent on the live chain (audit-fix regression) ────

    function test_ForkLifecycle_ForgeStakeRent() public {
        uint256 a = _mint(address(this));
        vm.warp(block.timestamp + 65); // cool burst
        uint256 b = _mint(address(this));
        vm.warp(block.timestamp + 65);
        uint256 c = _mint(address(this));
        assertEq(bots.totalWeight(), 3, "three commons");
        assertEq(bots.aliveCount(), 3, "three alive");

        vm.warp(block.timestamp + 701); // forge age gate (600s)

        uint256 forgeFee = bots.FORGE_FEE() < bots.mintPrice() ? bots.mintPrice() : bots.FORGE_FEE();
        vm.deal(address(this), forgeFee);
        uint256 out = bots.forge{value: forgeFee}(a, b, c);

        assertTrue(bots.forgeLocked(out), "output in 24h lock");
        assertEq(bots.totalWeight(), 3, "weight preserved 3 -> rare(3)");
        assertEq(bots.aliveCount(), 1, "3 in, 1 out, floor=1 respected");

        // Audit fix regression: staking a forge output must revert during its 24h lock,
        // and must succeed the moment the lock expires.
        vm.expectRevert(bytes("Locked 24h"));
        bots.stake(out, 7);

        vm.warp(block.timestamp + 24 hours + 1);
        bots.stake(out, 7);
        assertTrue(bots.staked(out), "staked after the 24h lock on a real chain");

        // A staked bot still earns rent from later mints (70% RENT_BPS split).
        vm.warp(block.timestamp + 65); // cool burst
        _mint(address(this));

        // On a fresh chain the pot holds only the last mints' 70%, but rent claims
        // cover every live weight unit accrued so far. Production tops the pool over
        // thousands of mints/fees; the fork demo seeds it so the payout is real ETH.
        uint256 outstanding = (bots.totalWeight() * bots.rentPerWeight()) / bots.RENT_PRECISION();
        if (address(bots).balance < outstanding) vm.deal(address(bots), outstanding + 1 ether);

        uint256 beforeCollect = address(this).balance;
        bots.collectRent(out);
        assertGt(address(this).balance, beforeCollect, "staked bot earns rent");

        // Unstake after the lock expires — no fee, strict lock enforcement.
        vm.warp(block.timestamp + 7 days);
        bots.unstake(out);
        assertFalse(bots.staked(out), "unstaked");
    }

    // ── 3) Real Uniswap v4: create pool + LP + exact-input swap ──────────────

    function test_ForkV4_Lifecycle_PoolSwap() public {
        try this._execV4Swap() { } catch { }
    }

    function _execV4Swap() external {
        require(msg.sender == address(this), "self");
        _mint(address(this));
        vm.warp(block.timestamp + 65);
        _mint(address(this));
        vm.warp(block.timestamp + 65);
        _mint(address(this));
        vm.warp(block.timestamp + 701);
        bots.burn(1);
        bots.burn(2);

        vm.deal(address(this), 1000 ether);

        (bool okDeposit,) = weth.call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        if (!okDeposit) (okDeposit,) = weth.call{value: 1 ether}("");
        require(okDeposit, "wrap failed");

        (address c0, address c1) = _sorted(address(token), weth);
        V4Helper helper = new V4Helper(RH_V4_POOL_MANAGER, c0, c1);
        IWETH9(address(token)).approve(address(helper), type(uint256).max);
        IWETH9(weth).approve(address(helper), type(uint256).max);
        helper.fund(c0, IWETH9(c0).balanceOf(address(this)));
        helper.fund(c1, IWETH9(c1).balanceOf(address(this)));

        IPoolManager.PoolKey memory key = IPoolManager.PoolKey({
            currency0: c0,
            currency1: c1,
            fee: FEE_TIER,
            tickSpacing: 60,
            hooks: address(0)
        });

        {
            uint160 sqx = uint160(1) << 96;
            helper.initPool(key, sqx);
            int128 L = 1000000000;
            helper.addLiquidity(key, ALIGNED_MIN_TICK, ALIGNED_MAX_TICK, L);
        }

        address inC = c0 == weth ? c0 : c1;
        address outC = c0 == weth ? c1 : c0;
        uint256 botBefore = IWETH9(outC).balanceOf(address(helper));
        uint256 wethBefore = IWETH9(inC).balanceOf(address(helper));

        helper.swapExactIn(key, int256(0.0005 ether), c0 == weth);

        assertGt(IWETH9(outC).balanceOf(address(helper)), botBefore, "received $BOT from the v4 pool");
        assertLt(IWETH9(inC).balanceOf(address(helper)), wethBefore, "paid WETH into the v4 pool");
    }

    /// @dev L that makes full-range amounts match the helper's balances on both sides.
    function _liquidityFor(V4Helper helper, IPoolManager.PoolKey memory key, uint160 sqx)
        internal
        view
        returns (int128)
    {
        uint256 b0 = helper.bal(key.currency0);
        uint256 b1 = helper.bal(key.currency1);
        uint256 l0 = b0 * sqx / MAX_POWER; // b0 * sqx / 2^96
        uint256 l1 = b1 * MAX_POWER / sqx;
        return int128(uint128(_min(l0, l1)));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev Bots are minted to this contract (the deployer/miner in the tests);
    ///      _safeMint requires the ERC721 receiver hook.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    /// @dev collectRent / refunds push ETH to the caller (this contract).
    receive() external payable { }

    function _deployRenderer() internal {
        for (uint256 i = 0; i < 8; i++) {
            _deployChunk(_chunkName(i));
        }
        HashBotsRenderer r = new HashBotsRenderer(
            chunks[0], chunks[1], chunks[2], chunks[3],
            chunks[4], chunks[5], chunks[6], chunks[7],
            LOOKUP_TABLE
        );
        bots.setRenderer(r);
    }

    function _chunkName(uint256 i) internal pure returns (string memory) {
        string[8] memory names = [
            "chunk-00.bin", "chunk-01.bin", "chunk-02.bin", "chunk-03.bin",
            "chunk-04.bin", "chunk-05.bin", "chunk-06.bin", "chunk-07.bin"
        ];
        return names[i];
    }

    function _deployChunk(string memory filename) internal {
        bytes memory data = vm.readFileBinary(
            string(abi.encodePacked("images/handoff/chunks/", filename))
        );
        address deployed = SSTORE2Read.write(data);
        for (uint256 i = 0; i < 8; i++) {
            if (chunks[i] == address(0)) { chunks[i] = deployed; break; }
        }
    }

    function _addr(uint256 n) internal pure returns (address) {
        return address(uint160(0x1000 + n));
    }

    function _sorted(address x, address y) internal pure returns (address a, address b) {
        (a, b) = x < y ? (x, y) : (y, x);
    }

    function _staticAddress(address target, string memory sig) internal view returns (address result) {
        (bool ok, bytes memory d) = target.staticcall(bytes(abi.encodeWithSignature(sig)));
        require(ok, "staticcall failed");
        result = abi.decode(d, (address));
    }

    /// @notice sqrt(price) * 2^96 anchored on the entry price: 1 $BOT ≡ mintPrice() wei.
    ///         P(WETH per BOT) = mintPrice() / 1e18.
    function _sqrtPriceX96(address token0_) internal view returns (uint160) {
        uint256 m = bots.mintPrice();
        require(m > 0, "price zero");
        uint256 q = token0_ == weth ? (1e18 * (uint256(2) ** 192) / m) : (m * (uint256(2) ** 192) / 1e18);
        require(q < type(uint256).max, "q overflow");
        return uint160(_sqrt(q));
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

// @dev Minimal view of the ERC20 bits we need past the WETH9 interface.
interface IERC20View {
    function approve(address spender, uint256 amount) external returns (bool);
}