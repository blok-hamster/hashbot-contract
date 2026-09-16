// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {HashBotsTestBase} from "./TestBase.sol";

/// @dev Pool access hardening (audit 2016-09-15): router is set-once so an owner can
///      never redirect the pool's ETH into a malicious router, and swapAndBurn is
///      keeper-gated so a public caller can't grief the buyback rate.
contract PoolGatesTest is HashBotsTestBase {
    address internal alice = address(0xA11CE);
    address internal carol = address(0xC0FFEE);

    function setUp() public {
        _deployFull(1, 16376, 200, 1024, 16, 0);
    }

    // ── setSwapRouter: set-once ──────────────────────────────────────────────

    function test_Router_SetOnce() public {
        // Constructor already set the mock router; an owner can never swap it out.
        vm.expectRevert(bytes("Already set"));
        pool.setSwapRouter(ISwapRouter(address(router)));
    }

    function test_Router_OnlyOwner() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        pool.setSwapRouter(ISwapRouter(address(router)));
    }

    // ── setKeeper: onlyOwner ─────────────────────────────────────────────────

    function test_SetKeeper_OnlyOwner() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        pool.setKeeper(carol, true);
    }

    function test_SetKeeper_ZeroDisabled() public {
        vm.expectRevert(bytes("Zero"));
        pool.setKeeper(address(0), true);
    }

    function test_SetKeeper_GrantsAndRevokes() public {
        pool.setKeeper(carol, true);
        assertTrue(pool.keepers(carol), "keeper granted");
        pool.setKeeper(carol, false);
        assertFalse(pool.keepers(carol), "keeper revoked");
    }

    // ── swapAndBurn: keeper-gated ────────────────────────────────────────────

    function test_SwapAndBurn_Unauthorized_Reverts() public {
        // Pool has no ETH; the keeper gate must reject before the balance check.
        vm.prank(carol);
        vm.expectRevert(bytes("Not keeper"));
        pool.swapAndBurn(1);
    }

    function test_SwapAndBurn_KeeperCanSwap() public {
        for (uint256 i = 0; i < 2; i++) _mint(address(uint160(0x900 + i)));
        uint256 poolEth = address(pool).balance;
        assertGt(poolEth, 0);

        uint256 expectedOut = (poolEth * router.pricePerEth()) / 1e18;
        uint256 supplyBefore = token.totalSupply();

        pool.swapAndBurn(expectedOut); // test contract is keeper (TestBase fixture)

        assertEq(token.totalSupply(), supplyBefore - expectedOut, "bought back and burned");
    }

    function test_SwapAndBurn_RevokedKeeper_Reverts() public {
        for (uint256 i = 0; i < 2; i++) _mint(address(uint160(0xA00 + i)));

        pool.setKeeper(address(this), false);
        vm.expectRevert(bytes("Not keeper"));
        pool.swapAndBurn(1);
    }

    function test_Slippage_OwnerOnly() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        pool.setMaxSlippageBps(500);
    }
}