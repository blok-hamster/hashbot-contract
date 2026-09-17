// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HashToken} from "../src/HashToken.sol";
import {Pool} from "../src/Pool.sol";
import {PowBots} from "../src/PowBots.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {IPool} from "../src/interfaces/IPool.sol";

/// @dev Simulates a Uniswap V3 SwapRouter with a settable flat price (BOT per ETH, 1e18).
contract MockSwapRouter {
    uint256 public pricePerEth = 100e18;

    function setPrice(uint256 p) external {
        pricePerEth = p;
    }

    function fund(address token, address from, uint256 amount) external {
        IERC20(token).transferFrom(from, address(this), amount);
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        amountOut = (p.amountIn * pricePerEth) / 1e18;
        require(amountOut >= p.amountOutMinimum, "mock min");
        require(amountOut > 0, "mock no out");
        bool ok = IERC20(p.tokenOut).transfer(p.recipient, amountOut);
        require(ok, "mock transfer failed");
        return amountOut;
    }
}

contract MockWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    receive() external payable { balanceOf[msg.sender] += msg.value; }
    function deposit() external payable { balanceOf[msg.sender] += msg.value; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Shared fixtures + mining helpers used across the test suites.
abstract contract HashBotsTestBase is Test {
    address internal constant WETH =
        address(0x4200000000000000000000000000000000000006);

    HashToken internal token;
    Pool internal pool;
    PowBots internal bots;
    MockSwapRouter internal router;

    // Prod defaults for reference.
    uint256 internal constant PROD_FLOOR_BITS = 26;
    uint256 internal constant PROD_WALL_FROM = 4444;
    uint256 internal constant PROD_WALL_DIV = 200;
    uint256 internal constant PROD_UNIQUE_WINDOW = 1024;
    uint256 internal constant PROD_UNIQUE_TOTAL = 16;
    uint256 internal constant PROD_SUPPLY_FLOOR = 4096;

    function _deploy(uint256 floorBits_) internal {
        _deployFull(floorBits_, PROD_WALL_FROM, PROD_WALL_DIV, PROD_UNIQUE_WINDOW, PROD_UNIQUE_TOTAL, PROD_SUPPLY_FLOOR);
    }

    function _deployFull(
        uint256 floorBits_,
        uint256 wallFrom_,
        uint256 wallDiv_,
        uint256 uniqueWindow_,
        uint256 uniqueTotal_,
        uint256 supplyFloor_
    ) internal {
        vm.roll(1000); // ensure blockhash(block.number-1) != 0
        vm.warp(1_000_000);
        vm.etch(WETH, address(new MockWETH()).code);

        token = new HashToken();
        router = new MockSwapRouter();
        pool = new Pool(token, WETH, ISwapRouter(address(router)), 3000, 500);
        bots = new PowBots("HashBots", "BOT", token, IPool(address(pool)), floorBits_, wallFrom_, wallDiv_, uniqueWindow_, uniqueTotal_, supplyFloor_);

        token.setPowBots(address(bots));
        pool.setPowBots(address(bots));
        pool.setKeeper(address(this), true); // buyback tests call swapAndBurn as the test contract

        // Seed the pool with the 1M genesis $BOT and give the mock router BOT for buyback tests.
        token.transfer(address(pool), token.GENESIS_SUPPLY());
        deal(address(token), address(router), 10_000e18);
    }

    /// @dev Solve the puzzle for `miner` and mint. Returns the tokenId.
    function _mint(address miner) internal returns (uint256 tokenId) {
        return _mintAt(miner, 0);
    }

    /// @dev Mint forcing solve to start at `startNonce` (for stale/expired-structure tests).
    function _mintAt(address miner, uint64 startNonce) internal returns (uint256 tokenId) {
        return _mintWith(miner, startNonce, 0);
    }

    /// @dev Mint supplying explicit prevWork override (0 = use lastWork()).
    ///      `_maybeRetarget` folds epoch-floor snaps / pace / wall INTO the mint, so a stateless
    ///      re-query would keep solving against a stale target. Mirror the fold exactly
    ///      (`_forecastTarget`) so one solve always lands; keep a small safety loop anyway.
    function _mintWith(address miner, uint64 startNonce, uint256 prevOverride)
        internal
        returns (uint256 tokenId)
    {
        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 prev = prevOverride == 0 ? bots.lastWork() : prevOverride;
        address m = miner == address(0) ? address(0xBEEF) : miner;
        uint64 nonce = startNonce;
        for (uint256 attempt = 0; attempt < 3; attempt++) {
            uint256 target = _forecastTarget(m);
            nonce = _solve(m, prev, anchor, target, nonce);
            uint256 price = bots.mintPrice();
            vm.deal(m, price + 1);
            vm.prank(m);
            try bots.mint{value: price}(nonce, prev, anchorNum, anchor) returns (uint256 id) {
                return id;
            } catch (bytes memory reason) {
                bytes memory expected = abi.encodeWithSignature("Error(string)", "Above target");
                if (keccak256(reason) != keccak256(expected)) revert("UNEXPECTED_REVERT");
            }
            nonce += 1;
        }
        revert("solve+retry exhausted");
    }

    /// @dev Deterministic mirror of the in-mint `_maybeRetarget` fold, so the solve uses the exact
    ///      target the mint will enforce (snapshot is stable within a single test frame).
    function _forecastTarget(address miner) internal view returns (uint256) {
        uint256 base = bots.baseTarget();
        if (bots.totalMinted() - bots.lastRetargetMinted() >= bots.RETARGET_WINDOW()) {
            uint256 elapsed = block.timestamp - bots.windowStartTime();
            uint256 expected = bots.TARGET_INTERVAL() * bots.RETARGET_WINDOW();
            uint256 newBase = base;
            if (elapsed < expected / bots.MAX_RETARGET_UP()) {
                newBase = base / bots.MAX_RETARGET_UP();
            } else if (elapsed > expected * bots.MAX_RETARGET_DOWN()) {
                newBase = base > type(uint256).max / bots.MAX_RETARGET_DOWN()
                    ? type(uint256).max
                    : base * bots.MAX_RETARGET_DOWN();
            }
            uint256 floor = bots.epochFloor(bots.currentEpoch());
            if (newBase > floor) newBase = floor;
            if (bots.totalMinted() >= bots.wallFrom()) {
                uint256 over = bots.totalMinted() - bots.wallFrom();
                newBase = newBase / (1 + over / bots.wallDiv());
            }
            base = newBase;
        }
        uint256 t = base >> bots.effectiveNetworkBurst();
        return t >> bots.effectivePersonalBurst(miner);
    }

    /// @dev Mint using an externally supplied nonce (skips solving). Expect revert for bad nonce.
    function _mintWithNonce(address miner, uint64 nonce, uint256 prev, uint256 anchorNum, bytes32 anchor)
        internal
        returns (uint256 tokenId)
    {
        return _mintWithNoncePrice(miner, nonce, prev, anchorNum, anchor, bots.mintPrice());
    }

    /// @dev Same as above but price is supplied by the caller so `vm.expectRevert` can be placed
    ///      directly before the mint call without being consumed by a mintPrice() staticcall.
    function _mintWithNoncePrice(
        address miner,
        uint64 nonce,
        uint256 prev,
        uint256 anchorNum,
        bytes32 anchor,
        uint256 price
    ) internal returns (uint256 tokenId) {
        vm.deal(miner, price + 1);
        vm.prank(miner);
        tokenId = bots.mint{value: price}(nonce, prev, anchorNum, anchor);
        return tokenId;
    }

    function _anchor() internal view returns (uint256 anchorNum, bytes32 anchor) {
        anchorNum = block.number - 1;
        anchor = blockhash(anchorNum);
    }

    /// @dev Solve the 92-byte puzzle with a fixed scratch buffer (minimal gas per attempt).
    ///      Layout: miner(20) | nonce u64 BE(8) | prevWork(32) | anchor(32) — matches
    ///      KeccakPacked.workHash so solutions used here are valid on-chain.
    function _solve(address miner, uint256 prev, bytes32 anchor, uint256 target, uint64 startNonce)
        internal
        pure
        returns (uint64 nonce)
    {
        uint64 n = startNonce;
        while (true) {
            uint256 h;
            assembly {
                mstore(0x80, shl(96, miner))
                mstore(0x94, shl(192, n))
                mstore(0x9c, prev)
                mstore(0xbc, anchor)
                h := keccak256(0x80, 92)
            }
            if (h < target) return n;
            n++;
        }
    }

    /// @dev Assert helpers.
    function _assertEqUint(uint256 a, uint256 b, string memory msg_) internal pure {
        // placeholder kept here in case helpers evolve
        assertEq(a, b, msg_);
    }
}