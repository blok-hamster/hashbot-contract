# Audit Fixes — Implementation Plan & Step-by-Step Guide

Status: DONE — all phases shipped (audit 2016-09-15).
Owner: contract engineer. Scope: `contracts/` only; UI is out of scope except
where a read is affected.

## 0. Decisions to sign before writing code

Resolved 2016-09-15:
- **D1**: keep 70/30 unstake split; decision sheet row 6 updated.
- **D2**: keep 1,000,000 genesis supply; decision sheet row 7 updated.
- **D3**: burn during the 24h forge output lock is **lawful** (doc:133 forbids
  sell/forge only); pinned by `test_Forge_OutputCanBurnWithinLock_AfterAgeGate`.

(Original decision matrix preserved below for the record.)

Two findings are *doc-vs-code mismatches* and need an explicit value before the
contract is touched:

| # | Finding | Decision needed | Options |
|---|---------|-----------------|---------|
| D1 | Unstake fee destination (`PowBots.sol:578`) | Keep 70/30 (rent 70% / buyback pool 30%, like a mint) **or** go 100% to rent per decision sheet row 6 / doc:202 | A = keep 70/30 + update decision sheet; B = change code to 100% rent |
| D2 | Genesis supply (`HashToken.sol:11`) | Seed 1,000,000 `$BOT` (Hashcats lore, IMPLEMENTATION_PLAN) **or** 1,000 (decision sheet row 7) | A = keep 1M + update decision sheet; B = change to 1,000 + update deploy script |

Both default to **A (keep current code, fix the decision sheet)** unless the sheet
is considered binding — then they default to B and include both contract +
deploy changes + test edits.

| # | Finding | Decision needed | Options |
|---|---------|-----------------|---------|
| D3 | Burn during the 24h forge lock (`PowBots.sol:364`) | Is burning a forge output before its 24h lock passes lawful? doc:133 forbids *selling/forging* only. | A = lawful, add test pinning it; B = forbidden, add forgeLocked gate to `burn()` |

## 1. Phase plan (do in order)

### Phase 1 — HIGH severity bug (no decision needed)
1.1 **Unblock staking of forge outputs after the 24h lock.** `PowBots.sol:561`.
1.2 Update `Stake.t.sol` with regression tests (before AND after lock).
1.3 Full `forge test` must stay green.

### Phase 2 — Decision-gated fixes (D1, D2)
2.1 Apply the chosen outcome for D1 (unstake fee split) and D2 (genesis supply).
2.2 Update the affected tests + the decision sheet so docs match.
2.3 Full `forge test`.

### Phase 3 — Pool hardening (D3 + MEDIUM/LOW findings)
3.1 Resolve D3 (burn during 24h lock).
3.2 Tighten Pool router trust (`Pool.sol:60`) — make router set-once.
3.3 Add keeper role / spend cap to `swapAndBurn` (`Pool.sol:86`).
3.4 (Optional) Document rent truncation dust — no code change.

### Phase 4 — Verification & deploy
4.1 `forge test`, tsc + vite build, live anvil smoke.
4.2 Prod deploy + custom verify, or redeploy local stack.

---

## 2. Step-by-step guide

### Phase 1 — Fix the forge-lock staking bug

**Step 1.1 — Patch `stake()`** in `contracts/src/PowBots.sol`, line 561:

```solidity
// old (broken: blocks all forge outputs forever)
require(!forgeLocked[tokenId], "Locked 24h");

// new (mirrors forge() lines 437-439)
require(!forgeLocked[tokenId] || block.timestamp >= catMintTime[tokenId] + FORGE_LOCK, "Locked 24h");
```

Why: `forgeLocked` is set true at forge (line 483) and never cleared, so the old
check rejected staking even after the lock window. The condition must expire on
`catMintTime[tokenId] + FORGE_LOCK` like the other gates.

**Step 1.2 — Add regression tests** in `contracts/test/Stake.t.sol` (replace the
one-sided `test_Stake_RevertsForgeOutputDuringLock` with a two-sided pair):

```solidity
function test_Stake_RevertsForgeOutputDuringLock() public {
    (uint256 id1, uint256 id2, uint256 id3) = _trio();
    uint256 fee = bots.FORGE_FEE();
    vm.deal(alice, fee + 1 ether);
    vm.prank(alice);
    uint256 outId = bots.forge{value: fee}(id1, id2, id3);

    vm.prank(alice);
    vm.expectRevert(bytes("Locked 24h"));
    bots.stake(outId, LOCK);
}

function test_Stake_AllowsForgeOutputAfterLock() public {
    (uint256 id1, uint256 id2, uint256 id3) = _trio();
    uint256 fee = bots.FORGE_FEE();
    vm.deal(alice, fee + 1 ether);
    vm.prank(alice);
    uint256 outId = bots.forge{value: fee}(id1, id2, id3);

    vm.warp(block.timestamp + 24 hours + 1); // lock expired
    vm.prank(alice);
    bots.stake(outId, LOCK);

    assertTrue(bots.staked(outId), "forge output stakeable after 24h lock");
}
```

**Step 1.3 — Run the suite:**

```sh
cd contracts
forge test            # expect 85+ tests passing (now +2)
```

---

### Phase 2 — Decision-gated fixes

**Step 2.1a — D1 = Option A (keep 70/30, update docs).**
No contract change. Fix `contracts/docs/forge-decision-sheet.md` row 6:

```markdown
| 6 | unstake fee | doc:202 — TO SET, to the rent pool; split 70/30 rent / buyback like a mint | 0.0005 | |
```

**Step 2.1b — D1 = Option B (100% to rent).**
Patch `PowBots.sol:578-582`:

```solidity
uint256 fee = UNSTAKE_FEE;
require(msg.value >= fee, "Fee");
rentPerWeight += (fee * RENT_PRECISION) / totalWeight; // whole fee to rent pool
pool.deposit{value: 0}(); // no hook share — or drop the call
```

Then update `test_Stake_UnstakePaysFeeToRentPool` to assert 100% of the fee lands
in `rentPerWeight` and `pool.balance` is unchanged.

**Step 2.2a — D2 = Option A (keep 1M, update docs).**
No contract change. Fix `forge-decision-sheet.md` row 7:

```markdown
| 7 | genesis supply | doc:227 — TO SET, $BOT seeded into the pool at launch; 1,000,000 (Hashcats lore) | 1,000,000 | |
```

**Step 2.2b — D2 = Option B (change to 1,000).**
Patch `HashToken.sol:11`:

```solidity
uint256 public constant GENESIS_SUPPLY = 1_000e18;
```

`Deploy.s.sol:53` and `DeployLocal.s.sol:30` use `bot.GENESIS_SUPPLY()` so they
follow automatically. No other change.

**Step 2.3 — Run `forge test` again.** Update any test asserting
`GENESIS_SUPPLY` or the unstake split before running.

---

### Phase 3 — Pool hardening

**Step 3.1 — Resolve D3.** Pick one of:

- **Option A (lawful):** add a regression test that a forge output *can* be burned
  after its 600s age gate even within the 24h lock (already true; pin it).
- **Option B (forbidden):** add to `burn()` after the staked check
  (`PowBots.sol:367`):

```solidity
require(!forgeLocked[tokenId] || block.timestamp >= catMintTime[tokenId] + FORGE_LOCK, "Locked 24h");
```

and a corresponding revert test.

**Step 3.2 — Router trusted-setup-once** in `contracts/src/Pool.sol`:

```solidity
function setSwapRouter(ISwapRouter _swapRouter) external onlyOwner {
    require(address(swapRouter) == address(0), "Already set"); // set once
    swapRouter = _swapRouter;
    emit RouterSet(address(_swapRouter));
}
```

Add `test_setSwapRouter_OnlyOnce`. Optionally transfer `Ownable` to a timelock
after genesis liquidity exists — note it in the README security section.

**Step 3.3 — Keeper role on `swapAndBurn`** in `Pool.sol`:

```solidity
mapping(address => bool) public keepers;
event KeeperSet(address indexed keeper, bool enabled);

function setKeeper(address keeper, bool enabled) external onlyOwner {
    keepers[keeper] = enabled;
    emit KeeperSet(keeper, enabled);
}
```

Gate `swapAndBurn` callers: `require(keepers[msg.sender], "Not keeper");` (the doc
already says *"Keepers call swapAndBurn()"*). Keep `amountOutMin` + the
`lastPriceBotsPerEth` floor as the slippage backstop. Add:
- `test_swapAndBurn_OnlyKeeper`
- `test_swapAndBurn_KeeperCanSwap`
- `test_setKeeper_OnlyOwner`

(If a fully public buyback is wanted, skip the role and instead cap
`amountIn` per call — but the keeper role matches the doc.)

**Step 3.4 — Rent dust note (no code).**
Add to `IMPLEMENTATION_PLAN.md` security notes: per-mint integer truncation in
`rentPerWeight` accrues unclaimable dust inside `PowBots`. Accepted cost of the
"exactly 70% of price" rule.

---

### Phase 4 — Verification & deploy

**Step 4.1 — Repo checks.**

```sh
cd contracts && forge build && forge test        # all suites green
cd ../ui && npx tsc --noEmit && npx vite build   # UI still type-clean
cd ../miner/go && go test ./...                  # solver unchanged, still green
cd ../sdk && npm test                            # golden vector still passes
```

**Step 4.2 — Live anvil smoke (local stack).**

```sh
# fresh chain + deploy
anvil --port 8545 --block-gas-limit 300000000 &
cd contracts
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
forge script script/DeployLocal.s.sol --rpc-url anvil --broadcast -vv
POWBOTS=0x<PowBots> forge script script/DeployArtClean.s.sol --rpc-url anvil --broadcast -vv
RENDERER=0x<Renderer> POWBOTS=0x<PowBots> forge script script/DeployRarity.s.sol --rpc-url anvil --broadcast -vv
```

Manual smoke of the Phase-1 fix (via cast):

1. Mint 3 bots (or `cast send` with a found nonce), warp +700s:
   ```sh
   cast rpc anvil_setNextBlockTimestamp $(( $(date +%s) + 700 ))
   cast rpc evm_mine
   ```
2. Forge them → output `100002`, still forge-locked.
3. Try to stake the output → must revert `Locked 24h`.
4. Warp `+24h` (24h + 1s), stake the output → must succeed.
5. `bots.staked(100002) == true`, `stakedCount` +1.

**Step 4.3 — Prod deploy sequence** (only after D1/D2 signed and Phase 1–3 merged):

```sh
cd contracts
export PRIVATE_KEY=0x…                     # from .env
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify -vvvv
# record TOKEN / POOL / POWBOTS into .env
forge script script/Verify.s.sol  --rpc-url base_sepolia --broadcast -vvvv
POWBOTS=0x… forge script script/DeployArt.s.sol --rpc-url base_sepolia --broadcast -vvvv
RENDERER=0x… POWBOTS=0x… forge script script/DeployRarity.s.sol --rpc-url base_sepolia --broadcast -vvvv
forge script script/SeedLiquidity.s.sol --rpc-url base_sepolia --broadcast -vvvv
```

> The renderer + Rarity wiring must happen **before any forge / rarity read**:
> `forge()` and `Rarity` depend on `renderer.selectTraits()` (PowBots.sol:533).

**Step 4.4 — Test matrix sign-off:**

| Check | Command | Expected |
|---|---|---|
| Forge/stake gates | `forge test` | 85 + new tests green |
| UI typing | `cd ui && npx tsc --noEmit` | clean |
| UI build | `cd ui && npx vite build` | builds |
| Mining golden | `cd miner/go && go test ./...` | green |
| SDK vector | `cd sdk && npm test` | green |
| Live forge→stake | cast smoke (Step 4.2) | Phase-1 flow works |

---

## 3. File change index

All applied and green. Addendum to the plan:

- **Phase 1 / 3 ship notes**: `PoolGates.t.sol:7` — the test contract grants itself
  keeper via `setKeeper` in `TestBase._deployFull` (line 77), so the pre-existing
  `Econ.t.sol` buyback tests run unchanged behind the new gate.
- **Stake suite**: `test_Stake_AllowsForgeOutputAfterLock` added (after-lock stake);
  the existing during-lock revert test is unchanged.

| File | Change | Phase | Status |
|------|--------|-------|--------|
| `contracts/src/PowBots.sol` | stake() lock-window fix (line 561) | 1 | done |
| `contracts/src/Pool.sol` | setSwapRouter set-once + keeper role | 3 | done |
| `contracts/test/Stake.t.sol` | forge-output stake tests (2-sided) | 1 | done |
| `contracts/test/Forge.t.sol` | burn-during-lock pinning test | 3 | done |
| `contracts/test/PoolGates.t.sol` (new) | router/keeper/swapAndBurn tests | 3 | done |
| `contracts/test/TestBase.sol` | grant test-contract keeper in fixture | 3 | done |
| `contracts/docs/forge-decision-sheet.md` | D1/D2 doc alignment | 2 | done |
| `README.md` | pool trust + rent-dust notes (§9) | 3 | done |
| `contracts/docs/IMPLEMENTATION_PLAN.md` | Pool §4 + rent-dust note | 3 | done |
| `contracts/docs/BUILD_SPEC.md` | liquidity bootstrap vs real `swapAndBurn` | 3 | done |

Suite: **96 tests pass** (was 85; +1 stake, +1 forge burn-lock, +9 PoolGates).
D1-B / D2-B / D3-B (the rejected alternatives) were not implemented.