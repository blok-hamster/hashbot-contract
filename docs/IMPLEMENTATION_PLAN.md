# HashBots — Implementation Plan

> A Hashcats-style fair-launch PoW NFT collection, rebuilt as **HashBots**.
> Collection name: **HashBots** · Token: **$BOT** · Chain: anvil (dev) → **Base Sepolia** (deploy/verify).
> UI is owned by a separate engineer; this repo is contracts + miners + deployment + the `getStatus` read surface the UI polls.

Status: APPROVED — starting build.

---

## 1. Source Documents

| Doc | Role |
|-----|------|
| `docs/POW_CATS_SPEC.sol` guide | Contract structure + difficulty rules + GPU preimage layout |
| `docs/pow_cat.md` | Official Hashcats economics article (rent, buyback-burn, burn halving, flywheel) |
| `docs/HASHCATS_DOCUMENTATION.md` | Live deployment data, mining playbook, `getStatus` read surface |
| `docs/Mineable PoW NFT Technical Specification.pdf` | Generic variant (VRGDA/streak) — superseded, retained for near-miss gamification inspiration |

Econ conflicts in the docs were resolved toward the **real Hashcats model** (article + live data), see §5.

---

## 2. Repository Layout

```
hashbots/
├── foundry.toml            # solidity ^0.8.24, via_ir off, base_sepolia RPC + key
├── .env.example            # PRIVATE_KEY, BASE_SEPOLIA_RPC, ETHERSCAN_API_KEY, DEPLOYER
├── src/
│   ├── HashToken.sol       # ERC20 18-dec; 1M genesis mint to Pool; mint() only via PowBots.onBurn
│   ├── Pool.sol            # 30% of mint ETH → keepers call swapAndBurn() (Uniswap V3) → burn $BOT
│   ├── PowBots.sol         # ERC721 PoW collection — core contract
│   ├── interfaces/
│   │   ├── IHashToken.sol
│   │   ├── IPool.sol
│   │   └── ISwapRouter.sol  # Uniswap V3 SwapRouter (minimal surface)
│   └── libraries/
│       ├── EpochMath.sol    # epoch boundaries, epochOf, price schedule
│       └── KeccakPacked.sol  # shared 92-byte preimage packing (contract ↔ miner mirror)
├── test/
│   ├── PoWGate.t.sol        # accept/reject, address-binding fuzz, anchor/prev chaining
│   ├── Difficulty.t.sol     # retarget clamp, burst caps, epoch floor, wall, failsafe
│   ├── Econ.t.sol           # price schedule, rent, burn, arbitrage pin
│   └── Stress.t.sol         # 5,000-mint sim, reentrancy, refunds
├── script/
│   ├── Deploy.s.sol         # token → pool → powbots, wire minter/Pool roles
│   ├── Verify.s.sol
│   └── SeedLiquidity.s.sol  # fund Uniswap $BOT/ETH pool from Pool's 1M seed
├── miner/
│   ├── go/                  # reference CPU miner (status, mine, pre-sign + race, HD rotation)
│   └── cuda/                # keccak-f1600 kernel (pre-absorbed 84B prefix), Linux build.sh
├── abi/                     # exported ABIs (generated) for the UI engineer
└── docs/
    ├── IMPLEMENTATION_PLAN.md   # this file
    └── BUILD_SPEC.md            # resolved conflicts + precise on-chain math
```

---

## 3. Core Contract — `PowBots.sol`

### 3.1 Mining puzzle (92 bytes, address-bound)
```
keccak256( abi.encodePacked( msg.sender[20], uint64 nonce BE[8], prevWork[32], anchor[32] ) ) < target
```
- **nonce**: `uint64`, big-endian (8 bytes) — matches the GPU layout; NOTE: this intentionally overrides the SPEC's `uint256 nonce` because `abi.encodePacked` on uint64 yields 8 bytes; the SPEC's Go miner packs 8 bytes, so the SPEC's own Solidity would never verify. Docs' "92 bytes" (HASHCATS doc) is treated as correct.
- **prevWork**: exact winning `h` of the previous mint (stored in `lastWork`). Fixes the SPEC's lossy `(1<<d)-1` reconstruction. `prevWork == 0` only for the first cat. Enforces chaining → no pre-mining.
- **anchor**: `mint` takes `anchorNum`; contract requires `block.number - anchorNum <= ANCHOR_WINDOW (250)` and `blockhash(anchorNum) == anchor` and non-zero. Time-bounds every solution (~25s–2.5min shelf life); expired anchors revert "Stale anchor".

### 3.2 Difficulty (four independent rules)
| Rule | Formula | Constants |
|------|---------|-----------|
| Epoch floor | `targetBits >= FLOOR_BITS + epoch` | FLOOR_BITS = 26 |
| Retarget (every 8 mints vs 10s pace) | `newBase = baseTarget / 2` if too fast, `*4` if too slow; clamped to floor | RETARGET_WINDOW=8, TARGET_INTERVAL=10, MAX_RETARGET_UP=2, MAX_RETARGET_DOWN=4 |
| Network burst | `+1 bit per mint`, cap 16 → `currentTarget = baseTarget >> networkBurst` | BURST_SHIFT_CAP=16 |
| Personal burst | `+1 bit per miner mint`, cap 16 → `targetFor = currentTarget >> personalBurst[addr]` | BURST_SHIFT_CAP=16 |
| Wall | after cat 4,444: `newBase /= (1 + (minted-4444)/200)` | WALL_FROM=4444, WALL_DIV=200 |
| Failsafe | admin `setPace`: if idle > FAILSAFE_MAX windows → halve difficulty, emit `PaceChanged` | FAILSAFE_MAX=20 |

Target conversion: `_bitsToTarget(b) = (1<<256) - (1<<(256-b))`, i.e. `≈ 2^(256-b)`; `targetBits(t) = 256 - t.bit_length()`.

### 3.3 Economics (real Hashcats model)
- **Epoch boundaries**: epoch 0 = cats 1–8; epoch N covers cats `(8<<N - 8)+1 .. (8<<N)`. `epochOf(tokenId)` = smallest N such that `tokenId <= 8<<N`. `currentEpoch` derived from `totalMinted` at each mint.
- **Price**: `mintPrice(0) = 0.000069 ETH` (floor); `mintPrice(N) = (8 << (N-1)) × 0.00002 ETH` for N ≥ 1 (price = cats alive when the epoch opens).
  - Choice recorded: the front end's epoch math won. Note the (8<<epoch) reading maps the documented live datapoint to epoch 9; under the shipped schedule that same `0.08192 ≈ 0.08176 ETH` falls in epoch 10. Round-trip: known live `~0.08176` → epoch 10 → `4096 × 0.00002`.
- **Rent (70%)**: on mint, `holderShare = price × 70 / 100`; `rentRate += holderShare × PRECISION(1e6) / aliveCount` where `aliveCount = totalMinted - burnedCount`. Per-token `claimable = (rentRate - collected[tokenId]) / PRECISION`. Pull model; **claim lives on the token** (transfers preserve `collected`, ownership-independent). Burn removes the token from `aliveCount` → every later mint gives survivors a bigger slice ("Every burn is a raise for everyone who stayed").
- **Pool (30%)**: `hookShare = price × 30 / 100` transferred to `Pool` at mint (guard `onlyPowBots`). Pool buyback-burns on the open market (§4).
- **Burn**: after `BURN_DELAY=600s` and a later cat exists (`totalMinted > tokenId`): mint `burnAmount = 1,000e18 >> (curEpoch - tokenEpoch)` $BOT to burner, burn the token. Halving per epoch passed; floored at 1 wei. Burned bot's accrued-but-uncollected claim is forfeited into the contract (survivors accrue against a smaller `aliveCount`).
- **Unique 1/1**: every `UNIQUE_WINDOW=1024` mints, at most `UNIQUE_TOTAL=16` total, `unique=1` when `totalMinted % 1024 == 0 && uniquesTaken < 16`. Emits `UniqueDrawn`.
- **Seed/art**: `catSeed = keccak256(h, block.timestamp / ROLL_PERIOD(300))` — 5-min bucket, cannot be grinded for rarity. `tokenURI` returns on-chain JSON metadata (name, seed, epoch, depth, unique) — art rendering is the UI engineer's domain; full on-chain PNG art dataset deferred (see §9).

### 3.4 Read surface for UI + miners
`getStatus(address)` → `{target, targetBits, floorBits, anchor, prevWork, mintPrice, networkBurst, personalBurst, aliveCount, totalMinted, currentEpoch, lastMintTime, canMine}`. Also standalone getters: `totalMinted, currentEpoch, mintPrice, baseTarget, currentTarget, networkBurst, personalBurst, targetFor, lastWork, epochFloor, epochOf, getUniquesRemaining`.

All state needed by miners/UI is returned by `getStatus` via one `eth_call`.

---

## 4. `HashToken.sol` + `Pool.sol`

- **HashToken**: ERC20 18 decimals, `MINTER_ROLE`. Constructor mints `1_000_000e18` to Pool (article: "one million $HASH were minted once to seed the pool"). After genesis, `mint()` is callable **only by PowBots** (on burn). Burns via Pool buyback are plain ERC20 `burn`.
- **Pool**: accumulates `onlyPowBots` ETH (30% of each mint). **Keepers** call `swapAndBurn()` (keeper-gated; audit 2016-09-15): swaps accumulated ETH → WETH → $BOT via Uniswap V3 SwapRouter (`exactInputSingle`, beneficiary = this contract, then `bot.burn`), respecting `MAX_SLIPPAGE_BPS`. The router is fixed at deploy (setter is set-once, so an owner cannot redirect pool ETH post-launch). Config: `setMaxSlippageBps`, `setKeeper`. Holds the 1M genesis $BOT for LP seeding + buyback-burn reserve. Emits `SwappedAndBurned(ethAmount, botsBurned)`. Known accepted cost: per-mint truncation in `rentPerWeight` accumulates unclaimable dust inside `PowBots` (note in README §9).
- **Econ invariant for tests**: if `1,000 $BOT > mintPrice`, mint+burn is profitable → arbitrage pins `$BOT ≈ mintPrice / 1000`.

---

## 5. Resolved Doc Conflicts (recorded in BUILD_SPEC.md)

| Question | Docs disagreed | Chosen (source) |
|----------|----------------|-----------------|
| Price formula | SPEC: `PRICE_EPOCH0×2^epoch`; article/live: cats×0.00002; front end: `(8<<(N-1))×0.00002` | `(8<<(N-1))×0.00002`, epoch0 floor 0.000069 (matches live 0.08176 ≈ epoch 10) |
| Burn payout | SPEC: fixed 1,000; article: 1,000, halving/epoch | 1,000 × 2^(−epochs since token) (article) |
| Rent split | SPEC: 30% hook only; article: 70% rent + 30% buyback | 70/30 (article); rent claim on token |
| nonce type | SPEC contract `uint256` vs miner/docs 8 bytes | `uint64` BE (matches "92-byte" GPU preimage) |
| prevWork | reconstruct `(1<<d)-1` | store exact winning hash |
| anchor | placeholder in SPEC | verified `blockhash(anchorNum)` within 250 blocks |

---

## 6. Test Matrix (Foundry)

- **PoWGate**: valid mint passes; wrong nonce/prev/anchor fails; **address-binding fuzz** (a second user submitting the winning nonce/prev/anchor must revert); anchor expiry; excess ETH refunded; first cat prevWork=0; nonce/prev duplication cannot mint twice.
- **Difficulty**: retarget clamps within [½,4]×; epoch floor never crossed; network+personal burst caps at 16; wall kick-in at 16,376 and monotonic difficulty after; failsafe halve on long idle + `PaceChanged`.
- **Econ**: price table (0.000069 … 0.16384) exact (epoch0 floor … epoch 11 `(8<<10)×0.00002`); rent accrues 70% pro-rata to alive cats; claim follows token (transfer then collect by new owner); burn amounts (delay, halving per epoch, >1 cat requirement, 1-wei floor); survivor rent share rises after burn; pool receives 30% each mint; token mint only via burn; arbitrage pin invariant; unique drops at 1024 boundaries, cap 16.
- **Stress**: 5,000-mint simulation with mixed wallet rotation; invariant checks (token ≤ burned-mint supply, rent distributed ≤ 70% of cumulative price, aliveCount consistent, difficulty monotonically bounded above by wall).

---

## 7. Miner

- **`miner/go`** (reference CPU, runs on macOS/anywhere): one `eth_call getStatus` per loop; keccak sweep (mirrors `KeccakPacked.sol` big-endian packing); on solve → pre-sign tx + broadcast to 3 RPCs; HD wallet rotation after mint; `newHeads` subscription invalidates stale work. Flags: `-burst-cap`, `-bits-min`, `-workers`, `-keystore`.
- **`miner/cuda`** (NVIDIA, Linux): keccak-f1600 kernel in CUDA; fixed 84-byte prefix (address+prev+anchor) pre-absorbed once per status fetch; only the 8-byte nonce rotates in the final squeeze — single-round variant, 10k+ threads; host (C) streams found nonce → JSON/stdout consumed by the Go submitter. `build.sh` targets a Linux 40x0 rig (Ubuntu/Vast.ai). ⚠️ macOS cannot compile/run CUDA (Apple dropped support) — kernel ships compile-clean as source; CI-grade verification happens on a Linux GPU host.

---

## 8. Build Order

1. ✅ Plan doc saved
2. Foundry scaffold: `foundry.toml`, `.env.example`, `forge install` deps (OpenZeppelin), minimal `lib/` (all under `contracts/`)
3. Contracts: `libraries/` → `interfaces/` → `HashToken` → `Pool` → `PowBots`
4. `forge build` clean → tests green on `forge test` (anvil)
5. Deploy/verify/seed scripts → check on Base Sepolia
6. Go CPU miner → local solve against anvil with real deployed contract
7. CUDA kernel + `build.sh` + miner README
8. Export `contracts/abi/`, write root `README.md` + `contracts/docs/BUILD_SPEC.md`

---

## 9. Deferred / Out of Scope (for now)

- **Fully on-chain PNG art** (real Hashcats ships 147 KB of sprites + in-contract PNG assembly). HashBots stores `catSeed` + on-chain metadata JSON; UI renders art deterministically from the seed. Art dataset/table can be added later without changing the mint logic.
- **Near-miss "Bots That Got Away"** gamification (from the PDF) — UI-side feature; no contract change needed.
- Rust miner — no toolchain installed; Go+CUDA covers reference + high-throughput paths.
- Contracts are **non-upgradeable** by design (mirrors Hashcats "no admin keys" ethos); only `setPace` (failsafe retarget) + Pool config are owner-settable.

---

## 10. Naming

Collection: **HashBots** · Symbol: `HASHBOTS` · Token: **$BOT** (`BOT`). File/class names follow (`PowBots`, `HashToken`). Trivial to rename if the brand changes.