# Hashbots — Burn and Forge

The rules, as they stand. No argument, no alternatives considered. If a number
is here it is the number to build against.

Constants live in `src/lib/chain.ts`. Anything marked TO SET has no value yet
and needs one before the contract is written.

---

## 0. Weight

Every bot carries a `weight`. Rent and every distribution read `weight`, never a
count of NFTs.

| token | weight |
|---|---|
| Common (mined) | 1 |
| Rare (3 commons forged) | 3 |
| Epic (3 rares forged) | 9 |
| Legendary (3 epics forged) | 27 |

Total network weight is constant. Forging never creates weight and never
destroys it. This is the rule the whole system rests on: if a forge ever
returned more weight than it consumed, forging becomes compulsory for everyone
and the collection is burnt down for no gain.

---

## 1. Mining

| rule | value |
|---|---|
| Supply gate | difficulty and price, not a cap |
| Wall | bot 16,376 |
| Epoch 0 size | 8 bots; every epoch after is twice the last |
| Epoch 0 price | 0.000069 ETH |
| Later epoch price | `0.00016 x (2^epoch - 1)` ETH |
| Difficulty floor | 26 bits + epoch |
| Retarget | every 8 mints, targeting 10 seconds per bot |
| One-of-ones | 16 total, one chance per 1,024 mints |

Price by epoch, and where the money is:

| epoch | bots | price ETH | epoch total | share of all revenue |
|---|---|---|---|---|
| 0 | 8 | 0.000069 | 0.00 | 0.0% |
| 3 | 64 | 0.001120 | 0.07 | 0.0% |
| 6 | 512 | 0.010080 | 5.16 | 0.3% |
| 8 | 2,048 | 0.040800 | 83.56 | 4.7% |
| 9 | 4,096 | 0.081760 | 334.89 | 18.7% |
| 10 | 8,192 | 0.163680 | 1,340.87 | 75.0% |
| **all** | **16,376** | | **1,786.95** | **100%** |

---

## 2. Where a mint goes

```
entry price -+- 70% -> rent, split between existing weight
             +- 30% -> the hook -+- X% -> project
                                 +- rest -> buy $PIXELBOTS, burn it
```

**Rent is 70% of the price actually paid**, divided by total live weight, and
credited as a claim rather than a transfer. A holder collects when they come
for it.

```solidity
rentPerWeight += (msg.value * 70 / 100) / totalWeight;
```

> **Fix required.** `rentAccrued()` in `src/lib/chain.ts` currently computes
> `rentStep x (epoch + 1)` per mint, which totals 2.29 ETH over the whole
> collection, 0.13% of revenue rather than 70%. The docs pages describe
> `(m-1) x rentStep`, which totals 105% of revenue and is insolvent. Neither is
> right. Use the share-of-price rule above; it is exactly 70% at every mint and
> cannot overspend. `rentStep` becomes a display constant only.

Lifetime rent for one bot under the corrected rule:

| bot | lifetime rent |
|---|---|
| #1 | 0.159 ETH |
| #505 | 0.154 ETH |
| #4,096 | 0.119 ETH |
| #8,188 | 0.079 ETH |
| #16,000 | 0.003 ETH |

Rent stops at the wall. There are no mints after 16,376, so there is no rent
after 16,376. Forge and stake fees are what the contract earns after that.

---

## 3. Burn

Destroys the NFT. Mints `$PIXELBOTS`. Irreversible.

| rule | value |
|---|---|
| Full rate | 1,000 $PIXELBOTS |
| Decay | halves for each epoch waited: `1000 / 2^epochsWaited` |
| Age gate | the bot must be 600 seconds old |
| Effect on weight | the bot's weight leaves the pool permanently |
| Effect on others | total weight falls, so every survivor's share rises |

| epochs waited | tokens |
|---|---|
| 0 | 1,000 |
| 1 | 500 |
| 2 | 250 |
| 3 | 125 |
| 4 | 62 |

Burning three commons on the day they are mined returns **3,000 $PIXELBOTS**
and nothing else.

---

## 4. Forge

Consumes three tokens of the same tier. Returns one token of the next tier.

| rule | value |
|---|---|
| Input | 3 tokens, same tier, same owner |
| Output | 1 token, next tier up |
| Weight | preserved exactly: 3 commons (weight 3) -> 1 Rare (weight 3) |
| Tokens minted | 1,000 $PIXELBOTS, flat, no epoch decay |
| Forge fee | TO SET, in ETH, paid by the forger |
| Where the fee goes | the rent pool, split by weight like a mint |
| Age gate | all three inputs must be 600 seconds old |
| Cooldown | the output cannot be sold or forged for 24 hours |
| Supply floor | forging is refused if live token count would fall below 4,096 |

The ladder:

| forge | inputs | output | output weight | commons destroyed |
|---|---|---|---|---|
| Rare | 3 commons | 1 Rare | 3 | 3 |
| Epic | 3 Rares | 1 Epic | 9 | 9 |
| Legendary | 3 Epics | 1 Legendary | 27 | 27 |

### The choice a holder faces

| action | $PIXELBOTS | NFTs kept | weight kept |
|---|---|---|---|
| Hold 3 commons | 0 | 3 | 3 |
| Burn 3 commons | 3,000 | 0 | 0 |
| **Forge 3 commons** | **1,000** | **1 Rare** | **3** |

Forging costs 2,000 $PIXELBOTS relative to burning. That is the price of
keeping the picture and the rent claim.

### Traits are inherited, never rolled

The output takes, for each trait slot, the rarest value present among the three
inputs, by the published rarity table. Ties break by lowest token id.

No randomness at any point. A random roll resolved in the same transaction can
be read by a calling contract which reverts if it dislikes the result, giving
free rerolls until it wins. On this chain `prevrandao` is sequencer-controlled,
so commit-reveal does not fix it either.

Inheritance also makes specific bots worth more than floor, because a bot with
a scarce visor is a forge ingredient.

### The tier pool

10% of all rent is set aside and split **equally between every Rare and above**.
The remaining 90% is split by weight across all live tokens.

```
rare multiple over a common = 3 + (0.10 / 0.90) x 16,376 / (number of rares)
```

| rares in existence | a Rare earns |
|---|---|
| 250 | 10.3x a common |
| 500 | 6.6x a common |
| 910 | 5.0x a common |
| 2,000 | 3.9x a common |
| 5,458 | 3.3x a common |

The multiple falls as more Rares appear, so forging early is worth more than
forging late, and it never falls below 3x, which is the weight the forger put
in. A common's yield is unchanged by anybody else forging, because total weight
never moves.

---

## 5. Staking

No token emission. `$PIXELBOTS` is minted by burning and forging only.

| rule | value |
|---|---|
| Lock a bot | its owner's personal mining difficulty falls by 1 bit |
| 1 bit means | exactly half the expected work |
| Maximum | TO SET, bits per wallet |
| Minimum lock | TO SET |
| Unstake fee | TO SET, to the rent pool |
| Tokens emitted | none |

A staked bot still earns rent and cannot be sold, forged or burned while locked.

---

## 6. Supply

`$PIXELBOTS` supply moves in two directions.

**Up**, only from destroying an NFT:

| source | maximum ever |
|---|---|
| Burn, if every bot burned at full rate | 16,376,000 |
| Forge, if the whole collection were forged | about 8,188,000 |

In practice far less, because the burn rate halves every epoch waited and
because holders who forge are not burning.

**Down**, continuously: the hook buys `$PIXELBOTS` on the market and destroys
what it buys, funded by 30% of every mint, 30% of every trading fee and 30% of
every resale royalty.

Genesis supply into the pool at launch: **TO SET**.

---

## 7. Trading

| rule | value |
|---|---|
| Venue | one Uniswap v4 pool, ETH / $PIXELBOTS |
| Pool fee | 0%, the hook charges instead |
| Hook fee | 2.5% in, 2.5% out, on the ETH side |
| Opening | bot 1,016, the end of epoch 6 |
| Launch window | starts as high as 50%, decays to 2.5% over 10 minutes |
| Liquidity | can be added by the hook only |
| Buyback cap | 1% price move or 0.025 ETH per L1 block, tighter limit wins |
| Royalty | 5%, ERC-2981, receiver is the hook, receiver is immutable |

---

## 8. Project share

Of everything reaching the hook, a fixed percentage is set aside for the
project and the rest buys the token back and burns it. The split is identical
for a mint, a trading fee and a royalty.

| project share of the hook | share of mint revenue | over the full run |
|---|---|---|
| 30% | 9.0% | 160.8 ETH |
| 40% | 12.0% | 214.4 ETH |
| 50% | 15.0% | 268.0 ETH |
| 60% | 18.0% | 321.7 ETH |

Two properties worth stating plainly for anyone reading this. It is set once at
deployment and is immutable afterwards. And it is back-loaded: 94% of mint
revenue is in epochs 9 and 10, so if the collection stalls at epoch 8 the whole
project share is around 10 ETH regardless of the percentage chosen.

---

## 9. Build order

| phase | work |
|---|---|
| 0 | `weight` field. Rent as a share of price. Keccak miner kernel. Own copy. |
| 1 | Launch: mine, own, burn. Nothing else. Gather real hash-rate data. |
| 2 | Forge to Rare. Forge fee. Recipe page published one week before. |
| 3 | Epic and Legendary. Tier pool. Leaderboard ranked by weight. |
| 4 | Staking for difficulty. |
| 5 | Public trait reader. Named recipes. |

Phase 0 cannot be retrofitted. Everything after phase 2 is optional.

---

## 10. Rules that must not be broken

1. No `$PIXELBOTS` is created by anything other than destroying an NFT.
2. No forge returns more weight than it consumed.
3. No randomness is resolved in the transaction that requested it.
4. No mechanic can take live supply below the floor.
5. Nothing that mints or forges can happen in the same block as the mint it
   depends on. The 600-second gate covers this.
6. The project share and the royalty receiver are immutable after deployment.

---

## For the docs page

> Feed three bots to the forge and one comes back. It keeps their combined rent
> claim and the rarest of their traits, and it mints a third of the tokens that
> burning them outright would have. The collection gets smaller. Your share of
> it does not.
