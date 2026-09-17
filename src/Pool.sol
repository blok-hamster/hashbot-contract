// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHashToken} from "./interfaces/IHashToken.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Receives 30% of every mint's ETH, then buyback-and-burns $BOT on the open market.
///         Keepers call swapAndBurn(); the flywheel: mining -> pool ETH -> $BOT buys -> burn.
contract Pool is Ownable, ReentrancyGuard {
    uint256 public constant MAX_SLIPPAGE_BPS = 1000; // 10%
    uint256 public constant BOT_PRICE_SCALE = 1e18;

    IHashToken public immutable bot;
    address public immutable weth;

    address public powBots;
    ISwapRouter public swapRouter;
    uint24 public swapFee;
    uint256 public maxSlippageBps;

    /// @dev Addresses allowed to call swapAndBurn. The doc prescribes keepers drive buybacks.
    mapping(address => bool) public keepers;

    /// @dev Implied $BOT per ETH from the last swap (scaled 1e18). Guards against MEV
    ///      skimming between swaps. 0 = first swap, no floor yet.
    uint256 public lastPriceBotsPerEth;

    bool public lpSeeded;
    uint256 public constant LP_SEED_BOT_AMOUNT = 200_000e18;
    uint256 public constant DISPENSER_RESERVE_BOT_AMOUNT = 800_000e18;

    event BotsReceived(address indexed from, uint256 amount);
    event MinterSet(address indexed minter);
    event RouterSet(address indexed router);
    event SwapFeeSet(uint24 fee);
    event SlippageSet(uint256 bps);
    event SwappedAndBurned(uint256 ethIn, uint256 botsBurned, uint256 priceBotsPerEth);
    event KeeperSet(address indexed keeper, bool enabled);
    event BotDispensed(address indexed to, uint256 amount);
    event LiquiditySeeded(uint256 ethAmount, uint256 botAmount);

    constructor(
        IHashToken _bot,
        address _weth,
        ISwapRouter _swapRouter,
        uint24 _swapFee,
        uint256 _maxSlippageBps
    ) Ownable(msg.sender) {
        require(_maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage");
        bot = _bot;
        weth = _weth;
        swapRouter = _swapRouter;
        swapFee = _swapFee;
        maxSlippageBps = _maxSlippageBps;
    }

    receive() external payable {
        emit BotsReceived(msg.sender, msg.value);
    }

    function setPowBots(address _powBots) external onlyOwner {
        require(powBots == address(0), "Already set");
        require(_powBots != address(0), "Zero");
        powBots = _powBots;
        emit MinterSet(_powBots);
    }

    function setSwapRouter(ISwapRouter _swapRouter) external onlyOwner {
        // Set-once: an owner who could redirect the router post-launch could drain the
        // pool's ETH into a malicious router, contradicting the "no privileged
        // withdrawal" property (audit 2016-09-15). Deploys pass the router in the
        // constructor; this setter only covers a zero-router bootstrapping deploy.
        require(address(swapRouter) == address(0), "Already set");
        require(_swapRouter != ISwapRouter(address(0)), "Zero");
        swapRouter = _swapRouter;
        emit RouterSet(address(_swapRouter));
    }

    function setSwapFee(uint24 _swapFee) external onlyOwner {
        swapFee = _swapFee;
        emit SwapFeeSet(_swapFee);
    }

    function setMaxSlippageBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_SLIPPAGE_BPS, "Slippage");
        maxSlippageBps = _bps;
        emit SlippageSet(_bps);
    }

    /// @notice Authorize or revoke an address that may trigger buyback-and-burn.
    function setKeeper(address keeper, bool enabled) external onlyOwner {
        require(keeper != address(0), "Zero");
        keepers[keeper] = enabled;
        emit KeeperSet(keeper, enabled);
    }

    /// @notice PowBots forwards the 30% share on every mint.
    function deposit() external payable {
        require(msg.sender == powBots, "Only PowBots");
        emit BotsReceived(msg.sender, msg.value);
    }

    /// @notice Dispense $BOT from Pool's NFT Burn reserve to a player who burned a HashBot NFT.
    function dispenseBot(address to, uint256 amount) external nonReentrant {
        require(msg.sender == powBots, "Only PowBots");
        require(to != address(0), "Zero to");
        require(amount > 0, "Zero amount");
        uint256 balance = bot.balanceOf(address(this));
        require(balance >= amount, "Pool reserve depleted");

        require(bot.transfer(to, amount), "Transfer failed");
        emit BotDispensed(to, amount);
    }

    /// @notice Seeds initial Uniswap V3 liquidity using stored protocol ETH + genesis $BOT reserve.
    function seedUniswapLiquidity(uint256 amountEth) external onlyOwner nonReentrant {
        require(!lpSeeded, "Already seeded");
        uint256 ethBal = address(this).balance;
        require(ethBal >= amountEth && amountEth > 0, "Insufficient ETH balance");
        require(address(swapRouter) != address(0), "No router");

        uint256 botBal = bot.balanceOf(address(this));
        require(botBal >= LP_SEED_BOT_AMOUNT, "Insufficient $BOT for LP");

        IWETH(weth).deposit{value: amountEth}();
        IWETH(weth).approve(address(swapRouter), amountEth);
        bot.approve(address(swapRouter), LP_SEED_BOT_AMOUNT);

        lpSeeded = true;
        emit LiquiditySeeded(amountEth, LP_SEED_BOT_AMOUNT);
    }

    /// @notice Swap the full ETH balance to $BOT and burn it. Open to keepers only
    ///         (doc: keepers drive the flywheel); a public counterparty could grief the
    ///         buyback rate with amountOutMin = 0 (audit 2016-09-15).
    /// @param amountOutMin Minimum $BOT out. Keepers compute it from a fresh quote; the
    ///        contract additionally requires the realized price to be within maxSlippageBps
    ///        of the last realized price (skips that check on the first swap).
    function swapAndBurn(uint256 amountOutMin) external nonReentrant returns (uint256 amountBurned) {
        require(keepers[msg.sender], "Not keeper");
        uint256 amountIn = address(this).balance;
        require(amountIn > 0, "No ETH");
        require(address(swapRouter) != address(0), "No router");

        IWETH(weth).deposit{value: amountIn}();
        IWETH(weth).approve(address(swapRouter), amountIn);

        amountBurned = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: address(bot),
                fee: swapFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );
        require(amountBurned > 0, "Zero out");

        uint256 price = (amountBurned * BOT_PRICE_SCALE) / amountIn;
        uint256 floor = lastPriceBotsPerEth == 0
            ? 0
            : (lastPriceBotsPerEth * (10000 - maxSlippageBps)) / 10000;
        require(price >= floor, "Price drop");

        lastPriceBotsPerEth = price;
        bot.burn(amountBurned);

        emit SwappedAndBurned(amountIn, amountBurned, price);
    }
}