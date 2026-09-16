// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {HashBotsTestBase} from "./TestBase.sol";

/// @dev Difficulty engine: bursts, decay, retarget, epoch floor, wall, failsafe.
contract DifficultyTest is HashBotsTestBase {
    address internal a = address(0xA11A);
    address internal b = address(0xB22B);
    address internal c = address(0xC33C);

    function setUp() public {
        _deploy(6);
    }

    function test_NetworkBurst_Rises_AndCapsAt16() public {
        _deployFull(1, PROD_WALL_FROM, PROD_WALL_DIV, PROD_UNIQUE_WINDOW, PROD_UNIQUE_TOTAL, PROD_SUPPLY_FLOOR);
        for (uint256 i = 0; i < 16; i++) {
            _mint(address(uint160(0x1000 + i)));
        }
        assertEq(bots.effectiveNetworkBurst(), 16, "cap");
    }

    function test_Burst_DecaysWithTime() public {
        for (uint256 i = 0; i < 10; i++) _mint(address(uint160(0x2000 + i)));
        uint256 burst = bots.effectiveNetworkBurst();
        assertGt(burst, 0);
        vm.warp(block.timestamp + 60 * burst); // 60s per bit
        assertEq(bots.effectiveNetworkBurst(), 0, "fully cooled");
    }

    function test_PersonalBurst_IsPerAddress() public {
        _mint(a);
        _mint(a);
        uint256 pa = bots.effectivePersonalBurst(a);
        uint256 pb = bots.effectivePersonalBurst(b);
        assertGt(pa, 0);
        assertEq(pb, 0, "unrelated address unaffected");
    }

    function test_FreshAddress_OnlyPersonalBurstIsPerAddress() public {
        uint256 t0 = bots.targetFor(b);
        uint256 base0 = bots.baseTarget();
        _mint(a);
        _mint(a);
        assertEq(bots.baseTarget(), base0, "no retarget fired with only 2 mints");

        uint256 net = bots.effectiveNetworkBurst();
        assertEq(net, 2, "network burst rose from a's rapid mints");
        assertEq(bots.targetFor(b), base0 >> net, "b pays the global network burst");
        assertEq(bots.effectivePersonalBurst(b), 0, "b has no personal burst");
        assertLt(bots.targetFor(a), bots.targetFor(b), "a pays extra personal burst on top");
    }

    function test_Retarget_HardensWhenTooFast() public {
        uint256 before = bots.baseTarget();
        // Retarget windows fire on the 9th mint (pre-increment: totalMinted reaches 8).
        for (uint256 i = 0; i < 9; i++) _mint(address(uint160(0x3000 + i)));
        assertLt(bots.baseTarget(), before, "base target should shrink (harder)");
    }

    function test_Retarget_EasesTowardFloor_WhenIdleButClamped() public {
        // Push difficulty up with a fast burst of mints...
        for (uint256 i = 0; i < 9; i++) _mint(address(uint160(0x4000 + i)));
        uint256 hardTarget = bots.baseTarget();
        // ...then go idle well past the 4x-ease window (expected*4 = 320s).
        vm.warp(block.timestamp + 400);
        for (uint256 i = 0; i < 9; i++) _mint(address(uint160(0x5000 + i)));
        // The 4x ease overshoots the epoch floor, so the retarget must clamp to
        // exactly the floor ceiling, not to baseTarget*4 (which would be far easier).
        uint256 floor = bots.epochFloor(bots.currentEpoch());
        assertEq(bots.baseTarget(), floor, "ease clamps exactly to the epoch floor");
        assertGe(bots.baseTarget(), floor, "never easier than the epoch floor");
        // The spike (snapped during the burst) was well harder than the raw 4x
        // ease target, which further proves the floor — not the multiply — bound it.
        assertLt(hardTarget, floor * 4, "unclamped 4x ease would be easier than the spike");
    }

    function test_EpochFloor_RisesWithEpoch() public {
        uint256 e0 = bots.epochFloor(0);
        uint256 e1 = bots.epochFloor(1);
        uint256 e5 = bots.epochFloor(5);
        assertEq(_targetBits(e0), 6); // floorBits(6) + 0
        assertEq(_targetBits(e1), 7);
        assertEq(_targetBits(e5), 11);
        assertGt(_targetBits(e5), _targetBits(e1));
    }

    function test_Wall_Bites_BelowFloor() public {
        _deployFull(2, 16, 4, 1024, 16, 100); // wall kicks in after 16 bots, divisor every 4 over
        assertEq(bots.wallFrom(), 16);
        for (uint256 i = 0; i < 33; i++) {
            vm.warp(block.timestamp + 65); // keep burst ~cooled so mints stay cheap
            _mint(address(uint160(0x6000 + i)));
        }
        // The last retarget fires at the 33rd mint with pre-increment totalMinted=32:
        //   over = 32 - 16 = 16 -> divisor (1 + 16/4) = 5; floor clamped to epoch floor.
        uint256 floor = bots.epochFloor(bots.currentEpoch());
        uint256 expected = floor / (1 + (32 - bots.wallFrom()) / bots.wallDiv());
        assertGt(expected, 0);
        assertEq(bots.baseTarget(), expected, "wall divisor applied at last firing");
        assertLt(bots.baseTarget(), floor, "wall makes difficulty exceed the floor");
    }

    function test_Failsafe_OnlyOwner() public {
        vm.prank(b);
        vm.expectRevert();
        bots.setPace();
    }

    function test_Failsafe_RequiresIdle() public {
        _mint(a);
        vm.expectRevert(bytes("Not idle"));
        bots.setPace();
    }

    function test_Failsafe_HalvesDifficulty_AfterLongIdle() public {
        for (uint256 i = 0; i < 8; i++) _mint(address(uint160(0x7000 + i)));
        uint256 before = bots.baseTarget();
        vm.warp(block.timestamp + 500); // > FAILSAFE_MAX(20) * TARGET_INTERVAL(10) = 200s
        bots.setPace();
        assertGt(bots.baseTarget(), before, "difficulty halved via failsafe");
    }

    function _targetBits(uint256 target) internal pure returns (uint256) {
        if (target == 0) return 256;
        uint256 msb;
        for (uint256 t = target; t > 1; t >>= 1) msb++;
        return 256 - (msb + 1);
    }
}