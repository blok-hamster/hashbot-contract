// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Epoch / pricing math. Epoch N holds cats (8<<(N-1))+1 .. 8<<N; epoch 0 holds cats 1..8.
library EpochMath {
    uint256 internal constant PRICE_EPOCH0 = 69_000_000_000_000; // 0.000069 ETH (epoch 0 floor)
    uint256 internal constant SHARE_PRICE = 20_000_000_000_000; // 0.00002 ETH per existing cat
    uint256 internal constant FIRST_EPOCH_SIZE = 8;

    /// @dev Stage containing ordinal `x` (1-indexed token id). Closed form of the
    ///      exponential boundary walk; no loops beyond ~160 iterations of bit scan.
    function stageOf(uint256 x) internal pure returns (uint256) {
        if (x <= FIRST_EPOCH_SIZE) return 0;
        uint256 msb;
        for (uint256 t = x; t > 1; t >>= 1) msb++;
        bool isPow2 = (x & (x - 1)) == 0;
        return (isPow2 ? msb : msb + 1) - 3;
    }

    /// @dev Epoch the NEXT cat (totalMinted+1) would be minted into.
    function epochForNextMint(uint256 totalMinted) internal pure returns (uint256) {
        return stageOf(totalMinted + 1);
    }

    /// @dev Epoch a token was minted in.
    function epochOfToken(uint256 tokenId) internal pure returns (uint256) {
        return stageOf(tokenId);
    }

    /// @notice Entry price for a mint in `epoch`. Epoch 0 is a fixed genesis floor. For later
    ///         epochs, price = (8 << (epoch - 1)) x 0.00002 ETH — i.e. the number of bots
    ///         already in existence when the epoch opens, each at 0.00002 ETH. The known live
    ///         datapoint (~0.08176 ETH) sits at epoch 10 under this schedule
    ///         ((8 << 9) x 0.00002 = 0.08192). Intentionally 2x cheaper per epoch than the
    ///         (8 << epoch) reading, to match the web client's epoch math.
    function mintPrice(uint256 epoch) internal pure returns (uint256) {
        if (epoch == 0) return PRICE_EPOCH0;
        return (FIRST_EPOCH_SIZE << (epoch - 1)) * SHARE_PRICE;
    }

    /// @dev Minimum difficulty (bits) for `epoch`; doubles each epoch.
    function floorBits(uint256 epoch) internal pure returns (uint256) {
        return 26 + epoch;
    }
}