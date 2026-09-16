// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal RFC-4648 base64 (used for on-chain data-URI metadata).
library Base64 {
    string internal constant TABLE =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    // forge-lint: disable-start(unsafe-typecast, divide-before-multiply)
    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        bytes memory table = bytes(TABLE);
        uint256 len = data.length;
        uint256 encodedLen = 4 * ((len + 2) / 3);
        bytes memory out = new bytes(encodedLen);

        uint256 i;
        for (i = 0; i + 2 < len; i += 3) {
            uint256 b = (uint256(uint8(data[i])) << 16) | (uint256(uint8(data[i + 1])) << 8) | uint256(uint8(data[i + 2]));
            out[(i / 3) * 4] = bytes1(table[(b >> 18) & 0x3F]);
            out[(i / 3) * 4 + 1] = bytes1(table[(b >> 12) & 0x3F]);
            out[(i / 3) * 4 + 2] = bytes1(table[(b >> 6) & 0x3F]);
            out[(i / 3) * 4 + 3] = bytes1(table[b & 0x3F]);
        }

        uint256 rem = len - i;
        if (rem == 1) {
            uint256 b = uint8(data[i]);
            out[(i / 3) * 4] = bytes1(table[(b >> 2) & 0x3F]);
            out[(i / 3) * 4 + 1] = bytes1(table[(b & 0x03) << 4]);
            out[(i / 3) * 4 + 2] = bytes1("=");
            out[(i / 3) * 4 + 3] = bytes1("=");
        } else if (rem == 2) {
            uint256 b = (uint256(uint8(data[i])) << 8) | uint256(uint8(data[i + 1]));
            out[(i / 3) * 4] = bytes1(table[(b >> 10) & 0x3F]);
            out[(i / 3) * 4 + 1] = bytes1(table[(b >> 4) & 0x3F]);
            out[(i / 3) * 4 + 2] = bytes1(table[(b & 0x0F) << 2]);
            out[(i / 3) * 4 + 3] = bytes1("=");
        }

        return string(out);
    }
    // forge-lint: disable-end(unsafe-typecast, divide-before-multiply)
}