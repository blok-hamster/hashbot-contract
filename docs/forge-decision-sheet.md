# Forge decision sheet

Every `TO SET` in `contracts/docs/hashbots-forge-mechanics.md`, one row each.
Fill the **value** column with a signed number before any of these mechanics is
written to a contract. Until a row has a value, that mechanic ships nothing —
the doc's own rule (line 6) says a TO SET "has no value yet and needs one
before the contract is written", and this sheet is the place the value lands
so the contract author never has to invent one.

Source of each prescribing rule: the row's doc line, read byte-clean this
session.

| # | mechanic | doc rule | value | signed |
|---|---|---|---|---|
| 1 | forge fee | doc:130 — TO SET, in ETH, paid by the forger; 30% of it goes to the pool |0.0005 | |
| 2 | forge epoch pressure | doc:9 table — every forge must pay the next-mint difficulty floor at least, so forging never produces "cheap" tier upgrades |true| |
| 3 | forge cooldown | doc — TO SET, seconds between forges from one wallet |60 | |
| 4 | stake maximum | doc:200 — TO SET, bits per wallet that can be staked | 8| |
| 5 | minimum lock | doc:201 — TO SET, seconds a stake must stay locked before unstake |86400 | |
| 6 | unstake fee | doc:202 — TO SET, to the rent pool; split 70/30 rent / buyback like a mint (audit sign-off 2016-09-15) |0.0005 | |
| 7 | genesis supply | doc:227 — TO SET, $BOT seeded into the pool at launch; 1,000,000 (Hashcats lore, IMPLEMENTATION_PLAN; audit sign-off 2016-09-15) |1,000,000 | |
| 8 | pool rent split | doc prescribes no share; the doc's only TO SET for the forge is the total fee (line 130). The rent share is its own TO SET. |30% | |
| 9 | forge weight rule | doc:23 table — output takes the rarest input tier; inputs must all be the same tier | true| |

Anything else in the doc marked TO SET belongs in
`src/lib/chain.ts` (doc line 6) and is gated by the same rule.
