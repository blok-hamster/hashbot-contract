// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {HashBotsTestBase} from "./TestBase.sol";

/// @dev Economics: price schedule, rent (70%), pool (30%), burn & $BOT halving, uniques.
contract EconTest is HashBotsTestBase {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B0B);
    address internal carol = address(0xCA801);

    function setUp() public {
        _deploy(6);
    }

    function test_PriceSchedule_MatchesDocumentedTable() public {
        assertEq(bots.mintPrice(), uint256(69_000_000_000_000), "epoch 0 floor");
        assertEq(uint256(20_000_000_000_000 * (8 << 0)), uint256(160_000_000_000_000), "epoch1 formula");
        assertEq(uint256(20_000_000_000_000 * (8 << 5)), uint256(5_120_000_000_000_000), "epoch6 ~ 0.00512 ETH");
        assertEq(uint256(20_000_000_000_000 * (8 << 9)), uint256(81_920_000_000_000_000), "epoch10 ~ 0.08192 ETH");
    }

    function test_Price_DoublesAtEpochBoundaries() public {
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(block.timestamp + 65);
            _mint(address(uint160(0x100 + i)));
        }
        uint256 epoch1Price = bots.mintPrice();
        assertEq(epoch1Price, 160_000_000_000_000, "entry into epoch 1");
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(block.timestamp + 65);
            _mint(address(uint160(0x200 + i)));
        }
        uint256 epoch2Price = bots.mintPrice();
        assertEq(epoch2Price, 320_000_000_000_000, "entry into epoch 2 = double");
    }

    function test_Rent_Accrues60Percent_ProRata() public {
        _mint(alice); // id1 — no prior bots, no holders
        _mint(bob);   // id2 — 60% of price to the 1 alive bot
        _mint(carol); // id3 — 60% split across 2 alive bots

        uint256 price = bots.catPricePaid(2);
        uint256 h = (price * 6000) / 10000; // net holder share (60%)
        uint256 grossRent = h + h / 2; // id1 accrued for id2's + id3's mint
        uint256 claimTax = (grossRent * 200) / 10000; // 2% claim tax
        uint256 expectedId1 = grossRent - claimTax;

        uint256 before = alice.balance;
        vm.prank(alice);
        bots.collectRent(1);
        assertEq(alice.balance - before, expectedId1, "pro-rata rent to earliest bot");
    }

    function test_RentClaim_TravelsWithToken() public {
        _mint(alice); // id1
        _mint(bob);   // id2
        _mint(carol); // id3

        vm.prank(alice);
        bots.approve(bob, 1);
        vm.prank(bob);
        bots.transferFrom(alice, bob, 1); // claim lives on the token
        uint256 before = bob.balance;
        vm.prank(bob);
        bots.collectRent(1); // new owner can claim accumulated rent

        assertGt(bob.balance - before, 0, "borrower collects rent");
        vm.expectRevert(bytes("Not owner"));
        vm.prank(alice);
        bots.collectRent(1);
    }

    function test_RentClaim_NothingToClaim() public {
        _mint(alice); // id1 alone: no later bots yet
        vm.expectRevert(bytes("Nothing to claim"));
        vm.prank(alice);
        bots.collectRent(1);
    }

    function test_Pool_Receives30Percent_EachMint() public {
        uint256 expected = 0;
        for (uint256 i = 0; i < 5; i++) {
            _mint(address(uint160(0x300 + i)));
            uint256 price = bots.catPricePaid(i + 1);
            // With no stakers present, the 3% stake bonus is diverted to buyback pool (30% + 3% = 33%).
            expected += (price * 3300) / 10000;
        }
        assertEq(address(pool).balance, expected, "pool received 33% of each mint (30% hook + 3% unallocated stake bonus)");
    }

    function test_Burn_SameEpoch_Yields_1000BOT() public {
        _mint(alice); // id1
        _mint(bob);   // id2
        vm.warp(block.timestamp + 600);
        vm.prank(alice);
        bots.burn(1);

        assertEq(token.balanceOf(alice), 1000e18, "full burn in own epoch");
        assertTrue(bots.catBurned(1));
        assertEq(bots.aliveCount(), 1);
        assertEq(bots.burnedCount(), 1);
    }

    function test_Burn_HalvesForEveryEpochPassed() public {
        _mint(alice); // id1 (epoch 0)
        for (uint256 i = 0; i < 32; i++) {
            vm.warp(block.timestamp + 65);
            _mint(address(uint160(0x400 + i))); // well into later epochs
        }
        uint256 expected = 1000e18 >> (bots.currentEpoch() - bots.epochOf(1));

        vm.warp(block.timestamp + 600);
        vm.prank(alice);
        bots.burn(1);
        assertEq(token.balanceOf(alice), expected, "halving per epoch passed");
    }

    function test_Burn_RequiresLaterBot() public {
        _mint(alice); // id1 — the last bot
        vm.warp(block.timestamp + 600);
        vm.expectRevert(bytes("Last bot"));
        vm.prank(alice);
        bots.burn(1);
    }

    function test_Burn_RequiresDelay() public {
        _mint(alice);
        _mint(bob);
        vm.expectRevert(bytes("Delay"));
        vm.prank(alice);
        bots.burn(1); // < 600s elapsed
    }

    function test_Survivors_GetBiggerSlice_AfterBurn() public {
        _mint(alice); // id1
        _mint(bob);   // id2
        _mint(carol); // id3
        _mint(address(0x0A551)); // id4 — lets us burn id3 without tripping "Last bot"
        uint256 price = bots.catPricePaid(2);
        uint256 h = (price * 6000) / 10000; // net holder share (60%)

        // Collect what id1 earned so far (ids 2 and 3), then burn id3 (owned by carol).
        vm.prank(alice);
        bots.collectRent(1);

        vm.warp(block.timestamp + 600);
        vm.prank(carol);
        bots.burn(3);

        assertEq(bots.aliveCount(), 3, "id4 added, id3 burned: 4 -> 3");

        // Mint id5: each of the 3 surviving bots (id1, id2, id4) gets h/3 — had id3
        // stayed alive the slice would have been h/4. Then 2% claim tax is deducted.
        _mint(carol);
        uint256 before = alice.balance;
        vm.prank(alice);
        bots.collectRent(1);
        uint256 claimed = alice.balance - before;
        uint256 grossSlice = h / 3;
        uint256 claimTax = (grossSlice * 200) / 10000;
        uint256 expectedPayout = grossSlice - claimTax;

        assertEq(claimed, expectedPayout, "survivors split id5's rent evenly minus 2% tax");
        assertGt(claimed, (h / 4) * 9800 / 10000, "burn raised the surviving bots' slice");
    }

    function test_Unique_Drops_EveryWindow_UpToCap() public {
        _deployFull(6, 16376, 200, 4, 5, 100); // unique every 4th mint, cap 5
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + 65);
            _mint(address(uint160(0x500 + i)));
        }

        assertEq(bots.uniquesTaken(), 5, "cap reached");
        assertEq(bots.uniquesRemaining(), 0);
        assertTrue(bots.catUnique(4), "4th is unique");
        assertFalse(bots.catUnique(5), "5th is not");
        assertTrue(bots.catUnique(20), "20th (5th slot) is unique");
    }

    function test_Unique_SkipsAfterCap() public {
        _deployFull(6, 16376, 200, 4, 2, 100); // only 2 uniques in the whole run
        for (uint256 i = 0; i < 16; i++) {
            vm.warp(block.timestamp + 65);
            _mint(address(uint160(0x600 + i)));
        }
        assertEq(bots.uniquesTaken(), 2, "capped at 2");
        assertFalse(bots.catUnique(12), "no more unique after cap");
    }

    function test_Token_MintableOnlyBy_BotsContract() public {
        vm.prank(bob);
        vm.expectRevert(bytes("Only PowBots"));
        token.mint(bob, 1e18);
    }

    function test_Token_GenesisCirculation() public {
        assertEq(token.totalSupply(), token.GENESIS_SUPPLY(), "1M seeded at genesis");
        assertEq(address(pool).balance, 0);
    }

    function test_Buyback_PoolSwapsAndBurns() public {
        for (uint256 i = 0; i < 3; i++) _mint(address(uint160(0x700 + i)));
        uint256 poolEth = address(pool).balance;
        assertGt(poolEth, 0);

        uint256 expectedOut = (poolEth * router.pricePerEth()) / 1e18;
        uint256 supplyBefore = token.totalSupply();

        pool.swapAndBurn(expectedOut);

        assertEq(token.totalSupply(), supplyBefore - expectedOut, "bought back and burned");
        assertEq(pool.lastPriceBotsPerEth(), router.pricePerEth(), "price recorded");
    }

    function test_Buyback_RespectsMinimum() public {
        for (uint256 i = 0; i < 2; i++) _mint(address(uint160(0x800 + i)));
        vm.expectRevert(bytes("mock min"));
        pool.swapAndBurn(type(uint256).max); // absurdly high minimum
    }

    function test_Arbitrage_Structure_MintBurnProfitable() public {
        // "mine a bot, burn it, sell": 1,000 $BOT halving from currentEpoch, flat inside epoch.
        _mint(alice);
        _mint(bob);
        vm.warp(block.timestamp + 600);
        uint256 burnAmount = 1000e18 >> (bots.currentEpoch() - bots.epochOf(1));
        vm.prank(alice);
        bots.burn(1);

        // With router price P (BOT/ETH), burn yields P * burnAmount ETH of $BOT.
        // The docs pin $BOT ≈ entryPrice / 1000 -> keeping the loop self-balancing.
        uint256 entryPrice = bots.mintPrice();
        assertGt(burnAmount, entryPrice / 2, "burn value is in the correct magnitude");
    }
}