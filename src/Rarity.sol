// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RarityTable} from "./libraries/RarityTable.sol";

/// @title Rarity — on-chain rarity oracle for HashBots
/// @notice Stores the exact per-trait effective frequencies computed by
///  enumerating the renderer's derivation space. Anyone can call oneInOfSeed
///  or oneInOfToken to verify the rarity value displayed by the UI.
///  The shares table is immutable (frozen at deploy); the renderer's own
///  selectTraits() is the source of truth for which traits a bot has.
contract Rarity {
    uint256 public constant SCALE = 1000000000;
    address public immutable renderer;
    address public immutable powbots;

    /// @param _renderer HashBotsRenderer address (for selectTraits).
    /// @param _powbots  PowBots address (for catSeed).
    constructor(address _renderer, address _powbots) {
        renderer = _renderer;
        powbots = _powbots;
    }

    /// @notice Raw share value for a trait (×1000000000).
    function shareOf(uint256 traitId) external pure returns (uint256) {
        return RarityTable.shareOf(traitId);
    }

    struct BotRarity {
        uint256 oneIn;          // 1 / Π(share_i), integer
        uint256 rarestShare;    // min share × SCALE
        uint256 rarestTraitId;  // which trait is rarest
        uint8   badge;          // 0=Mythic 1=Legendary 2=Epic 3=Rare 4=Uncommon 5=Common
    }

    /// @notice Full rarity info for a seed. The combined "1 in N" uses the
    ///  product of the six per-trait shares — the standard NFT rarity metric.
    ///  oneIn = SCALE^6 / Π(share_i). Max prod = (5.8e7)^6 ≈ 3.8e46, SCALE^6 =
    ///  1e54, both well below 2^256. badge is tier 0–5 derived from oneIn.
    function oneInOfSeed(uint256 seed) external view returns (BotRarity memory) {
        return _rarityOf(seed);
    }

    /// @notice Same as oneInOfSeed but reads the seed from PowBots.catSeed(tokenId).
    function oneInOfToken(uint256 tokenId) external view returns (BotRarity memory) {
        return _rarityOf(_catSeed(tokenId));
    }

    /// @notice Full rarity of an explicit trait set (e.g. a forged output's
    ///  inherited traits). oneIn is the same 1 / Π(share_i) as oneInOfSeed.
    function rarityOfTraits(uint256[6] memory t) external view returns (BotRarity memory) {
        return _rarityOfTraits(t);
    }

    // ── Internal ────────────────────────────────────────────────────────────

    function _rarityOf(uint256 seed) internal view returns (BotRarity memory r) {
        return _rarityOfTraits(_selectTraits(seed));
    }

    function _rarityOfTraits(uint256[6] memory t) internal view returns (BotRarity memory r) {
        uint256 prod = 1;
        for (uint256 i = 0; i < 6; i++) prod *= RarityTable.shareOf(t[i]);
        r.oneIn = SCALE ** 6 / prod;
        r.rarestShare = SCALE;
        for (uint256 i = 0; i < 6; i++) {
            uint256 s = RarityTable.shareOf(t[i]);
            if (s < r.rarestShare) {
                r.rarestShare = s;
                r.rarestTraitId = t[i];
            }
        }
        r.badge = _tier(r.oneIn);
    }

    /// @dev Badge tier 0–5 derived from oneIn, matching the UI's badge bands.
    ///  0=Mythic(≥8B) 1=Legendary(6B) 2=Epic(4.5B) 3=Rare(3.8B) 4=Uncommon(3.4B) 5=Common
    function _tier(uint256 oneIn) internal pure returns (uint8) {
        if (oneIn >= 8_000_000_000) return 0;
        if (oneIn >= 6_000_000_000) return 1;
        if (oneIn >= 4_500_000_000) return 2;
        if (oneIn >= 3_800_000_000) return 3;
        if (oneIn >= 3_400_000_000) return 4;
        return 5;
    }

    function _catSeed(uint256 tokenId) internal view returns (uint256) {
        (bool ok, bytes memory data) = powbots.staticcall(
            abi.encodeWithSignature("catSeed(uint256)", tokenId)
        );
        require(ok, "catSeed failed");
        return abi.decode(data, (uint256));
    }

    function _selectTraits(uint256 seed) internal view returns (uint256[6] memory t) {
        (bool ok, bytes memory data) = renderer.staticcall(
            abi.encodeWithSignature("selectTraits(uint256)", seed)
        );
        require(ok, "selectTraits failed");
        return abi.decode(data, (uint256[6]));
    }
}
