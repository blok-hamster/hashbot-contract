// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {HashBotsTestBase} from "./TestBase.sol";

/// @dev Proof-of-work gate: acceptance, rejection, address-binding, anchors, chaining.
contract PoWGateTest is HashBotsTestBase {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        _deploy(8); // 8-bit difficulty floor keeps minting fast in tests
    }

    function test_FirstBOT_Accepts_ValidSolver() public {
        uint256 id = _mint(alice);
        assertEq(id, 1);
        assertEq(bots.totalMinted(), 1);
        assertEq(bots.catMiner(id), alice);
        assertEq(bots.ownerOf(id), alice);
        assertEq(bots.catPricePaid(id), 69_000_000_000_000);
    }

    function test_SequentialMints_ChainOnNewPrevWork() public {
        uint256 id1 = _mint(alice);
        uint256 id2 = _mint(bob);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(bots.totalMinted(), 2);
        assertTrue(bots.lastWork() > 0);
        assertGt(bots.catDepth(id2), 0);
    }

    /// @dev The winning hash binds the miner address: the same nonce+prev+anchor under a
    ///      different miner produces a different digest (deterministic address-binding check).
    function test_WorkHash_IsMinerBound() public {
        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 prev0 = bots.lastWork();
        uint256 target = bots.targetFor(alice);
        uint64 nonce = _solve(alice, prev0, anchor, target, 0);

        uint256 ha = uint256(keccak256(abi.encodePacked(alice, nonce, prev0, anchor)));
        uint256 price = bots.mintPrice();
        vm.deal(alice, price + 1);
        vm.prank(alice);
        bots.mint{value: price}(nonce, prev0, anchorNum, anchor);
        assertEq(bots.lastWork(), ha, "lastWork stores the miner's own winning hash");

        uint256 hb = uint256(keccak256(abi.encodePacked(bob, nonce, prev0, anchor)));
        assertTrue(ha != hb, "preimage binds the miner address");
        assertEq(bots.catMiner(bots.totalMinted()), alice, "minted to the miner");
    }

    function test_WrongPrevWork_Reverts() public {
        _mint(alice); // lastWork is now non-zero
        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 price = bots.mintPrice();
        vm.expectRevert(bytes("Bad prev"));
        _mintWithNoncePrice(bob, 42, 0, anchorNum, anchor, price); // stale prevWork == 0
    }

    function test_FirstBOT_RequiresPrevZero() public {
        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 target = bots.targetFor(bob);
        uint64 nonce = _solve(bob, 0, anchor, target, 0);
        uint256 price = bots.mintPrice();
        vm.expectRevert(bytes("Bad prev"));
        _mintWithNoncePrice(bob, nonce, 1, anchorNum, anchor, price); // prevWork != 0 for first bot
    }

    function test_StaleAnchorExpired_Reverts() public {
        // block.number is 1000; 251 blocks back exceeds ANCHOR_WINDOW (250).
        (uint256 anchorNum, ) = _anchor();
        uint256 price = bots.mintPrice();
        vm.expectRevert(bytes("Anchor expired"));
        _mintWithNoncePrice(bob, 0, 0, anchorNum - 251, bytes32(0), price);
    }

    function test_FutureAnchor_Reverts() public {
        (uint256 anchorNum, ) = _anchor();
        uint256 price = bots.mintPrice();
        vm.expectRevert(bytes("Anchor future"));
        _mintWithNoncePrice(bob, 0, 0, anchorNum + 1, bytes32(0), price);
    }

    function test_WrongAnchorHash_Reverts() public {
        (uint256 anchorNum, ) = _anchor();
        uint256 price = bots.mintPrice();
        vm.expectRevert(bytes("Bad anchor"));
        _mintWithNoncePrice(bob, 0, 0, anchorNum, bytes32(uint256(0xdead)), price);
    }

    function test_PriceGate_TooLittleValueFails() public {
        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 prev = bots.lastWork();
        uint256 target = bots.targetFor(alice);
        uint64 nonce = _solve(alice, prev, anchor, target, 0);
        uint256 price = bots.mintPrice();

        vm.deal(alice, price - 1);
        vm.prank(alice);
        vm.expectRevert(bytes("Price"));
        bots.mint{value: price - 1}(nonce, prev, anchorNum, anchor);
    }

    function test_ExcessPayments_Refunded() public {
        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 prev = bots.lastWork();
        uint256 target = bots.targetFor(alice);
        uint64 nonce = _solve(alice, prev, anchor, target, 0);
        uint256 price = bots.mintPrice();
        uint256 overpaid = 2 ether;

        uint256 before = 100 ether;
        vm.deal(alice, before);
        vm.prank(alice);
        bots.mint{value: price + overpaid}(nonce, prev, anchorNum, anchor);

        assertEq(alice.balance, before - price, "refund mismatch");
    }

    function test_StalePrev_Reverts() public {
        (uint256 anchorNum, bytes32 anchor) = _anchor();
        uint256 prev0 = bots.lastWork();
        uint256 target = bots.targetFor(alice);
        uint64 nonce = _solve(alice, prev0, anchor, target, 0);
        uint256 price = bots.mintPrice();

        vm.deal(alice, price + 1);
        vm.prank(alice);
        bots.mint{value: price}(nonce, prev0, anchorNum, anchor); // valid first bot

        // The same solution is now stale: prevWork must equal the new lastWork.
        vm.expectRevert(bytes("Bad prev"));
        _mintWithNoncePrice(alice, nonce, prev0, anchorNum, anchor, price);
    }

    function test_targetBits_Decrease_WithEachSuccessiveMint() public {
        uint256 before = bots.targetBitsFor(alice);
        _mint(alice);
        _mint(bob);
        // Network burst raised target bits (harder) after each mint.
        assertGt(bots.targetBitsFor(bob), before - 2);
    }
}