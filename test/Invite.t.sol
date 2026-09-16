// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HashBotsTestBase} from "./TestBase.sol";

contract InviteTest is HashBotsTestBase {
    address internal alice = address(0xA11CE);
    address internal bob   = address(0xB0B);

    function setUp() public {
        _deploy(1);
    }

    function test_InviteGated_DefaultsToFalse() public view {
        assertFalse(bots.inviteGated(), "Default false");
    }

    function test_InviteGated_OwnerCanToggle() public {
        bots.setInviteGated(true);
        assertTrue(bots.inviteGated(), "Gated enabled");

        bots.setInviteGated(false);
        assertFalse(bots.inviteGated(), "Gated disabled");
    }

    function test_InviteGated_RevertsUninvitedMiner() public {
        bots.setInviteGated(true);

        uint256 price = bots.mintPrice();
        vm.deal(alice, price);

        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 prev = bots.lastWork();
        uint256 target = _forecastTarget(alice);
        uint64 nonce = _solve(alice, prev, anchor, target, 0);

        vm.prank(alice);
        vm.expectRevert(bytes("Invite required"));
        bots.mint{value: price}(nonce, prev, anchorNum, anchor);
    }

    function test_RedeemInvite_AuthorizesMiner() public {
        string memory code = "HASHBOTS-EARLY-ACCESS";
        bots.addInviteCode(code);

        vm.prank(alice);
        bots.redeemInvite(code);

        assertTrue(bots.isInvited(alice), "Alice authorized");
    }

    function test_RedeemInvite_InvalidCodeReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Invalid invite code"));
        bots.redeemInvite("WRONG-CODE");
    }

    function test_InvitedMiner_CanMintWhenGated() public {
        bots.setInviteGated(true);
        string memory code = "EXCLUSIVE-MINER-2026";
        bots.addInviteCode(code);

        vm.prank(alice);
        bots.redeemInvite(code);

        uint256 price = bots.mintPrice();
        vm.deal(alice, price);

        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 prev = bots.lastWork();
        uint256 target = _forecastTarget(alice);
        uint64 nonce = _solve(alice, prev, anchor, target, 0);

        vm.prank(alice);
        uint256 id = bots.mint{value: price}(nonce, prev, anchorNum, anchor);
        assertEq(id, 1, "Minted id 1");
    }

    function test_MintWithInvite_RedeemsAndMints() public {
        bots.setInviteGated(true);

        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 prev = bots.lastWork();
        uint256 target = _forecastTarget(alice);
        uint64 nonce = _solve(alice, prev, anchor, target, 0);

        string memory code = "ATOMIC-INVITE-KEY";
        bots.addInviteCode(code);

        uint256 price = bots.mintPrice();
        vm.deal(alice, price);

        vm.prank(alice);
        uint256 id = bots.mintWithInvite{value: price}(nonce, prev, anchorNum, anchor, code);
        assertEq(id, 1, "Minted id 1");
        assertTrue(bots.isInvited(alice), "Alice now invited");
    }

    function test_Owner_CanDirectlyInviteAddress() public {
        bots.setInviteGated(true);

        assertFalse(bots.isInvited(bob));
        bots.setAddressInvited(bob, true);
        assertTrue(bots.isInvited(bob));

        bots.setAddressInvited(bob, false);
        assertFalse(bots.isInvited(bob));
    }

    function test_InviteUntil_ExpirationOpensToPublic() public {
        uint256 window = block.timestamp + 1 days;
        bots.setInviteUntil(window);
        assertTrue(bots.inviteGated(), "Gated before expiration");

        uint256 price = bots.mintPrice();
        vm.deal(alice, price);

        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 prev = bots.lastWork();
        uint256 target = _forecastTarget(alice);
        uint64 nonce = _solve(alice, prev, anchor, target, 0);

        // Before expiration: uninvited fails
        vm.prank(alice);
        vm.expectRevert(bytes("Invite required"));
        bots.mint{value: price}(nonce, prev, anchorNum, anchor);

        // Warp past expiration timestamp
        vm.warp(window + 1);
        assertFalse(bots.inviteGated(), "Ungated after expiration");

        // After expiration: uninvited succeeds automatically
        vm.prank(alice);
        uint256 id = bots.mint{value: price}(nonce, prev, anchorNum, anchor);
        assertEq(id, 1, "Public mint succeeded after expiration");
    }
}
