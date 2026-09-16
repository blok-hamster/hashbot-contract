// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {HashBotsTestBase} from "./TestBase.sol";
import {HashBotsRenderer} from "../src/HashBotsRenderer.sol";
import {SSTORE2Read} from "../src/libraries/SSTORE2Read.sol";
import {RarityTable} from "../src/libraries/RarityTable.sol";
import {LOOKUP_TABLE} from "../src/LookupTable.sol";

/// @dev Forge tests: weight, trait inheritance, fee split, supply floor, gates, ladder.
///      Deploys a real renderer (with 8 SSTORE2 chunks) so _traitOf works for mined inputs.
contract ForgeTest is HashBotsTestBase {
    address internal alice = address(0xA11CE);
    address internal bob   = address(0xB0B0B);

    HashBotsRenderer internal renderer;

    function setUp() public {
        _deployFull(1, 16376, 200, 1024, 16, 0); // supplyFloor = 0 for forge tests
        _deployRenderer();
    }

    // ── Renderer fixture (mirrors RendererFixture) ───────────────────────────

    function _deployRenderer() internal {
        for (uint256 i = 0; i < 8; i++) {
            _deployChunk(_chunkName(i));
        }
        renderer = new HashBotsRenderer(
            chunks[0], chunks[1], chunks[2], chunks[3],
            chunks[4], chunks[5], chunks[6], chunks[7],
            LOOKUP_TABLE
        );
        bots.setRenderer(renderer);
    }

    address[8] internal chunks;

    function _chunkName(uint256 i) internal pure returns (string memory) {
        string[8] memory names = [
            "chunk-00.bin", "chunk-01.bin", "chunk-02.bin", "chunk-03.bin",
            "chunk-04.bin", "chunk-05.bin", "chunk-06.bin", "chunk-07.bin"
        ];
        return names[i];
    }

    function _deployChunk(string memory filename) internal returns (address deployed) {
        bytes memory data = vm.readFileBinary(
            string(abi.encodePacked("images/handoff/chunks/", filename))
        );
        deployed = SSTORE2Read.write(data);
        // Fill next slot of chunks.
        for (uint256 i = 0; i < 8; i++) {
            if (chunks[i] == address(0)) { chunks[i] = deployed; break; }
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    /// @dev Mint three bots for alice, warp past the age gate, return [id1, id2, id3].
    function _trio() internal returns (uint256 id1, uint256 id2, uint256 id3) {
        id1 = _mint(alice);
        vm.warp(block.timestamp + 65); // cool burst
        id2 = _mint(alice);
        vm.warp(block.timestamp + 65);
        id3 = _mint(alice);
        vm.warp(block.timestamp + 700); // past the 600s age gate
    }

    /// @dev The actual fee the forge function requires (epoch pressure: max of FORGE_FEE, mintPrice).
    function _forgeFee() internal view returns (uint256) {
        uint256 mintP = bots.mintPrice();
        return bots.FORGE_FEE() < mintP ? mintP : bots.FORGE_FEE();
    }

    // ── Core forge tests ─────────────────────────────────────────────────────

    function test_Forge_CommonToRare() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = _forgeFee();
        vm.deal(alice, fee + 1 ether);

        uint256 beforeBotBalance = token.balanceOf(alice);

        vm.prank(alice);
        uint256 outId = bots.forge{value: fee}(id1, id2, id3);

        // Output id in the forge space, owned by alice.
        assertEq(outId, bots.FORGE_ID_START() + 1);
        assertEq(bots.ownerOf(outId), alice);

        // Weight: 3 commons → 1 rare, weight preserved (1+1+1 → 3).
        assertEq(bots.catWeight(outId), 3);
        assertTrue(bots.catForged(outId));

        // Alive and weight invariants: 4 minted, 3 alive after forge (3-3+1=1... wait, no. We started with 3 bots alive, forge consumes 3, creates 1: 3-2 = 1 alive. totalWeight starts at 3 (3 commons), ends at 3 (1 rare).)
        assertEq(bots.aliveCount(), 1, "alive after forge");
        assertEq(bots.totalWeight(), 3, "total weight unchanged");

        // 1000 $BOT minted to alice.
        assertEq(token.balanceOf(alice) - beforeBotBalance, 1000e18, "forge reward");

        // Forge lock set.
        assertTrue(bots.forgeLocked(outId), "lock set");
    }

    function test_Forge_FeeSplit70_30() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = _forgeFee();
        // With no stakers active, the 3% stake bonus is diverted to buyback pool (30% + 3% = 33%).
        uint256 expectedHook = (fee * 3300) / 10000;
        uint256 poolBefore = address(pool).balance;

        vm.deal(alice, fee + 1 ether);
        vm.prank(alice);
        bots.forge{value: fee}(id1, id2, id3);

        assertEq(address(pool).balance - poolBefore, expectedHook, "33% to buyback pool (30% hook + 3% diverted stake bonus)");
    }

    function test_Forge_CarryRent() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();

        // Mint some more bots to build rent.
        _mint(bob);
        _mint(bob);

        // Each input should have rent from the two extra mints.
        uint256 rent1Before = alice.balance;
        vm.prank(alice);
        bots.collectRent(id1);
        uint256 r1 = alice.balance - rent1Before;
        assertGt(r1, 0, "id1 has unclaimed rent");

        // Forge the inputs (unclaimed rent at this point is 0 for id1, some for id2/id3).
        uint256 fee = _forgeFee();
        vm.deal(alice, fee + 1 ether);
        vm.prank(alice);
        uint256 outId = bots.forge{value: fee}(id1, id2, id3);

        // The output's unclaimed rent should include id2's and id3's prior claims.
        vm.deal(alice, 1 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        bots.collectRent(outId);
        uint256 claimed = alice.balance - before;
        assertGt(claimed, 0, "output carries rent");
    }

    function test_Forge_WeightPreserved_AcrossTiers() public {
        // This test verifies that burn correctly decrements weight for forged outputs too.
        (uint256 id1, uint256 id2, uint256 id3) = _trio();

        uint256 fee = _forgeFee();
        vm.deal(alice, fee + 1 ether);
        vm.prank(alice);
        uint256 rareId = bots.forge{value: fee}(id1, id2, id3);
        assertEq(bots.totalWeight(), 3);

        // Burn the rare (weight 3): totalWeight should drop to 0.
        vm.warp(block.timestamp + 600);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        bots.burn(rareId);
        assertEq(bots.totalWeight(), 0, "weight leaves on burn");
        assertEq(bots.aliveCount(), 0);
    }

    /// @dev Doc:133 only forbids selling / forging during the 24h output lock. Burning
    ///      after the 600s age gate but still inside the lock window is lawful (audit
    ///      decision 2016-09-15 — pinned so a future lock gate on burn() can't silently
    ///      flip this).
    function test_Forge_OutputCanBurnWithinLock_AfterAgeGate() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = _forgeFee();
        vm.deal(alice, fee + 1 ether);
        vm.prank(alice);
        uint256 outId = bots.forge{value: fee}(id1, id2, id3);

        vm.warp(block.timestamp + 600); // age gate passed; 24h output lock still active
        assertTrue(bots.forgeLocked(outId), "still in the 24h lock");

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        bots.burn(outId);

        assertTrue(bots.catBurned(outId), "burned during the 24h lock is lawful");
        assertEq(bots.aliveCount(), 0, "burn consumed the only live bot");
    }

    // ── Trait inheritance ─────────────────────────────────────────────────────

    function test_Forge_InheritsRarestPerSlot() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();

        uint256 fee = _forgeFee();
        vm.deal(alice, fee + 1 ether);
        vm.prank(alice);
        uint256 outId = bots.forge{value: fee}(id1, id2, id3);

        uint256[6] memory outTraits = bots.getForgeTraits(outId);

        // For each slot, verify the output trait is the rarest among the three inputs.
        for (uint256 slot = 0; slot < 6; slot++) {
            uint256[3] memory inputTraits = [
                _traitOfId(id1, slot),
                _traitOfId(id2, slot),
                _traitOfId(id3, slot)
            ];
            uint256[3] memory inputIds = [id1, id2, id3];

            uint256 expectedShare = RarityTable.shareOf(outTraits[slot]);
            // The output's share must be <= the rarest input's share.
            uint256 minInputShare = type(uint256).max;
            uint256 minInputId = type(uint256).max;
            for (uint256 k = 0; k < 3; k++) {
                uint256 s = RarityTable.shareOf(inputTraits[k]);
                if (s < minInputShare || (s == minInputShare && inputIds[k] < minInputId)) {
                    minInputShare = s;
                    minInputId = inputIds[k];
                }
            }
            assertEq(expectedShare, minInputShare, "output trait must be rarest per slot");
        }
    }

    /// @dev Read trait of an owned bot by slot (supports both mined and forged).
    function _traitOfId(uint256 tokenId, uint256 slot) internal view returns (uint256) {
        if (bots.catForged(tokenId)) {
            uint256[6] memory t = bots.getForgeTraits(tokenId);
            return t[slot];
        }
        return renderer.selectTraits(bots.catSeed(tokenId))[slot];
    }

    // ── Gate tests ───────────────────────────────────────────────────────────

    function test_Forge_RevertsWhenNotOwner() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = _forgeFee();
        vm.deal(bob, fee);
        vm.prank(bob);
        vm.expectRevert(bytes("Not owner"));
        bots.forge{value: fee}(id1, id2, id3);
    }

    function test_Forge_RevertsDifferentWeights() public {
        (uint256 id1, ,) = _trio();
        uint256 id4 = _mint(alice); // common (weight 1) same as id1

        // Create a Rare from three more commons.
        (uint256 ra, uint256 rb, uint256 rc) = _trio();
        uint256 fee = _forgeFee();
        vm.deal(alice, fee + 1 ether);
        vm.prank(alice);
        uint256 rareId = bots.forge{value: fee}(ra, rb, rc);

        // id1 (Common), id4 (Common), rareId (Rare) — different weights.
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(bytes("Weight mismatch"));
        bots.forge{value: fee}(id1, id4, rareId);
    }

    function test_Forge_RevertsAgeGate() public {
        _mint(alice); // id1
        vm.warp(block.timestamp + 1);
        _mint(alice); // id2
        vm.warp(block.timestamp + 1);
        _mint(alice); // id3
        // No warp past 600s — should fail on first check ("Age a").
        uint256 fee = _forgeFee();
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(bytes("Age a"));
        bots.forge{value: fee}(1, 2, 3);
    }

    function test_Forge_RevertsCooldown() public {
        // Mint 6 bots upfront so both trios are age-gated together.
        uint256 id1 = _mint(alice);
        vm.warp(block.timestamp + 65);
        uint256 id2 = _mint(alice);
        vm.warp(block.timestamp + 65);
        uint256 id3 = _mint(alice);
        vm.warp(block.timestamp + 65);
        uint256 id4 = _mint(alice);
        vm.warp(block.timestamp + 65);
        uint256 id5 = _mint(alice);
        vm.warp(block.timestamp + 65);
        uint256 id6 = _mint(alice);
        vm.warp(block.timestamp + 700); // all 6 are now 600s+ old

        uint256 fee = _forgeFee();
        vm.deal(alice, 2 ether);

        // First forge succeeds.
        vm.prank(alice);
        bots.forge{value: fee}(id1, id2, id3);

        // Second forge immediately — cooldown hasn't elapsed.
        vm.prank(alice);
        vm.expectRevert(bytes("Cooldown"));
        bots.forge{value: fee}(id4, id5, id6);

        // Warp 60s — second forge succeeds.
        vm.warp(block.timestamp + 60);
        vm.prank(alice);
        bots.forge{value: fee}(id4, id5, id6);
        assertEq(bots.forgeCount(), 2);
    }

    function test_Forge_RevertsLockedOutput24h() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = _forgeFee();
        vm.deal(alice, fee + 1 ether);
        vm.prank(alice);
        uint256 rareId = bots.forge{value: fee}(id1, id2, id3);

        // Attempt to transfer within 24h — should revert.
        vm.prank(alice);
        vm.expectRevert();
        bots.transferFrom(alice, bob, rareId);

        // Warp past 24h — transfer succeeds.
        vm.warp(block.timestamp + 24 hours);
        vm.prank(alice);
        bots.transferFrom(alice, bob, rareId);
        assertEq(bots.ownerOf(rareId), bob);
    }

    function test_Forge_RevertsMaxTier() public {
        // Mint 3 bots, cheat their weight to 27 (legendary), forge them → should revert.
        uint256 id1 = _mint(alice);
        vm.warp(block.timestamp + 1);
        uint256 id2 = _mint(alice);
        vm.warp(block.timestamp + 1);
        uint256 id3 = _mint(alice);
        vm.warp(block.timestamp + 700);

        // Cheat weight to 27 for each input.
        // catWeight is at storage slot 42.
        vm.store(address(bots), keccak256(abi.encode(id1, uint256(42))), bytes32(uint256(27)));
        vm.store(address(bots), keccak256(abi.encode(id2, uint256(42))), bytes32(uint256(27)));
        vm.store(address(bots), keccak256(abi.encode(id3, uint256(42))), bytes32(uint256(27)));

        uint256 fee = _forgeFee();
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(bytes("Max tier"));
        bots.forge{value: fee}(id1, id2, id3);
    }

    // ── Epoch pressure ───────────────────────────────────────────────────────

    function test_Forge_EpochPressure_FeeFollowsMintPrice() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = _forgeFee();
        vm.deal(alice, fee + 1 ether);

        // Underpaying by 1 wei should revert "Fee".
        vm.prank(alice);
        vm.expectRevert(bytes("Fee"));
        bots.forge{value: fee - 1}(id1, id2, id3);
    }

    function test_Forge_FeeRefundsExcess() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = _forgeFee();
        uint256 overpayment = 0.1 ether;
        vm.deal(alice, fee + overpayment + 1 ether);
        uint256 balBefore = alice.balance;

        vm.prank(alice);
        bots.forge{value: fee + overpayment}(id1, id2, id3);

        // Alice should get overpayment back.
        assertApproxEqRel(alice.balance, balBefore - fee, 1e14, "excess refunded");
    }

    // ── Supply floor ─────────────────────────────────────────────────────────

    function test_Forge_RevertsBelowFloor() public {
        // Deploy with floor = 5: forge requires alive - 2 >= 5 → alive >= 7.
        _deployFull(1, 16376, 200, 1024, 16, 5);
        _deployRenderer();

        // Mint only 4 bots → aliveCount = 4 < 7 → forge reverts.
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = _forgeFee();
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(bytes("Floor"));
        bots.forge{value: fee}(id1, id2, id3);
    }

    // ── Tier ladder (Rare → Epic → Legendary) ────────────────────────────────

    function test_Forge_Ladder_RareToEpic() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = _forgeFee();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 rareId = bots.forge{value: fee}(id1, id2, id3);
        assertEq(bots.catWeight(rareId), 3, "rare");
        vm.warp(block.timestamp + 24 hours); // unlock first rare

        (uint256 id4, uint256 id5, uint256 id6) = _trio();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 rare2Id = bots.forge{value: fee}(id4, id5, id6);
        vm.warp(block.timestamp + 24 hours); // unlock second rare

        (uint256 id7, uint256 id8, uint256 id9) = _trio();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 rare3Id = bots.forge{value: fee}(id7, id8, id9);
        vm.warp(block.timestamp + 24 hours); // unlock third rare

        // Forge 3 rares → 1 epic.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 epicId = bots.forge{value: fee}(rareId, rare2Id, rare3Id);
        assertEq(bots.catWeight(epicId), 9, "epic");
        assertTrue(bots.catForged(epicId));
    }
}
