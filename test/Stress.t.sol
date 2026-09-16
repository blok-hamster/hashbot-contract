// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {HashBotsTestBase} from "./TestBase.sol";

/// @dev Large-scale mint simulation with invariant checks across the whole flow.
contract StressTest is HashBotsTestBase {
    function test_Stress_1000Mints_Invariants() public {
        _deployFull(1, PROD_WALL_FROM, PROD_WALL_DIV, PROD_UNIQUE_WINDOW, PROD_UNIQUE_TOTAL, PROD_SUPPLY_FLOOR);
        uint256 N = 1000;
        uint256 expectedHook = 0;

        for (uint256 i = 0; i < N; i++) {
            vm.warp(block.timestamp + 65); // cool burst; target interval pace
            uint256 id = _mint(address(uint160(0x9000 + i)));
            assertEq(id, i + 1, "tokenId == mint order");
            // With no active stakers, the 3% stake bonus pool is diverted to the buyback pool (30% + 3% = 33%).
            expectedHook += (bots.catPricePaid(id) * 3300) / 10000;
        }

        assertEq(bots.totalMinted(), N, "all minted");
        assertEq(bots.aliveCount(), N, "nothing burned");
        assertEq(bots.burnedCount(), 0);
        assertEq(bots.uniquesTaken(), 0, "window 1024 not reached");
        assertEq(address(pool).balance, expectedHook, "pool got 33% (30% hook + 3% diverted stake bonus)");

        // Difficulty never got EASIER than the epoch floor and stayed bounded.
        assertLe(bots.baseTarget(), bots.epochFloor(bots.currentEpoch()), "floor holds");

        // Every burned cat is none (no burns), so alive == minted; rent accrued.
        assertGt(bots.rentPerWeight(), 0, "rent accrued");

        // Spot-check a mid-life token's chain data.
        uint256 mid = 500;
        assertGt(bots.catDepth(mid), 0, "depth recorded");
        assertGt(bots.catSeed(mid), 0, "seed recorded");
        assertEq(bots.catMiner(mid), address(uint160(0x9000 + mid - 1)), "miner recorded");
    }

    function test_Stress_SustainedSafePace_HoldsFloor() public {
        _deployFull(4, PROD_WALL_FROM, PROD_WALL_DIV, PROD_UNIQUE_WINDOW, PROD_UNIQUE_TOTAL, PROD_SUPPLY_FLOOR);
        // ≥BURST_COOL apart: burst stays cooled, every retarget clamps base to the epoch floor.
        uint256 N = 72; // multiple of the retarget window, no trailing bump of the epoch
        for (uint256 i = 0; i < N; i++) {
            vm.warp(block.timestamp + 65);
            _mint(address(uint160(0xA000 + i)));
        }
        assertEq(bots.effectiveNetworkBurst(), 1, "burst cooled between mints");
        assertEq(bots.baseTarget(), bots.epochFloor(bots.currentEpoch()), "pace holds the floor");
    }
}