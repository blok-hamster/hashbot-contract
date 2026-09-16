// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SSTORE2Read} from "./libraries/SSTORE2Read.sol";
import {Base64} from "./libraries/Base64.sol";
import {LOOKUP_TABLE} from "./LookupTable.sol";

/// @notice On-chain SVG renderer for HashBots — reads shape + palette data from
///         SSTORE2 chunks, assembles PNGs, stacks them into an SVG, and wraps
///         the result in a base64 data-URI tokenURI.
/// @dev    See contracts/images/README.md for the full byte-level specification.
contract HashBotsRenderer {
    // ── PNG constants (4 chunks that never change) ────────────────────────────
    bytes constant PNG_SIG =
        hex"89504e470d0a1a0a"; // 8 bytes
    bytes constant PNG_IHDR =
        hex"0000000d49484452000000a5000000a508030000000af5cde8"; // 25 bytes
    bytes constant PNG_TRNS =
        hex"0000000174524e530040e6d866"; // 13 bytes
    bytes constant PNG_IEND =
        hex"0000000049454e44ae426082"; // 12 bytes

    // ── Layer constants ───────────────────────────────────────────────────────
    uint256 constant NUM_LAYERS = 6;
    uint256 constant NUM_SHAPES = 64;

    // Layer ID ranges (global trait IDs, contiguous per layer):
    //   bg=0..17  down=18..57  skin=58..80  head=81..154  mouth=155..191  eye=192..270
    uint256 constant BG_FIRST = 0;
    uint256 constant BG_COUNT = 18;
    uint256 constant DOWN_FIRST = 18;
    uint256 constant DOWN_COUNT = 40;
    uint256 constant SKIN_FIRST = 58;
    uint256 constant SKIN_COUNT = 23;
    uint256 constant HEAD_FIRST = 81;
    uint256 constant HEAD_COUNT = 74;
    uint256 constant MOUTH_FIRST = 155;
    uint256 constant MOUTH_COUNT = 37;
    uint256 constant EYE_FIRST = 192;
    uint256 constant EYE_COUNT = 79;

    // ── State ─────────────────────────────────────────────────────────────────
    address[8] public chunks;

    // ── Lookup Table Accessors (Read directly from LOOKUP_TABLE bytecode) ───────
    function recOff(uint256 i) internal pure returns (uint256) {
        uint256 off = i * 5;
        return uint256(uint8(LOOKUP_TABLE[off])) << 24
            | uint256(uint8(LOOKUP_TABLE[off + 1])) << 8
            | uint256(uint8(LOOKUP_TABLE[off + 2]));
    }

    function recLen(uint256 i) internal pure returns (uint256) {
        uint256 off = i * 5;
        return uint256(uint8(LOOKUP_TABLE[off + 3])) << 8 | uint256(uint8(LOOKUP_TABLE[off + 4]));
    }

    function traitShape(uint256 i) internal pure returns (uint256) {
        return uint256(uint8(LOOKUP_TABLE[1680 + i]));
    }

    function chunkStart(uint256 i) internal pure returns (uint256) {
        uint256 off = 1951 + i * 3;
        return uint256(uint8(LOOKUP_TABLE[off])) << 16
            | uint256(uint8(LOOKUP_TABLE[off + 1])) << 8
            | uint256(uint8(LOOKUP_TABLE[off + 2]));
    }

    // ── Constructor ───────────────────────────────────────────────────────────
    /// @param c0..c7 The 8 SSTORE2 chunk addresses, in order.
    constructor(
        address c0,
        address c1,
        address c2,
        address c3,
        address c4,
        address c5,
        address c6,
        address c7,
        bytes memory /* lookupTable */
    ) {
        chunks[0] = c0;
        chunks[1] = c1;
        chunks[2] = c2;
        chunks[3] = c3;
        chunks[4] = c4;
        chunks[5] = c5;
        chunks[6] = c6;
        chunks[7] = c7;
    }

    // ── Low-level read ────────────────────────────────────────────────────────

    /// @dev Read `length` bytes from record `recIndex` (336 records total).
    function _readRecord(uint256 recIndex, uint256 length) internal view returns (bytes memory) {
        uint256 packed = recOff(recIndex);
        uint256 chunkIdx = packed >> 24;
        uint256 localOff = packed & 0xFFFFFF;
        return SSTORE2Read.read(chunks[chunkIdx], localOff, length);
    }

    // ── Trait selection from seed ─────────────────────────────────────────────

    /// @dev Derive the 6 chosen trait IDs from the mint seed (deterministic).
    function deriveTraits(uint256 seed)
        public
        pure
        returns (uint256[6] memory t)
    {
        t[0] = seed % BG_COUNT;
        t[1] = (seed >> 8) % DOWN_COUNT + DOWN_FIRST;
        t[2] = (seed >> 16) % SKIN_COUNT + SKIN_FIRST;
        t[3] = (seed >> 24) % HEAD_COUNT + HEAD_FIRST;
        t[4] = (seed >> 32) % MOUTH_COUNT + MOUTH_FIRST;
        t[5] = (seed >> 40) % EYE_COUNT + EYE_FIRST;
    }

    /// @notice Select compatible traits for a given seed, applying legibility rules.
    /// @dev    Returns 6 global trait IDs. bg yields to both down and skin;
    ///         each upper layer yields to the one beneath it.
    function selectTraits(uint256 seed)
        public
        view
        returns (uint256[6] memory t)
    {
        t = deriveTraits(seed);

        // 1. Background yields to both down and skin.
        for (uint256 i = 0; i < BG_COUNT; i++) {
            if (_okDownBg(t[1] - DOWN_FIRST, t[0]) && _okSkinBg(t[2] - SKIN_FIRST, t[0])) break;
            t[0] = (t[0] + 1) % BG_COUNT;
        }

        // 2. Each upper layer yields to the one beneath it, using nextColourwayOfSameDrawing.
        t[2] = _resolveUpper(t[2], t[0], 1); // skin over bg
        t[3] = _resolveUpper(t[3], t[2], 2); // head over skin
        t[4] = _resolveUpper(t[4], t[2], 3); // mouth over skin
        t[5] = _resolveUpper(t[5], t[2], 4); // eye over skin

        return t;
    }

    /// @dev Resolve a single upper layer against the layer beneath it.
    function _resolveUpper(uint256 traitId, uint256 beneathId, uint256 pairIdx)
        internal
        view
        returns (uint256)
    {
        uint256 id = traitId;
        for (uint256 i = 0; i < 200; i++) {
            if (_checkCompat(id, beneathId, pairIdx)) return id;
            id = _nextColourway(id);
        }
        return id; // guaranteed to terminate (see README)
    }

    // ── Legibility (compat) ───────────────────────────────────────────────────

    /// @dev Check a bit in the compat table. `pairIdx`: 0=down-bg, 1=skin-bg, 2=head-skin, 3=mouth-skin, 4=eye-skin.
    ///      `a` and `b` are per-layer indices (not global trait IDs).
    function _checkCompat(uint256 topTrait, uint256 bottomTrait, uint256 pairIdx)
        internal
        view
        returns (bool)
    {
        uint256 a;
        uint256 b;
        uint256 countsBottom;

        if (pairIdx == 0) {
            // down over bg
            a = topTrait - DOWN_FIRST;
            b = bottomTrait;
            countsBottom = BG_COUNT;
        } else if (pairIdx == 1) {
            // skin over bg
            a = topTrait - SKIN_FIRST;
            b = bottomTrait;
            countsBottom = BG_COUNT;
        } else if (pairIdx == 2) {
            // head over skin
            a = topTrait - HEAD_FIRST;
            b = bottomTrait - SKIN_FIRST;
            countsBottom = SKIN_COUNT;
        } else if (pairIdx == 3) {
            // mouth over skin
            a = topTrait - MOUTH_FIRST;
            b = bottomTrait - SKIN_FIRST;
            countsBottom = SKIN_COUNT;
        } else {
            // eye over skin
            a = topTrait - EYE_FIRST;
            b = bottomTrait - SKIN_FIRST;
            countsBottom = SKIN_COUNT;
        }

        uint256 k = a * countsBottom + b;
        uint256 byteOff = k >> 3;
        uint256 bitOff = k & 7;

        // Compat data is the last record (index 335).
        bytes memory table = _readRecord(335, recLen(335));
        return (uint8(table[byteOff]) >> bitOff) & 1 == 1;
    }

    // ── Colourway cycling ─────────────────────────────────────────────────────

    /// @dev Advance to the next sibling trait (same shape, wrapping).
    function _nextColourway(uint256 traitId) internal pure returns (uint256) {
        uint256 shapeId = traitShape(traitId);

        // Find the first sibling (scan backwards).
        uint256 first = traitId;
        for (uint256 j = traitId; j > 0; j--) {
            if (traitShape(j - 1) != shapeId) break;
            first = j - 1;
        }

        // Find the last sibling (scan forwards).
        uint256 last = traitId;
        for (uint256 j = traitId + 1; j < 271; j++) {
            if (traitShape(j) != shapeId) break;
            last = j;
        }

        return first + ((traitId - first + 1) % (last - first + 1));
    }

    // ── Specific compat checks (bottomLayerLocal, bgLocal) ───────────────────

    function _okDownBg(uint256 downLocal, uint256 bgLocal) internal view returns (bool) {
        return _checkCompat(downLocal + DOWN_FIRST, bgLocal, 0);
    }

    function _okSkinBg(uint256 skinLocal, uint256 bgLocal) internal view returns (bool) {
        return _checkCompat(skinLocal + SKIN_FIRST, bgLocal, 1);
    }

    // ── PNG assembly ──────────────────────────────────────────────────────────

    /// @dev Build a complete PNG for trait `traitId` by concatenating the 6 byte strings.
    ///      PLTE and IDAT are read from SSTORE2 chunks; the other 4 are constants.
    function _assemblePng(uint256 traitId) internal view returns (bytes memory) {
        // Palette: trait i → record index 64 + i
        uint256 plteRecIdx = 64 + traitId;
        uint256 plteLen = recLen(plteRecIdx);
        bytes memory plte = _readRecord(plteRecIdx, plteLen);

        // Shape (IDAT): trait i → shape index from traitShape(i) → record index = shapeIndex
        uint256 shapeId = traitShape(traitId);
        uint256 shapeRecIdx = shapeId;
        uint256 shapeLen = recLen(shapeRecIdx);
        bytes memory idat = _readRecord(shapeRecIdx, shapeLen);

        // Concatenate: sig + ihdr + PLTE + trns + IDAT + iend
        bytes memory png = new bytes(PNG_SIG.length + PNG_IHDR.length + plteLen + PNG_TRNS.length + shapeLen + PNG_IEND.length);
        uint256 p = 0;

        for (uint256 i = 0; i < PNG_SIG.length; i++) { png[p++] = PNG_SIG[i]; }
        for (uint256 i = 0; i < PNG_IHDR.length; i++) { png[p++] = PNG_IHDR[i]; }
        for (uint256 i = 0; i < plteLen; i++) { png[p++] = plte[i]; }
        for (uint256 i = 0; i < PNG_TRNS.length; i++) { png[p++] = PNG_TRNS[i]; }
        for (uint256 i = 0; i < shapeLen; i++) { png[p++] = idat[i]; }
        for (uint256 i = 0; i < PNG_IEND.length; i++) { png[p++] = PNG_IEND[i]; }

        return png;
    }

    // ── SVG assembly ──────────────────────────────────────────────────────────

    string internal constant SVG_OPEN =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 165 165" shape-rendering="crispEdges">';
    string internal constant IMG_OPEN =
        '<image width="165" height="165" style="image-rendering:pixelated" href="data:image/png;base64,';
    string internal constant IMG_CLOSE = '"/>';
    string internal constant SVG_CLOSE = "</svg>";

    /// @dev Build the SVG string from 6 layer trait IDs.
    ///      Each PNG is base64-encoded and stacked as an <image> layer.
    function _assembleSvg(uint256[6] memory traits) internal view returns (string memory) {
        // Build layer by layer to keep stack shallow.
        bytes memory layer = bytes(SVG_OPEN);
        for (uint256 i = 0; i < NUM_LAYERS; i++) {
            bytes memory png = _assemblePng(traits[i]);
            layer = abi.encodePacked(layer, IMG_OPEN, Base64.encode(png), IMG_CLOSE);
            delete png;
        }
        layer = abi.encodePacked(layer, SVG_CLOSE);

        return string(layer);
    }

    // ── tokenURI ──────────────────────────────────────────────────────────────

    /// @notice Build the full on-chain tokenURI for a HashBot.
    function renderTokenURI(
        uint256 tokenId,
        uint256 seed,
        uint256 epoch,
        uint256 depth,
        bool unique,
        bool burned
    ) public view returns (string memory) {
        uint256[6] memory traits = selectTraits(seed);

        // Stack-shallow render: build metadata then wrap.
        string memory imageUri = _renderImage(traits);
        bytes memory json = _metadata(tokenId, epoch, depth, unique, burned, seed, imageUri);
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    /// @notice Build the tokenURI for a forge output — no seed, traits are inherited
    ///         and stored on-chain. The art is rendered from the explicit trait ids.
    function renderForgedTokenURI(
        uint256 tokenId,
        uint256[6] memory traits,
        uint256 weight,
        uint256 epoch,
        bool burned
    ) public view returns (string memory) {
        string memory imageUri = _renderImage(traits);
        string memory tier = _tierName(weight);
        string memory forgedStr = burned ? "Burned" : "Yes";
        bytes memory json = abi.encodePacked(
            '{"name":"HashBot #',
            _toString(tokenId),
            '","description":"Rarity-forged HashBot. Traits inherited from its three parents, no randomness.",',
            '"image":"',
            imageUri,
            '","attributes":[{"trait_type":"Tier","value":"',
            tier,
            '"},{"trait_type":"Weight","value":"',
            _toString(weight),
            '"},{"trait_type":"Epoch","value":"',
            _toString(epoch),
            '"},{"trait_type":"Forged","value":"',
            forgedStr,
            '"}]}'
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    /// @dev Tier display name derived from the forge weight (1/3/9/27).
    function _tierName(uint256 weight) internal pure returns (string memory) {
        if (weight == 27) return "Legendary";
        if (weight == 9) return "Epic";
        if (weight == 3) return "Rare";
        return "Common";
    }

    /// @dev Assemble the base64 SVG data URI only.
    function _renderImage(uint256[6] memory traits) internal view returns (string memory) {
        string memory svg = _assembleSvg(traits);
        return string(abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(svg))));
    }

    /// @dev Build the metadata JSON with the image field injected.
    function _metadata(
        uint256 tokenId,
        uint256 epoch,
        uint256 depth,
        bool unique,
        bool burned,
        uint256 seed,
        string memory imageUri
    ) internal pure returns (bytes memory) {
        string memory uniqueStr = burned ? "Burned" : (unique ? "Yes" : "No");
        string memory nameStr = string(abi.encodePacked("HashBot #", _toString(tokenId)));

        return abi.encodePacked(
            '{"name":"',
            nameStr,
            '","description":"Mineable PoW HashBot. Seed-born art, fully determined on-chain.",',
            '"image":"',
            imageUri,
            '","attributes":[{"trait_type":"Epoch","value":"',
            _toString(epoch),
            '"},{"trait_type":"Depth Bits","value":"',
            _toString(depth),
            '"},{"trait_type":"Unique","value":"',
            uniqueStr,
            '"},{"trait_type":"Seed","value":"',
            _toHex(seed),
            '"}]}'
        );
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _toHex(uint256 value) internal pure returns (string memory) {
        bytes16 h = bytes16("0123456789abcdef");
        bytes memory buffer = new bytes(66);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 0; i < 64; i++) {
            buffer[65 - i] = h[uint8(value & 0xf)];
            value >>= 4;
        }
        return string(buffer);
    }
}
