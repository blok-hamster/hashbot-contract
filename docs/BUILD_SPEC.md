# HashBots — Build & Integration Spec

Everything a UI engineer or miner needs, so both sides converge on one interface.
Target network: **Base Sepolia** (chain id `84532`); the `anvil` fast-difficulty layout
uses chain id `31337` for local testing.

## Contracts & ABIs

| Contract | ABI |
|----------|-----|
| `PowBots` (implements dispenser, rent, difficulty) | `contracts/abi/PowBots.json` |
| `HashToken` (ERC-721) | `contracts/abi/HashToken.json` |
| `Pool` (30% buyback/burn, LP reserve, rent vault, swap-and-burn) | `contracts/abi/Pool.json` |

A typed TypeScript SDK (`sdk/`) wraps all of this for browser work: it binds
`contracts/abi/PowBots.json` to an ethers `Contract`, reads `getStatus()`, builds the mining
preimage/digest, checks `h < target`, and emits a ready-to-sign `mint` transaction
(selector `0x80fc052a`). See `sdk/README.md`; its tests pin the same on-chain golden
vector used everywhere else in this repo.

Production constructor (from `script/Deploy.s.sol`, in order):

```text
PowBots(string name, string symbol, IHashToken token, IPool pool,
        uint256 floorBits, uint256 wallFrom, uint256 wallDiv,
        uint256 uniqueWindow, uint256 uniqueTotal)
```

Production values: `floorBits=26`, `wallFrom=4444`, `wallDiv=200`,
`uniqueWindow=1024`, `uniqueTotal=16`.

Getter hints for wiring: `PowBots.mintPrice()`, `uniquesRemaining()`,
`targetFor(miner)`, `aliveCount()`, `currentEpoch()`, `epochFloor(epoch)`,
`lastWork()`, plus Parity values on `HashToken`/`Pool` (see their ABIs).

## The one status call: `getStatus(address miner)`

`view`, returns **14 values** in this exact order:

| # | name | meaning |
|---|------|---------|
| 1 | `target` | current personal target `T` (256-bit uint) |
| 2 | `targetBits` | `bitlen(T)` — how many leading zero bits a winning hash needs |
| 3 | `floorBitsNow` | difficulty floor for the current epoch (`floorBits + epoch`) |
| 4 | `anchor` | `blockhash(block.number - 1)` for the caller to use (never zero) |
| 5 | `anchorNum` | `block.number - 1` (must be within `ANCHOR_WINDOW=250`) |
| 6 | `prevWork` | must equal `PowBots.lastWork()` for a mint to pass |
| 7 | `price` | ETH required (`msg.value`) for the next mint |
| 8 | `netBurst` | network "burst" allowance (attack damping) |
| 9 | `persBurst` | personal burst allowance for this miner |
| 10 | `alive` | current live-bot count |
| 11 | `minted` | `totalMinted` — next token id will be `minted + 1` |
| 12 | `epoch` | current epoch |
| 13 | `lastMint` | `lastMintTime` (unix) |
| 14 | `canMine` | `true` unless the wall is up / difficulty floor is 1 |

Decode: no field is nested; each of the 13 uints is an ABI word, `canMine` the 14th.
Rough JS consumption:

```js
const s = await powbots.getStatus(user);
// winning condition for a solution H:
//   BigInt("0x"+H) < target
// market display:
//   priceEth    = ethers.formatEther(s.price)
//   rentSlice   = s.price * 7n / 10n
//   yourShare   = rentSlice / BigInt(s.alive)
```

## Mining

A bot is mined with a single `mint(tx)` where the "work" is:

```
P = miner[20] ‖ nonce_BE[8] ‖ prevWork[32] ‖ anchor[32]     # 92 bytes, exactly
H = keccak256(P)
WIN  ⟺  H < target
```

- `miner` = the 20-byte **miner address** (msg.sender), left-aligned raw bytes.
- `nonce` = uint64 **big-endian** — the only free variable. Uint256-encoded in calldata.
- `prevWork` = `lastWork()` when the mint is built (0 for the first bot); must match on
  chain or the tx reverts `"Bad prev"` — never pre-compute across blocks.
- `anchor`/`anchorNum` probe: use `anchorNum = block.number - 1`,
  `anchor = blockhash(anchorNum)`, valid for 250 blocks.

Calldata for `mint(uint64 nonce, uint256 prevWork, uint256 anchorNum, bytes32 anchor)` —
selector `0x80fc052a`, `msg.value = price`:

```
0x80fc052a
<32B: nonce uint64 BE padded to 256>     # e.g. 0x00…0017c for nonce 380
<32B: prevWork>
<32B: anchorNum>
<32B: anchor>
```

Reference implementations: `miner/go/` (supported everywhere), `miner/cuda/`
(Linux + NVIDIA, built with `cd miner/cuda && ./build.sh`, work fed as JSON on stdin).
CUDA kernel math is host-tested against a real on-chain solve in
`miner/cuda/keccak_host_test.c` (`cc -O2 … && ./a.out`).

**Strategy notes.** `target` can differ between miners (burst damping) — always solve
your own personal target. Difficulty raises after every 10% of the collection; when
`targetBits = floorBitsNow` you must effectively spend the next `targetBits`
leading zeros. The unique-window (`uniqueTotal=16`) means long single-account grinding
saturates; keys rotate (see Go miner `-keystore`).

## Deploy & verify (Base Sepolia)

```sh
export PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify -vvvv
# note HashToken/Pool/PowBots addresses; write to .env:
#   TOKEN=0x… POOL=0x… POWBOTS=0x…
forge script script/Verify.s.sol --rpc-url base_sepolia --broadcast -vvvv
```

`script/Deploy.s.sol` wires `HashToken.setPowBots` and `Pool.setPowBots`, then seeds the
`1_000_000e18` genesis `$BOT` into the Pool (`Pool.buybackBurn` = burning reserve +
LP bootstrap material). Router default = SwapRouter02 Base Sepolia
`0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4`; override `SWAP_ROUTER`
(mainnet: `0x2626664c2603336E57B271c5C0b26F421741e481`).

## Liquidity bootstrap (customer-controlled, no privileged path)

`forge script script/SeedLiquidity.s.sol --rpc-url base_sepolia --broadcast -vvvv`
prints the exact steps it **recommends** — it does not move your funds itself:

1. `swapAndBurn` (keeper-gated, router fixed at deploy) is the pool's only ETH exit: the
   swap buys `$BOT` back to the Pool and `bot.burn(amount)` destroys it; `$BOT` held by
   the Pool is otherwise untouched.
2. Wait for natural ratio: mints put WETH back into `Pool` (70% rents, 30% reserved).
3. Provide `pool` ETH + `$BOT` on Uniswap V3 (e.g. via the router with the collected
   fees/DCA) to establish the `$BOT/ETH` pair the tokenURI + UI are built around.

## Chain facts

- WETH Base: `0x4200000000000000000000000000000000000006`
- Base Sepolia SwapRouter02: `0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4`
- Mainnet SwapRouter02: `0x2626664c2603336E57B271c5C0b26F421741e481`
- Base Sepolia RPC: `https://sepolia.base.org` (see `contracts/foundry.toml`/`contracts/.env.example`)

## Verifying your own solution (dev)

- Solidity: `uint256(keccak256(abi.encodePacked(miner, nonce, prevWork, anchor)))` where
  `nonce` is `uint64` — `abi.encodePacked` handles the big-endian width.
- Go: `crypto.Keccak256` on the same 92-byte layout (see `miner/go/powbots.go`).
- The `anvil` smoke run proved end-to-end equivalence: the Go miner's found nonce 380
  produced the exact `lastWork` on-chain (`0x000c30c1…2606`).