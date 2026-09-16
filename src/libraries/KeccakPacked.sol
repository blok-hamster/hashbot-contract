// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Mirror of the mining preimage. `abi.encodePacked(address, uint64, uint256, bytes32)`
///      packs to exactly 20 + 8 + 32 + 32 = 92 bytes. The Go/CUDA miners MUST reproduce this
///      byte-for-byte (big-endian nonce, big-endian 32-byte prevWork).
library KeccakPacked {
    function workHash(address miner, uint64 nonce, uint256 prevWork, bytes32 anchor)
        internal
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(miner, nonce, prevWork, anchor)));
    }

    function seedHash(uint256 solution, uint256 bucket) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(solution, bucket)));
    }
}