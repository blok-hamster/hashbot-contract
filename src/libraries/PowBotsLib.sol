// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RarityTable} from "./RarityTable.sol";

/// @title PowBotsLib — Math & Trait helpers for PowBots to optimize contract bytecode size.
library PowBotsLib {
    function bitsToTarget(uint256 bits) public pure returns (uint256) {
        if (bits == 0) return type(uint256).max;
        if (bits >= 256) return 0;
        return (uint256(1) << (256 - bits)) - 1;
    }

    function targetToBits(uint256 target) public pure returns (uint256) {
        if (target == 0) return 256;
        return 256 - bitLength(target);
    }

    function bitLength(uint256 x) public pure returns (uint256) {
        uint256 msb;
        for (uint256 t = x; t > 1; t >>= 1) msb++;
        return msb + 1;
    }

    function burstDecay(uint256 stored, uint256 lastAt, uint256 cool) public view returns (uint256) {
        if (stored == 0) return 0;
        uint256 elapsed = block.timestamp - lastAt;
        uint256 cooled = elapsed / cool;
        return cooled >= stored ? 0 : stored - cooled;
    }

    function inheritTraits(uint256[3] memory inputs, uint256[6][3] memory inputTraits)
        public
        pure
        returns (uint256[6] memory out)
    {
        for (uint256 slot = 0; slot < 6; slot++) {
            uint256 bestVal;
            uint256 bestShare = type(uint256).max;
            uint256 bestRank = type(uint256).max;
            for (uint256 i = 0; i < 3; i++) {
                uint256 k = (i + slot) % 3;
                uint256 val = inputTraits[k][slot];
                uint256 share = RarityTable.shareOf(val);
                if (share < bestShare || (share == bestShare && i < bestRank)) {
                    bestShare = share;
                    bestVal = val;
                    bestRank = i;
                }
            }
            out[slot] = bestVal;
        }
    }

    struct ForgeInputs {
        uint256 a; uint256 b; uint256 c;
        address ownerA; address ownerB; address ownerC;
        address sender;
        uint256 weightA; uint256 weightB; uint256 weightC;
        bool stakedA; bool stakedB; bool stakedC;
        uint256 mintTimeA; uint256 mintTimeB; uint256 mintTimeC;
        bool lockedA; bool lockedB; bool lockedC;
        uint256 lastForgeAt; uint256 aliveCount; uint256 supplyFloor;
        uint256 msgValue; uint256 fee;
    }

    function validateForge(ForgeInputs memory p) public view {
        require(p.a != p.b && p.a != p.c && p.b != p.c, "Duplicate inputs");
        require(p.ownerA == p.sender && p.ownerB == p.sender && p.ownerC == p.sender, "Not owner");
        require(p.weightA == p.weightB && p.weightA == p.weightC, "Weight mismatch");
        require(p.weightA <= 9, "Max tier");
        require(!p.stakedA && !p.stakedB && !p.stakedC, "Staked");
        uint256 now_ = block.timestamp;
        require(now_ >= p.mintTimeA + 600 && now_ >= p.mintTimeB + 600 && now_ >= p.mintTimeC + 600, "Age a");
        require((!p.lockedA || now_ >= p.mintTimeA + 86400) && (!p.lockedB || now_ >= p.mintTimeB + 86400) && (!p.lockedC || now_ >= p.mintTimeC + 86400), "Locked 24h");
        require(now_ >= p.lastForgeAt + 60, "Cooldown");
        require(p.aliveCount - 2 >= p.supplyFloor, "Floor");
        require(p.msgValue >= p.fee, "Fee");
    }

    function validateStake(
        address tokenOwner, address sender,
        bool isBurned, bool isStaked, bool isForgeLocked, uint256 mintTime,
        uint256 stakedCount, uint256 maxBits, uint256 lockDays
    ) public view {
        require(tokenOwner == sender, "Not owner");
        require(!isBurned, "Burned");
        require(!isStaked, "Already staked");
        require(!isForgeLocked || block.timestamp >= mintTime + 86400, "Locked 24h");
        require(lockDays == 7 || lockDays == 30 || lockDays == 90, "Bad term");
    }

    function validateUnstake(
        bool isStaked, address tokenOwner, address sender,
        uint256 unlockTime
    ) public view {
        require(isStaked, "Not staked");
        require(tokenOwner == sender, "Not owner");
        require(block.timestamp >= unlockTime, "Locked");
    }

    /// @dev Compute staking share weight from cat weight, lock term, and tier.
    ///      Term multiplier: 7d=100, 30d=150, 90d=300 (basis points / 100).
    ///      Status multiplier: weight 1=100, 3=120, 9=150, 27=200.
    ///      Share = catWeight * termMult * statusMult (unscaled; caller divides by 10000).
    function computeShareWeight(uint256 catWeight, uint256 lockDays) public pure returns (uint256) {
        uint256 termMult;
        if (lockDays == 90) termMult = 300;
        else if (lockDays == 30) termMult = 150;
        else termMult = 100; // 7d

        uint256 statusMult;
        if (catWeight >= 27) statusMult = 200;
        else if (catWeight >= 9) statusMult = 150;
        else if (catWeight >= 3) statusMult = 120;
        else statusMult = 100;

        return (catWeight * termMult * statusMult) / 10000;
    }

    /// @dev Validate and compute a staking reward claim.
    ///      If claiming before unlock, 50% penalty is applied.
    ///      Returns (payout, penaltyToStakers, penaltyToBuyback).
    function computeStakeRewardClaim(
        address tokenOwner, address sender,
        bool isStaked, uint256 unlockTime,
        uint256 pendingReward
    ) public view returns (uint256 payout, uint256 penaltyToStakers, uint256 penaltyToBuyback) {
        require(isStaked, "Not staked");
        require(tokenOwner == sender, "Not owner");
        require(pendingReward > 0, "No reward");

        if (block.timestamp >= unlockTime) {
            // Full payout after lock expires
            return (pendingReward, 0, 0);
        }
        // Early claim: 50% penalty, split evenly between stakers and buyback
        payout = pendingReward / 2;
        uint256 penalty = pendingReward - payout;
        penaltyToStakers = penalty / 2;
        penaltyToBuyback = penalty - penaltyToStakers;
    }

    function computeRetarget(
        uint256 baseTarget, uint256 elapsed, uint256 floorTarget, uint256 totalMinted, uint256 wallFrom, uint256 wallDiv
    ) public pure returns (uint256 newBase) {
        newBase = baseTarget;
        uint256 expected = 80;
        if (elapsed < expected / 2) {
            newBase = baseTarget / 2;
        } else if (elapsed > expected * 4) {
            newBase = baseTarget > type(uint256).max / 4 ? type(uint256).max : baseTarget * 4;
        }
        if (newBase > floorTarget) newBase = floorTarget;
        if (totalMinted >= wallFrom) {
            uint256 over = totalMinted - wallFrom;
            newBase = newBase / (1 + over / wallDiv);
        }
    }

    function validateMintParams(
        uint256 msgValue, uint256 price, uint256 anchorNum, uint256 blockNumber,
        bytes32 anchor, bytes32 blockHashAnchor, uint256 prevWork, uint256 lastWork,
        bool isGated, bool isInvited
    ) public pure {
        require(!isGated || isInvited, "Invite required");
        require(msgValue >= price, "Price");
        require(anchorNum < blockNumber, "Anchor future");
        require(blockNumber - anchorNum <= 250, "Anchor expired");
        require(blockHashAnchor == anchor && anchor != bytes32(0), "Bad anchor");
        require(prevWork == lastWork, "Bad prev");
    }

    function validateBurn(
        address owner, address sender, bool isBurned, bool isStaked,
        uint256 tokenId, uint256 totalMinted, uint256 mintTime
    ) public view {
        require(owner == sender, "Not owner");
        require(!isBurned, "Burned");
        require(!isStaked, "Staked");
        require(tokenId >= 100001 || totalMinted > tokenId, "Last bot");
        require(block.timestamp >= mintTime + 600, "Delay");
    }

    function validateRentClaim(
        address owner, address sender, uint256 scaled, uint256 precision, uint256 claimTaxBps
    ) public pure returns (uint256 amount, uint256 tax) {
        require(owner == sender, "Not owner");
        require(scaled >= precision, "Nothing to claim");
        amount = scaled / precision;
        tax = (amount * claimTaxBps) / 10000;
    }

    function validateInviteRedeem(string memory code) public pure returns (bytes32 codeHash) {
        require(bytes(code).length > 0, "Empty code");
        return keccak256(bytes(code));
    }

    function validateTransfer(bool isForgeLocked, uint256 mintTime, bool isStaked) public view {
        require(!isForgeLocked || block.timestamp >= mintTime + 86400, "Locked 24h");
        require(!isStaked, "Staked");
    }
}
