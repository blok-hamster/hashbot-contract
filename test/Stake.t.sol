// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HashBotsTestBase} from "./TestBase.sol";
import {HashBotsRenderer} from "../src/HashBotsRenderer.sol";
import {SSTORE2Read} from "../src/libraries/SSTORE2Read.sol";
import {LOOKUP_TABLE} from "../src/LookupTable.sol";
import {PowBotsLib} from "../src/libraries/PowBotsLib.sol";

/// @dev Staking tests: 7/30/90-day fixed terms, frozen share weights with
///      term × status multipliers (max 6×), strict lock enforcement (no early
///      unstake), staking reward deposits, early claim with 50% penalty
///      recycling, and difficulty integration.
contract StakeTest is HashBotsTestBase {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B0B);

    HashBotsRenderer internal renderer;

    function setUp() public {
        _deployFull(1, 16376, 200, 1024, 16, 0);
        _deployRenderer();
    }

    // ── Renderer fixture (mirrors ForgeTest — needed for forge's trait reads) ──

    address[8] internal chunks;

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
        for (uint256 i = 0; i < 8; i++) {
            if (chunks[i] == address(0)) { chunks[i] = deployed; break; }
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    /// @dev Mint n bots for `miner` in immediate succession (no warp) so the personal
    ///      burst actually builds — warping +60s between mints lets it cool to zero.
    function _mintRapid(address miner, uint256 n) internal returns (uint256 lastId) {
        for (uint256 i = 0; i < n; i++) {
            lastId = _mint(miner);
        }
    }

    function _trio() internal returns (uint256 id1, uint256 id2, uint256 id3) {
        id1 = _mint(alice);
        vm.warp(block.timestamp + 65);
        id2 = _mint(alice);
        vm.warp(block.timestamp + 65);
        id3 = _mint(alice);
        vm.warp(block.timestamp + 700); // past the 600s age gate
    }

    // ── Core staking: fixed terms (7/30/90 days) ──────────────────────────

    function test_Stake_7DayTerm() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        assertTrue(bots.staked(id), "staked flag");
        assertEq(bots.stakedCount(alice), 1, "count");
        assertEq(bots.stakeLockDays(id), 7, "lock days stored");
        assertEq(bots.stakeUnlock(id), block.timestamp + 7 days, "unlock in 7d");
        assertEq(bots.stakeBits(alice), 1, "1 bit eased");
    }

    function test_Stake_30DayTerm() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 30);

        assertEq(bots.stakeUnlock(id), block.timestamp + 30 days, "unlock in 30d");
        assertEq(bots.stakeLockDays(id), 30, "lock days 30");
    }

    function test_Stake_90DayTerm() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 90);

        assertEq(bots.stakeUnlock(id), block.timestamp + 90 days, "unlock in 90d");
        assertEq(bots.stakeLockDays(id), 90, "lock days 90");
    }

    function test_Stake_RevertsBadTerm() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("Bad term"));
        bots.stake(id, 14); // not 7, 30, or 90

        vm.prank(alice);
        vm.expectRevert(bytes("Bad term"));
        bots.stake(id, 1); // too short
    }

    function test_Stake_RevertsOldMinLock() public {
        // The old 86400 (24h) term is no longer valid
        uint256 id = _mint(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("Bad term"));
        bots.stake(id, 86400);
    }

    // ── Share weight: term × status multipliers ───────────────────────────

    function test_ShareWeight_Common7d() public {
        // Common (weight=1) × 7d → termMult=100, statusMult=100 → 1*100*100/10000 = 1
        uint256 w = PowBotsLib.computeShareWeight(1, 7);
        assertEq(w, 1, "common 7d = 1 share");
    }

    function test_ShareWeight_Common90d() public {
        // Common (weight=1) × 90d → termMult=300, statusMult=100 → 1*300*100/10000 = 3
        uint256 w = PowBotsLib.computeShareWeight(1, 90);
        assertEq(w, 3, "common 90d = 3 shares");
    }

    function test_ShareWeight_Legendary90d_MaxSetup() public {
        // Legendary (weight=27) × 90d → termMult=300, statusMult=200 → 27*300*200/10000 = 162
        // Compared to Common 7d (1): 162/1 ≈ ratio
        // But key: the MAX setup is 6× a basic one (per spec)
        // Basic = common 7d = 1 share. Max = legendary 90d.
        // ratio: 162 / 1 = 162, but the catWeight already differs.
        // The multipliers alone: (300*200) / (100*100) = 6.0
        uint256 basic = PowBotsLib.computeShareWeight(1, 7);
        uint256 maxSetup = PowBotsLib.computeShareWeight(27, 90);
        // maxSetup/basic per-unit-catWeight = 6× the basic per-unit
        assertEq((maxSetup * 10000) / (27 * basic), 60000, "6x multiplier ratio");
    }

    function test_ShareWeight_Rare30d() public {
        // Rare (weight=3) × 30d → termMult=150, statusMult=120 → 3*150*120/10000 = 5 (truncated from 5.4)
        uint256 w = PowBotsLib.computeShareWeight(3, 30);
        assertEq(w, 5, "rare 30d = 5 shares");
    }

    function test_Stake_ShareWeightFrozen() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        uint256 sw = bots.stakedShareWeight(id);
        assertEq(sw, PowBotsLib.computeShareWeight(1, 7), "share weight matches formula");
        assertGt(bots.totalStakedShareWeight(), 0, "total share weight tracked");
    }

    // ── Burst cancellation ──────────────────────────────────────────────────

    function test_Stake_LocksAndEasesOneBit() public {
        _mintRapid(alice, 2);
        uint256 burstBefore = bots.effectivePersonalBurst(alice);
        assertEq(burstBefore, 2, "burst built");

        vm.prank(alice);
        bots.stake(1, 7);

        assertEq(bots.effectivePersonalBurst(alice), 1, "burst eased by 1");
    }

    function test_Stake_BurstCancelledByStakedBits() public {
        _mintRapid(alice, 4);
        uint256 burst = bots.effectivePersonalBurst(alice);
        assertEq(burst, 4, "burst built");

        for (uint256 i = 1; i <= 4; i++) {
            vm.prank(alice);
            bots.stake(i, 7);
        }
        assertEq(bots.effectivePersonalBurst(alice), 0, "burst cancelled");
    }

    function test_Stake_MaxBitsPerWallet() public {
        _mintRapid(alice, 9);
        for (uint256 i = 1; i <= bots.STAKE_MAX_BITS(); i++) {
            vm.prank(alice);
            bots.stake(i, 7);
        }
        assertEq(bots.stakedCount(alice), 8, "staked 8 bots");
        assertEq(bots.stakeBits(alice), 8, "stakeBits is 8");

        // 9th stake succeeds for yield, stakeBits remains capped at 8
        vm.prank(alice);
        bots.stake(9, 7);
        assertEq(bots.stakedCount(alice), 9, "staked 9 bots");
        assertEq(bots.stakeBits(alice), 8, "stakeBits remains capped at 8");
    }

    // ── Ownership & double-stake guards ──────────────────────────────────────

    function test_Stake_RevertsWhenNotOwner() public {
        uint256 id = _mint(alice);
        vm.prank(bob);
        vm.expectRevert(bytes("Not owner"));
        bots.stake(id, 7);
    }

    function test_Stake_RevertsDoubleStake() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);
        vm.prank(alice);
        vm.expectRevert(bytes("Already staked"));
        bots.stake(id, 30);
    }

    // ── Forge output locks ───────────────────────────────────────────────────

    function test_Stake_RevertsForgeOutputDuringLock() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = bots.FORGE_FEE();
        vm.deal(alice, fee + 1 ether);
        vm.prank(alice);
        uint256 outId = bots.forge{value: fee}(id1, id2, id3);

        vm.prank(alice);
        vm.expectRevert(bytes("Locked 24h"));
        bots.stake(outId, 7);
    }

    function test_Stake_AllowsForgeOutputAfterLock() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();
        uint256 fee = bots.FORGE_FEE();
        vm.deal(alice, fee + 1 ether);
        vm.prank(alice);
        uint256 outId = bots.forge{value: fee}(id1, id2, id3);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(alice);
        bots.stake(outId, 7);

        assertTrue(bots.staked(outId), "forge output stakeable after 24h lock");
    }

    // ── Staked still earns rent ──────────────────────────────────────────────

    function test_Stake_StillEarnsRent() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        _mint(bob);

        uint256 before = alice.balance;
        vm.prank(alice);
        bots.collectRent(id);
        assertGt(alice.balance - before, 0, "staked bot still earns rent");
    }

    // ── What a staked bot cannot do ──────────────────────────────────────────

    function test_Stake_CannotTransferWhileStaked() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.prank(alice);
        vm.expectRevert(bytes("Staked"));
        bots.transferFrom(alice, bob, id);
    }

    function test_Stake_CannotBurnWhileStaked() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.warp(block.timestamp + 700);
        vm.prank(alice);
        vm.expectRevert(bytes("Staked"));
        bots.burn(id);
    }

    function test_Stake_CannotForgeWhileStaked() public {
        (uint256 id1, uint256 id2, uint256 id3) = _trio();

        vm.prank(alice);
        bots.stake(id1, 7);
        vm.prank(alice);
        bots.stake(id2, 7);

        uint256 fee = bots.FORGE_FEE();
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(bytes("Staked"));
        bots.forge{value: fee}(id1, id2, id3);
    }

    // ── Strict lock: NO early unstake ────────────────────────────────────────

    function test_Unstake_RevertsBeforeLock7d() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        // 6 days in — still locked
        vm.warp(block.timestamp + 6 days);
        vm.prank(alice);
        vm.expectRevert(bytes("Locked"));
        bots.unstake(id);
    }

    function test_Unstake_RevertsBeforeLock90d() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 90);

        vm.warp(block.timestamp + 89 days);
        vm.prank(alice);
        vm.expectRevert(bytes("Locked"));
        bots.unstake(id);
    }

    function test_Unstake_SucceedsAfterLock() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        bots.unstake(id);

        assertFalse(bots.staked(id), "un-staked");
        assertEq(bots.stakedCount(alice), 0, "count cleared");
        assertEq(bots.stakedShareWeight(id), 0, "share weight cleared");
    }

    function test_Unstake_NoFeeRequired() public {
        // The new system has no unstake fee — just strict time lock
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.warp(block.timestamp + 7 days);
        // Alice has 0 ETH, should still work (no fee)
        vm.deal(alice, 0);
        vm.prank(alice);
        bots.unstake(id);
        assertFalse(bots.staked(id), "unstaked with 0 ETH");
    }

    function test_Unstake_RestoresTransfer() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        bots.unstake(id);

        vm.prank(alice);
        bots.transferFrom(alice, bob, id);
        assertEq(bots.ownerOf(id), bob);
    }

    function test_Unstake_RevertsWhenNotStaked() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("Not staked"));
        bots.unstake(id);
    }

    function test_Unstake_RevertsWhenNotOwner() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        vm.expectRevert(bytes("Not owner"));
        bots.unstake(id);
    }

    // ── Staking reward deposits & distribution ───────────────────────────────

    function test_DepositStakingReward_Distributes() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        // Deposit 1 ETH as staking reward
        vm.deal(address(this), 1 ether);
        bots.depositStakingReward{value: 1 ether}();

        assertGt(bots.stakeRewardPerWeight(), 0, "reward per weight increased");
    }

    function test_DepositStakingReward_RevertsNoStakers() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("No stakers"));
        bots.depositStakingReward{value: 1 ether}();
    }

    function test_DepositStakingReward_RevertsNoETH() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.expectRevert(bytes("No ETH"));
        bots.depositStakingReward{value: 0}();
    }

    // ── Staking reward claims ────────────────────────────────────────────────

    function test_ClaimReward_FullPayoutAfterLock() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        // Deposit reward
        vm.deal(address(this), 1 ether);
        bots.depositStakingReward{value: 1 ether}();

        // Fast forward past lock
        vm.warp(block.timestamp + 7 days);

        uint256 before = alice.balance;
        vm.prank(alice);
        bots.claimStakingRewards(id);

        assertGt(alice.balance - before, 0, "alice received full reward");
        // Should be approximately 1 ETH minus rounding
        assertApproxEqRel(alice.balance - before, 1 ether, 1e16, "~1 ETH payout");
    }

    function test_ClaimReward_EarlyClaimPenalty50Pct() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        // Deposit reward
        vm.deal(address(this), 1 ether);
        bots.depositStakingReward{value: 1 ether}();

        // Claim BEFORE lock expires (early claim)
        uint256 before = alice.balance;
        vm.prank(alice);
        bots.claimStakingRewards(id);

        uint256 payout = alice.balance - before;
        // Should be approximately 50% (half is the penalty)
        assertApproxEqRel(payout, 0.5 ether, 5e16, "~50% payout on early claim");
    }

    function test_ClaimReward_PenaltyRecycledToStakers() public {
        // Stake two bots: alice gets id1, bob gets id2
        uint256 id1 = _mint(alice);
        uint256 id2 = _mint(bob);

        vm.prank(alice);
        bots.stake(id1, 7);
        vm.prank(bob);
        bots.stake(id2, 7);

        // Deposit reward
        vm.deal(address(this), 2 ether);
        bots.depositStakingReward{value: 2 ether}();

        uint256 rpwBefore = bots.stakeRewardPerWeight();

        // Alice claims early → 50% penalty; half of penalty recycled to stakers
        vm.prank(alice);
        bots.claimStakingRewards(id1);

        uint256 rpwAfter = bots.stakeRewardPerWeight();
        assertGt(rpwAfter, rpwBefore, "penalty recycled, rewardPerWeight increased");
    }

    function test_ClaimReward_PenaltyToBuybackPool() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.deal(address(this), 1 ether);
        bots.depositStakingReward{value: 1 ether}();

        uint256 poolBefore = address(pool).balance;

        // Early claim: 50% penalty, split: 25% to stakers, 25% to buyback
        vm.prank(alice);
        bots.claimStakingRewards(id);

        assertGt(address(pool).balance, poolBefore, "penalty reached buyback pool");
    }

    function test_ClaimReward_NoDoubleCollect() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.deal(address(this), 1 ether);
        bots.depositStakingReward{value: 1 ether}();

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        bots.claimStakingRewards(id);

        uint256 aliceBal = alice.balance;

        // Second claim: no new reward deposited, so pending is 0 (no-op, no extra payout)
        vm.prank(alice);
        bots.claimStakingRewards(id);

        assertEq(alice.balance, aliceBal, "no double collect");
    }

    function test_ClaimReward_RevertsNotOwner() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.deal(address(this), 1 ether);
        bots.depositStakingReward{value: 1 ether}();

        vm.prank(bob);
        vm.expectRevert(bytes("Not owner"));
        bots.claimStakingRewards(id);
    }

    // ── Unstake auto-claims remaining rewards ────────────────────────────────

    function test_Unstake_AutoClaimsReward() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        vm.deal(address(this), 1 ether);
        bots.depositStakingReward{value: 1 ether}();

        vm.warp(block.timestamp + 7 days);
        uint256 before = alice.balance;
        vm.prank(alice);
        bots.unstake(id);

        assertGt(alice.balance - before, 0, "unstake auto-claimed reward");
    }

    // ── Receive function deposits to stakers ────────────────────────────────

    function test_Receive_DistributesToStakers() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        bots.stake(id, 7);

        uint256 rpwBefore = bots.stakeRewardPerWeight();
        // Send ETH directly to the contract
        vm.deal(address(this), 1 ether);
        (bool ok,) = payable(address(bots)).call{value: 1 ether}("");
        assertTrue(ok, "send ETH");

        assertGt(bots.stakeRewardPerWeight(), rpwBefore, "receive deposited reward");
    }

    // ── Weight proportionality ──────────────────────────────────────────────

    function test_RewardProportional_HigherWeightGetsMore() public {
        // Alice stakes 7d, Bob stakes 90d → Bob has 3× share weight (for same catWeight)
        uint256 id1 = _mint(alice);
        uint256 id2 = _mint(bob);

        vm.prank(alice);
        bots.stake(id1, 7);  // shareWeight = 1
        vm.prank(bob);
        bots.stake(id2, 90); // shareWeight = 3

        vm.deal(address(this), 4 ether);
        bots.depositStakingReward{value: 4 ether}();

        vm.warp(block.timestamp + 90 days);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        bots.claimStakingRewards(id1);
        uint256 alicePayout = alice.balance - aliceBefore;

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        bots.claimStakingRewards(id2);
        uint256 bobPayout = bob.balance - bobBefore;

        assertGt(bobPayout, alicePayout, "90d stake earns more than 7d");
        // Bob should get ~3× alice's reward
        assertApproxEqRel(bobPayout, alicePayout * 3, 5e16, "~3x proportional reward");
    }

    // ── Difficulty integration ───────────────────────────────────────────────

    function test_Stake_DifficultyTargetEases() public {
        _mintRapid(alice, 3);
        uint256 bitsBefore = bots.targetBitsFor(alice);

        vm.prank(alice);
        bots.stake(1, 7);

        uint256 bitsAfter = bots.targetBitsFor(alice);
        assertLe(bitsAfter, bitsBefore, "staking never hurts");
        assertLt(bitsAfter, bitsBefore, "staking eases by at least one bit");
    }

    // ── Staker $BOT Burn Boost ───────────────────────────────────────────────

    function test_Burn_StakerBurnBoost() public {
        _mintRapid(alice, 3); // id1, id2, id3
        _mint(alice);         // id4 (later bot to satisfy age/prevWork)

        // Stake id1: alice now has 1 staked bot (+10% burn boost)
        vm.prank(alice);
        bots.stake(1, 7);

        assertEq(bots.burnBoostPct(alice), 10, "10% boost for 1 staked bot");

        vm.warp(block.timestamp + 600);
        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        bots.burn(2); // burn id2 while id1 is staked

        uint256 burnedBal = token.balanceOf(alice) - balBefore;
        // 1000 BOT * 110% = 1100 BOT
        assertEq(burnedBal, 1100e18, "burn reward boosted by +10%");
    }
}