// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HashBotsRenderer} from "../src/HashBotsRenderer.sol";
import {SSTORE2Read} from "../src/libraries/SSTORE2Read.sol";
import {LOOKUP_TABLE} from "../src/LookupTable.sol";

/// @dev Fixture: deploys the 8 SSTORE2 chunks + the renderer, exactly like DeployArt.
contract RendererFixture is Test {
    HashBotsRenderer public renderer;
    address[8] public chunks;

    function setUp() public {
        for (uint256 i = 0; i < 8; i++) {
            chunks[i] = _deployChunk(_chunkName(i));
        }
        renderer = new HashBotsRenderer(
            chunks[0], chunks[1], chunks[2], chunks[3],
            chunks[4], chunks[5], chunks[6], chunks[7],
            LOOKUP_TABLE
        );
    }

    function _chunkName(uint256 i) internal pure returns (string memory) {
        string[8] memory names = [
            "chunk-00.bin", "chunk-01.bin", "chunk-02.bin", "chunk-03.bin",
            "chunk-04.bin", "chunk-05.bin", "chunk-06.bin", "chunk-07.bin"
        ];
        return names[i];
    }

    /// @dev Read an int field from chunks/index.json at record `i` (3 calls per record).
    function _readU(string memory json, uint256 i, string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(json, string.concat(".[", vm.toString(i), "].", key));
    }

    function _deployChunk(string memory filename) internal returns (address deployed) {
        bytes memory data = vm.readFileBinary(
            string(abi.encodePacked("images/handoff/chunks/", filename))
        );
        return SSTORE2Read.write(data);
    }
}

/// @dev Validates the on-chain renderer: lookup table, trait selection, SVG/tokenURI output.
contract HashBotsRendererTest is RendererFixture {
    function test_smoke_RendererDeployed() public view {
        assertNotEq(address(renderer), address(0));
        for (uint256 i = 0; i < 8; i++) {
            assertNotEq(chunks[i], address(0));
        }
    }

    /// @dev Every chunk's deployed code must be exactly the chunk file, so SSTORE2 reads work.
    function test_smoke_ChunkCodeMatchesFile() public {
        for (uint256 i = 0; i < 8; i++) {
            bytes memory code = address(chunks[i]).code;
            bytes memory file = vm.readFileBinary(
                string(abi.encodePacked("images/handoff/chunks/", _chunkName(i)))
            );
            assertEq(keccak256(code), keccak256(file), string.concat("chunk ", _chunkName(i), " mismatch"));
        }
    }

/// @dev Trait selection must return ids within each layer's documented range.
    function test_lookup_TraitSelectionRanges() public view {
        uint256[6] memory traits = renderer.selectTraits(12345);
        // bg 0..17, down 18..57, skin 58..80, head 81..154, mouth 155..191, eye 192..270
        assertLt(traits[0], 18, "bg range");
        assertGe(traits[1], 18, "down range");
        assertLt(traits[1], 58, "down range");
        assertGe(traits[2], 58, "skin range");
        assertLt(traits[2], 81, "skin range");
        assertGe(traits[3], 81, "head range");
        assertLt(traits[3], 155, "head range");
        assertGe(traits[4], 155, "mouth range");
        assertLt(traits[4], 192, "mouth range");
        assertGe(traits[5], 192, "eye range");
        assertLt(traits[5], 271, "eye range");
    }

    /// @dev Same seed must always yield the same traits (determinism).
    function test_traits_Deterministic() public {
        uint256[6] memory a = renderer.selectTraits(0xDEADBEEF);
        uint256[6] memory b = renderer.selectTraits(0xDEADBEEF);
        for (uint256 i = 0; i < 6; i++) {
            assertEq(a[i], b[i], "determinism broken");
        }
    }

    /// @dev The renderer's tokenURI must be an application/json data URI.
    function test_tokenURI_IsDataUri() public view {
        string memory uri = renderer.renderTokenURI(1, 0x123456, 0, 40, false, false);
        assertTrue(_startsWith(uri, "data:application/json;base64,"), "wrong prefix");
    }

    /// @dev Full pipeline: decode the outer base64, check JSON has image/name/attributes,
    ///      then decode the SVG and verify structure. Fetch bytes from chunks directly to
    ///      inner-decode PNGs (we can't call internal functions, so decode from the SVG).
    function test_tokenURI_DecodesToValidStruct() public view {
        string memory uri = renderer.renderTokenURI(7, 0xCAFEBABE, 1, 42, true, false);
        bytes memory json = Base64Decode.decode(bytes(_stripPrefix(uri, "data:application/json;base64,")));
        string memory s = string(json);

        // JSON schema fields present
        assertTrue(_contains(s, '"name":"HashBot #7"'), "missing name");
        assertTrue(_contains(s, '"image":"data:image/svg+xml;base64,'), "missing image");
        assertTrue(_contains(s, '"trait_type":"Epoch"'), "missing epoch attr");
        assertTrue(_contains(s, '"trait_type":"Unique"'), "missing unique attr");
        assertTrue(_contains(s, '"value":"Yes"'), "unique flag not reflected");

        // Extract and decode the SVG
        uint256 imgStart = _indexOf(s, 'data:image/svg+xml;base64,');
        uint256 imgEnd = _indexOf(s, '","attributes"');
        bytes memory svg = Base64Decode.decode(bytes(substring(s, imgStart + 26, imgEnd)));
        string memory svgStr = string(svg);

        assertTrue(_startsWith(svgStr, "<svg"), "svg open");
        assertTrue(_endsWith(svgStr, "</svg>"), "svg close");
        assertTrue(_contains(svgStr, 'viewBox="0 0 165 165"'), "viewBox");
        assertTrue(_contains(svgStr, 'shape-rendering="crispEdges"'), "crispEdges");
        assertTrue(_contains(svgStr, 'image-rendering:pixelated'), "pixelated");
    }

    /// @dev Exactly six <image> layers, ordering bg..eye, each a base64 PNG.
    function test_tokenURI_SixLayers() public view {
        uint256[6] memory traits = renderer.selectTraits(0x777);
        string memory uri = renderer.renderTokenURI(99, 0x777, 1, 40, false, false);
        bytes memory json = Base64Decode.decode(bytes(_stripPrefix(uri, "data:application/json;base64,")));
        string memory s = string(json);
        uint256 imgStart = _indexOf(s, 'data:image/svg+xml;base64,');
        uint256 imgEnd = _indexOf(s, '","attributes"');
        bytes memory svg = Base64Decode.decode(bytes(substring(s, imgStart + 26, imgEnd)));
        string memory svgStr = string(svg);

        uint256 count = 0;
        uint256 from = 0;
        while (true) {
            uint256 idx = _indexOfFrom(svgStr, "data:image/png;base64,", from);
            if (idx == type(uint256).max) break;
            count++;
            from = idx + 1;
        }
        assertEq(count, 6, "expected 6 PNG layers");
        assertTrue(traits[0] < 18, "bg sorted first id");
    }

    /// @dev Byte-for-byte ground truth: each rendered PNG must equal the exact
    ///      bytes in chunks/index.json (+ the 4 PNG constants), i.e. the lookup
    ///      table offsets must point at the right chunk files.
    function test_png_MatchesGroundTruth() public view {
        string memory json = vm.readFile("images/handoff/chunks/index.json");
        uint256[6] memory traits = renderer.selectTraits(0xCAFEBABE);
        string memory uri = renderer.renderTokenURI(7, 0xCAFEBABE, 1, 42, true, false);
        string memory s = string(Base64Decode.decode(bytes(_stripPrefix(uri, "data:application/json;base64,"))));

        uint256 imgStart = _indexOf(s, 'data:image/svg+xml;base64,');
        uint256 imgEnd = _indexOf(s, '","attributes"');
        string memory svg = string(Base64Decode.decode(bytes(substring(s, imgStart + 26, imgEnd))));

        uint256 from = 0;
        for (uint256 p = 0; p < 6; p++) {
            uint256 idx = _indexOfFrom(svg, "data:image/png;base64,", from);
            _verifyLayer(json, svg, idx, renderer.selectTraits(0xCAFEBABE)[p], p);
            from = idx + 1;
        }
    }

    /// @dev One layer's ground-truth check (kept small to avoid stack-too-deep).
    function _verifyLayer(string memory json, string memory svg, uint256 idx, uint256 traitId, uint256 p)
        internal
        view
    {
        uint256 close = _indexOfFrom(svg, '"/>', idx);
        bytes memory png = Base64Decode.decode(bytes(substring(svg, idx + 22, close)));

        uint256 shapeSlot = uint256(uint8(LOOKUP_TABLE[1680 + traitId]));
        assertEq(_readU(json, shapeSlot, "id"), shapeSlot, "traitShape->record id mismatch");
        assertEq(_readU(json, 64 + traitId, "id"), traitId, "plte record id mismatch");

        bytes memory expected = _expectedPng(json, traitId, shapeSlot);
        assertEq(keccak256(png), keccak256(expected), string.concat("png layer ", _toString(p), " mismatch"));
    }

    /// @dev Assemble the reference PNG from index.json offsets + deployed chunk code.
    function _expectedPng(string memory json, uint256 traitId, uint256 shapeSlot)
        internal
        view
        returns (bytes memory expected)
    {
        uint256 pc = _readU(json, 64 + traitId, "chunk");
        uint256 po = _readU(json, 64 + traitId, "off");
        uint256 pl = _readU(json, 64 + traitId, "len");
        uint256 sc = _readU(json, shapeSlot, "chunk");
        uint256 so = _readU(json, shapeSlot, "off");
        uint256 sl = _readU(json, shapeSlot, "len");
        expected = _assembleExpectedPng(chunks[pc].code, po, pl, chunks[sc].code, so, sl);
    }

    /// @dev Build the reference PNG: sig + IHDR + plte slice + tRNS + idat slice + IEND.
    function _assembleExpectedPng(
        bytes memory plteCode, uint256 plteOff, uint256 plteLen,
        bytes memory idatCode, uint256 idatOff, uint256 idatLen
    ) internal pure returns (bytes memory) {
        bytes memory sig = hex"89504e470d0a1a0a";
        bytes memory ihdr = hex"0000000d49484452000000a5000000a508030000000af5cde8";
        bytes memory trns = hex"0000000174524e530040e6d866";
        bytes memory iend = hex"0000000049454e44ae426082";

        bytes memory out = new bytes(sig.length + ihdr.length + plteLen + trns.length + idatLen + iend.length);
        uint256 p = 0;
        for (uint256 i = 0; i < sig.length; i++) out[p++] = sig[i];
        for (uint256 i = 0; i < ihdr.length; i++) out[p++] = ihdr[i];
        for (uint256 i = plteOff; i < plteOff + plteLen; i++) out[p++] = plteCode[i];
        for (uint256 i = 0; i < trns.length; i++) out[p++] = trns[i];
        for (uint256 i = idatOff; i < idatOff + idatLen; i++) out[p++] = idatCode[i];
        for (uint256 i = 0; i < iend.length; i++) out[p++] = iend[i];
        return out;
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        for (uint256 i = digits; i > 0;) {
            i--;
            buffer[i] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _stripPrefix(string memory s, string memory prefix)
        private
        pure
        returns (string memory)
    {
        bytes memory b = bytes(s);
        bytes memory p = bytes(prefix);
        require(b.length >= p.length, "len");
        bytes memory out = new bytes(b.length - p.length);
        for (uint256 i = 0; i < out.length; i++) out[i] = b[i + p.length];
        return string(out);
    }

    function _startsWith(string memory s, string memory prefix) private pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory p = bytes(prefix);
        if (b.length < p.length) return false;
        for (uint256 i = 0; i < p.length; i++) if (b[i] != p[i]) return false;
        return true;
    }

    function _endsWith(string memory s, string memory suffix) private pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory p = bytes(suffix);
        if (b.length < p.length) return false;
        uint256 off = b.length - p.length;
        for (uint256 i = 0; i < p.length; i++) if (b[off + i] != p[i]) return false;
        return true;
    }

    function _contains(string memory s, string memory needle) private pure returns (bool) {
        return _indexOf(s, needle) != type(uint256).max;
    }

    function _indexOf(string memory s, string memory needle) private pure returns (uint256) {
        return _indexOfFrom(s, needle, 0);
    }

    function _indexOfFrom(string memory s, string memory needle, uint256 from)
        private
        pure
        returns (uint256)
    {
        bytes memory b = bytes(s);
        bytes memory n = bytes(needle);
        if (n.length == 0 || b.length < n.length) return type(uint256).max;
        for (uint256 i = from; i + n.length <= b.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (b[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return i;
        }
        return type(uint256).max;
    }

    function substring(string memory s, uint256 start, uint256 end)
        private
        pure
        returns (string memory)
    {
        bytes memory b = bytes(s);
        require(start <= end && end <= b.length, "slice");
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = b[i];
        return string(out);
    }
}

/// @dev Minimal base64 decoder for test assertions (RFC-4648, no padding validation).
library Base64Decode {
    function decode(bytes memory input) internal pure returns (bytes memory data) {
        uint256 len = input.length;
        require(len % 4 == 0 || len % 4 == 2 || len % 4 == 3, "b64len");
        uint256 pad = 0;
        if (len > 0 && input[len - 1] == "=") pad++;
        if (len > 1 && input[len - 2] == "=") pad++;
        uint256 outLen = (len * 3) / 4 - pad;
        data = new bytes(outLen);

        uint256 o = 0;
        for (uint256 i = 0; i < len; i += 4) {
            uint256 a = _val(input[i]);
            uint256 b = _val(input[i + 1]);
            uint256 c = input[i + 2] == "=" ? 0 : _val(input[i + 2]);
            uint256 d = input[i + 3] == "=" ? 0 : _val(input[i + 3]);
            uint256 triple = (a << 18) | (b << 12) | (c << 6) | d;
            if (o < outLen) data[o++] = bytes1(uint8((triple >> 16) & 0xff));
            if (o < outLen) data[o++] = bytes1(uint8((triple >> 8) & 0xff));
            if (o < outLen) data[o++] = bytes1(uint8(triple & 0xff));
        }
    }

    function _val(bytes1 c) internal pure returns (uint256) {
        uint8 b = uint8(c);
        if (b >= 65 && b <= 90) return b - 65;       // A-Z
        if (b >= 97 && b <= 122) return b - 71;      // a-z
        if (b >= 48 && b <= 57) return b + 4;        // 0-9
        if (b == 43) return 62;                      // +
        if (b == 47) return 63;                      // /
        revert("bad char");
    }
}