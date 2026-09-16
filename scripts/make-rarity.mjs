#!/usr/bin/env node
/**
 * make-rarity.mjs
 *
 * Computes the EXACT effective frequency of every trait by enumerating the
 * derivation space — no sampling, no Monte-Carlo. The derivation space is
 * 18·40·23·74·37·79 = 3.58B tuples, but the reroll structure decomposes:
 *   - bg shown depends only on (derived bg, down, skin): 16,560 combos.
 *   - down shown = derived down (never rerolled).
 *   - skin shown depends only on (b,d,s) and the bg reshuffle result.
 *   - head/mouth/eye shown depend only on (derived head, shown skin).
 *
 * Emits:
 *   - ui/src/lib/rarity.ts  — TRAIT_SHARE (fixed-point ×1e9), RARITY_SCALE,
 *                              selectTraits(), RARITY_TABLE bytes, badge tier.
 *   - contracts/src/libraries/RarityTable.sol — the exact share table as a shared
 *     on-chain library (used by Rarity.sol AND PowBots.sol for forge inheritance).
 *   - contracts/src/Rarity.sol — on-chain rarity oracle (same shares, same math).
 */

import { readFileSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const HANDOFF = join(__dirname, "..", "images", "handoff");
const OUT_TS = join(__dirname, "..", "..", "ui", "src", "lib", "rarity.ts");
const OUT_SOL = join(__dirname, "..", "src", "Rarity.sol");
const OUT_LIB = join(__dirname, "..", "src", "libraries", "RarityTable.sol");

const index = JSON.parse(readFileSync(join(HANDOFF, "chunks", "index.json"), "utf8"));
const manifest = JSON.parse(readFileSync(join(HANDOFF, "manifest.json"), "utf8"));
const chunks = [];
for (let c = 0; c < 8; c++) {
  chunks.push(readFileSync(join(HANDOFF, "chunks", `chunk-${String(c).padStart(2, "0")}.bin`)));
}
const compat = chunks[index[335].chunk].subarray(index[335].off, index[335].off + index[335].len);
const shape = manifest.traits.map((t) => t.shape);

const BG = 18, DOWN = 40, SKIN = 23, HEAD = 74, MOUTH = 37, EYE = 79;
const BS = [0, 90, 142, 355, 462, 690];
const CB = [18, 18, 23, 23, 23];
const AO = [18, 58, 81, 155, 192];
const BO = [0, 0, 58, 58, 58];
const D0 = 18, S0 = 58, H0 = 81, M0 = 155, E0 = 192;
const SCALE = 1_000_000_000;

function compatOk(topTrait, bottomTrait, pair) {
  const a = topTrait - AO[pair];
  const b = bottomTrait - BO[pair];
  const k = a * CB[pair] + b;
  return ((compat[BS[pair] + (k >> 3)] >> (k & 7)) & 1) === 1;
}

function nextColourway(id) {
  const s = shape[id];
  let first = id;
  for (let j = id; j > 0 && shape[j - 1] === s; j--) first = j - 1;
  let last = id;
  for (let j = id + 1; j < 271 && shape[j] === s; j++) last = j;
  return first + ((id - first + 1) % (last - first + 1));
}

function resolve(id, below, pair) {
  let t = id;
  for (let x = 0; x < 200; x++) {
    if (compatOk(t, below, pair)) return t;
    t = nextColourway(t);
  }
  return t;
}

function selectTraits(seed) {
  const bg = Number(seed % 18n);
  const dn = Number((seed >> 8n) % 40n) + D0;
  const sk = Number((seed >> 16n) % 23n) + S0;
  const hd = Number((seed >> 24n) % 74n) + H0;
  const mt = Number((seed >> 32n) % 37n) + M0;
  const ey = Number((seed >> 40n) % 79n) + E0;
  let b = bg;
  for (let x = 0; x < BG; x++) {
    if (compatOk(dn, b, 0) && compatOk(sk, b, 1)) break;
    b = (b + 1) % BG;
  }
  const skr = resolve(sk, b, 1);
  return [b, dn, skr, resolve(hd, skr, 2), resolve(mt, skr, 3), resolve(ey, skr, 4)];
}

// ── Exact enumeration ──────────────────────────────────────────────────────

// Step 1: enumerate (b, d, s) triples → shown bg and shown skin.
// bg shown depends on (b, d, s) via the reshuffle loop.
// skin shown = resolve(skin_global, bg_shown, 1).

const bgCounts = new Uint32Array(BG);   // bg shown id → count (of triples)
const skinCounts = new Uint32Array(SKIN); // skin shown local (0..22) → count

// For head/mouth/eye: for each shown-skin value (23 possible), count how many
// derived head/mouth/eye map to each shown value.
const headCounts = Array.from({ length: SKIN }, () => new Uint32Array(HEAD));
const mouthCounts = Array.from({ length: SKIN }, () => new Uint32Array(MOUTH));
const eyeCounts = Array.from({ length: SKIN }, () => new Uint32Array(EYE));

// Also tally down (should be uniform 40×18×23 per value = 414 each).
const downCounts = new Uint32Array(DOWN);

console.error("Enumerating 16,560 bg/d/s triples…");
const TRIPLES = BG * DOWN * SKIN;
for (let b = 0; b < BG; b++) {
  for (let d = 0; d < DOWN; d++) {
    for (let s = 0; s < SKIN; s++) {
      // Reshuffle bg
      let B = b;
      const dGlobal = d + D0, sGlobal = s + S0;
      for (let x = 0; x < BG; x++) {
        if (compatOk(dGlobal, B, 0) && compatOk(sGlobal, B, 1)) break;
        B = (B + 1) % BG;
      }
      bgCounts[B]++;

      // Resolved skin
      const S = resolve(sGlobal, B, 1) - S0; // local 0..22
      skinCounts[S]++;
      downCounts[d]++;

      // Head: for each of 74 derived heads, resolve against S
      for (let h = 0; h < HEAD; h++) {
        const H = resolve(h + H0, S + S0, 2) - H0;
        headCounts[S][H]++;
      }
      // Mouth: for each of 37 derived mouths
      for (let m = 0; m < MOUTH; m++) {
        const M = resolve(m + M0, S + S0, 3) - M0;
        mouthCounts[S][M]++;
      }
      // Eye: for each of 79 derived eyes
      for (let e = 0; e < EYE; e++) {
        const E = resolve(e + E0, S + S0, 4) - E0;
        eyeCounts[S][E]++;
      }
    }
  }
}

// Step 2: compute exact marginal share per trait.
// bg: share = bgCounts[B] / TRIPLES
// down: share = 1/DOWN (uniform, verify)
// skin: share = skinCounts[S] / TRIPLES
// head: share = sum_S (skinCounts[S] * headCounts[S][H]) / (TRIPLES * HEAD)
// mouth: share = sum_S (skinCounts[S] * mouthCounts[S][M]) / (TRIPLES * MOUTH)
// eye: share = sum_S (skinCounts[S] * eyeCounts[S][E]) / (TRIPLES * EYE)

function exactShare(num, den) {
  // returns floor(num * SCALE / den)
  return Math.floor((Number(num) * SCALE) / Number(den));
}

const shares = new Uint32Array(271);

// bg (id 0..17)
for (let i = 0; i < BG; i++) shares[i] = exactShare(bgCounts[i], TRIPLES);
// down (id 18..57): shown down = derived down, uniform over 40 values.
for (let i = 0; i < DOWN; i++) shares[D0 + i] = exactShare(TRIPLES, TRIPLES * DOWN); // = SCALE/DOWN
// skin (id 58..80)
for (let i = 0; i < SKIN; i++) shares[S0 + i] = exactShare(skinCounts[i], TRIPLES);
// head/mouth/eye: headCounts[S][H] already aggregates per-triple increments,
//  so the marginal count for shown H = sum_S headCounts[S][H]. No skinCounts factor.
// head (id 81..154)
for (let h = 0; h < HEAD; h++) {
  let n = 0n;
  for (let s = 0; s < SKIN; s++) n += BigInt(headCounts[s][h]);
  shares[H0 + h] = Number((n * BigInt(SCALE)) / (BigInt(TRIPLES) * BigInt(HEAD)));
}
// mouth (id 155..191)
for (let m = 0; m < MOUTH; m++) {
  let n = 0n;
  for (let s = 0; s < SKIN; s++) n += BigInt(mouthCounts[s][m]);
  shares[M0 + m] = Number((n * BigInt(SCALE)) / (BigInt(TRIPLES) * BigInt(MOUTH)));
}
// eye (id 192..270)
for (let e = 0; e < EYE; e++) {
  let n = 0n;
  for (let s = 0; s < SKIN; s++) n += BigInt(eyeCounts[s][e]);
  shares[E0 + e] = Number((n * BigInt(SCALE)) / (BigInt(TRIPLES) * BigInt(EYE)));
}

// Sanity: each layer sums to SCALE (within rounding).
for (const [base, count, name] of [[0,BG,"bg"],[D0,DOWN,"down"],[S0,SKIN,"skin"],[H0,HEAD,"head"],[M0,MOUTH,"mouth"],[E0,EYE,"eye"]]) {
  let sum = 0;
  for (let i = base; i < base + count; i++) sum += shares[i];
  console.error(`${name} share sum: ${(sum / SCALE).toFixed(9)} (target 1.000000000)`);
}

// Verify against known deployed seeds.
const KNOWN = [
  ["0xc87341adb5834e8b50a8640431bf1dbf1628898208e016e0d98d43023beb5980", [12, 19, 69, 138, 168, 246]],
  ["0x1817835ce87e2e9ea0de192a77c83ab292e51c581a8bee16231532acb88fe92d", [11, 43, 73, 107, 183, 222]],
];
for (const [seed, want] of KNOWN) {
  const got = selectTraits(BigInt(seed));
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    console.error(`selectTraits mismatch for ${seed.slice(0, 16)}… got ${got}, want ${want}`);
    process.exit(1);
  }
}

// ── Emit rarity.ts ─────────────────────────────────────────────────────────

const V0 = [0, 18, 58, 81, 155, 192];
const LAYER_SIZES = [18, 40, 23, 74, 37, 79];

const selectReplica = `/* selectTraits(seed) — exact replica of HashBotsRenderer.sol.
   Cross-checked against the deployed contract for every known bot seed.
   Called by the UI to map seed → shown trait IDs; the Rarity contract
   (on-chain) does the same internally so both paths always agree. */
export function selectTraits(seed: string | bigint): number[] {
  const s = typeof seed === "bigint" ? seed : BigInt(seed);
  let bg = Number(s % 18n);
  const dn = Number((s >> 8n) % 40n) + ${D0};
  const sk = Number((s >> 16n) % 23n) + ${S0};
  const hd = Number((s >> 24n) % 74n) + ${H0};
  const mt = Number((s >> 32n) % 37n) + ${M0};
  const ey = Number((s >> 40n) % 79n) + ${E0};
  const ao = [${AO}], bo = [${BO}], cb = [${CB}], bs = [${BS}];
  const ok = (T: number, B: number, p: number) =>
    (COMPAT[bs[p] + (((T - ao[p]) * cb[p] + (B - bo[p])) >> 3)] >> ((T - ao[p]) * cb[p] + (B - bo[p]) & 7) & 1) === 1;
  const nxt = (id: number): number => {
    const sh = TRAIT_SHAPE[id]; let f = id, l = id;
    for (let j = id; j > 0 && TRAIT_SHAPE[j - 1] === sh; j--) f = j - 1;
    for (let j = id + 1; j < 271 && TRAIT_SHAPE[j] === sh; j++) l = j;
    return f + ((id - f + 1) % (l - f + 1));
  };
  const res = (id: number, be: number, p: number): number => {
    let t = id;
    for (let x = 0; x < 200; x++) { if (ok(t, be, p)) return t; t = nxt(t); }
    return t;
  };
  for (let x = 0; x < 18; x++) { if (ok(dn, bg, 0) && ok(sk, bg, 1)) break; bg = (bg + 1) % 18; }
  const skr = res(sk, bg, 1);
  return [bg, dn, skr, res(hd, skr, 2), res(mt, skr, 3), res(ey, skr, 4)];
}`;

// Badge tier from rarest layer share.
// rarest = min of the six per-trait shares. A smaller share = rarer.
//  Tiers based on exact enumeration distribution:
//   share ≥ 0.04  → Common   (badge-5)
//   share ≥ 0.02  → Uncommon (badge-4)
//   share ≥ 0.01  → Rare     (badge-3)
//   share ≥ 0.005 → Epic     (badge-2)
//   share < 0.005 → Legendary (badge-1)  — extremely rare, below 0.5%
//   unique       → Mythic   (badge-0)
const BADGE_TIERS = [
  { min: SCALE * 0.04, label: "Common",   tier: 5 },
  { min: SCALE * 0.02, label: "Uncommon", tier: 4 },
  { min: SCALE * 0.01, label: "Rare",     tier: 3 },
  { min: SCALE * 0.005,label: "Epic",     tier: 2 },
  { min: 0,            label: "Legendary",tier: 1 },
];

const rarityTableBytes = Buffer.alloc(271 * 4);
for (let i = 0; i < 271; i++) rarityTableBytes.writeUInt32BE(shares[i], i * 4);

const lines = [
  `// Auto-generated by scripts/make-rarity.mjs — DO NOT EDIT.`,
  `// Exact per-trait frequencies computed by enumerating the derivation space.`,
  `// The companion Rarity.sol contract stores the same table on-chain.`,
  ``,
  `/* Byte-packed compatibility table (record 335 of the renderer). `,
  `   Pair bit-widths: 0=down-bg 18×18, 1=skin-bg 23×18, 2=head-skin 74×23,`,
  `   3=mouth-skin 37×23, 4=eye-skin 79×23. Bit k of the pair's row selects `,
  `   whether trait combination k is allowed. */
export const COMPAT = new Uint8Array([${Array.from(compat).join(",")}]);

/* TRAIT_SHAPE[i] = colourway group of global trait id i; rerolls step to the`,
  `   next trait with the same shape. */
export const TRAIT_SHAPE = ${JSON.stringify(shape)};`,
  ``,
  `export const RARITY_SCALE = ${SCALE};`,
  ``,
  `export const TRAIT_SHARE: Record<number, number> = {`,
];
for (let i = 0; i < 271; i++) lines.push(`  ${i}: ${shares[i] / SCALE},`);
lines.push(`};`);
lines.push(``);
lines.push(`export const LAYER_SIZES = ${JSON.stringify(LAYER_SIZES)};`);
lines.push(`export const TRAIT_LAYER_FIRST = ${JSON.stringify(V0)};`);
lines.push(``);
lines.push(`// Badge tiers from combined oneIn (1/Π share_i). Matching Rarity.sol _tier().`);
lines.push(`// 0=Mythic 1=Legendary 2=Epic 3=Rare 4=Uncommon 5=Common`);
lines.push(`export const BADGE_BANDS = [8_000_000_000, 6_000_000_000, 4_500_000_000, 3_800_000_000, 3_400_000_000] as const;`);
lines.push(`export const BADGE_LABELS = ["Mythic", "Legendary", "Epic", "Rare", "Uncommon", "Common"] as const;`);
lines.push(`/** Tier 0–5 from a oneIn value, matching Rarity.sol._tier(). */`);
lines.push(`export function badgeTier(oneIn: number): number {`);
lines.push(`  for (let i = 0; i < BADGE_BANDS.length; i++) if (oneIn >= BADGE_BANDS[i]) return i;`);
lines.push(`  return 5;`);
lines.push(`}`);
lines.push(selectReplica);
writeFileSync(OUT_TS, lines.join("\n") + "\n");
console.error(`wrote ${OUT_TS}`);

// ── Emit RarityTable.sol (shared on-chain share table) ─────────────────────

const libLines = [
  `// SPDX-License-Identifier: MIT`,
  `pragma solidity ^0.8.24;`,
  ``,
  `/// @title RarityTable — the exact per-trait frequency table as a shared library.`,
  `/// @notice Generated by scripts/make-rarity.mjs — DO NOT EDIT.`,
  `///  Single source of truth for the 271 on-chain trait shares: Rarity.sol reads`,
  `///  them for rarity scoring and PowBots.sol reads them for forge trait`,
  `///  inheritance ("rarest input per slot, tie by lowest token id").`,
  `library RarityTable {`,
  `    uint256 internal constant SCALE = ${SCALE};`,
  ``,
  `    /// @dev Per-trait effective frequency × ${SCALE}, one entry per of the 271`,
  `    ///  on-chain traits (indices 0..270, in bg/down/skin/head/mouth/eye order).`,
  `    bytes internal constant SHARE_TABLE = hex"${rarityTableBytes.toString("hex")}";`,
  ``,
  `    /// @notice Raw share value for a trait (× ${SCALE}).`,
  `    function shareOf(uint256 traitId) internal pure returns (uint256) {`,
  `        require(traitId < 271, "out of range");`,
  `        uint256 off = traitId * 4;`,
  `        return (uint256(uint8(SHARE_TABLE[off])) << 24) |`,
  `               (uint256(uint8(SHARE_TABLE[off+1])) << 16) |`,
  `               (uint256(uint8(SHARE_TABLE[off+2])) << 8) |`,
  `               uint256(uint8(SHARE_TABLE[off+3]));`,
  `    }`,
  `}`,
];
writeFileSync(OUT_LIB, libLines.join("\n") + "\n");
console.error(`wrote ${OUT_LIB}`);

// ── Emit Rarity.sol ────────────────────────────────────────────────────────

const solLines = [
  `// SPDX-License-Identifier: MIT`,
  `pragma solidity ^0.8.24;`,
  ``,
  `import {RarityTable} from "./libraries/RarityTable.sol";`,
  ``,
  `/// @title Rarity — on-chain rarity oracle for HashBots`,
  `/// @notice Stores the exact per-trait effective frequencies computed by`,
  `///  enumerating the renderer's derivation space. Anyone can call oneInOfSeed`,
  `///  or oneInOfToken to verify the rarity value displayed by the UI.`,
  `///  The shares table is immutable (frozen at deploy); the renderer's own`,
  `///  selectTraits() is the source of truth for which traits a bot has.`,
  `contract Rarity {`,
  `    uint256 public constant SCALE = ${SCALE};`,
  `    address public immutable renderer;`,
  `    address public immutable powbots;`,
  ``,
  `    /// @param _renderer HashBotsRenderer address (for selectTraits).`,
  `    /// @param _powbots  PowBots address (for catSeed).`,
  `    constructor(address _renderer, address _powbots) {`,
  `        renderer = _renderer;`,
  `        powbots = _powbots;`,
  `    }`,
  ``,
  `    /// @notice Raw share value for a trait (×${SCALE}).`,
  `    function shareOf(uint256 traitId) external pure returns (uint256) {`,
  `        return RarityTable.shareOf(traitId);`,
  `    }`,
  ``,
  `    struct BotRarity {`,
  `        uint256 oneIn;          // 1 / Π(share_i), integer`,
  `        uint256 rarestShare;    // min share × SCALE`,
  `        uint256 rarestTraitId;  // which trait is rarest`,
  `        uint8   badge;          // 0=Mythic 1=Legendary 2=Epic 3=Rare 4=Uncommon 5=Common`,
  `    }`,
  ``,
  `    /// @notice Full rarity info for a seed. The combined "1 in N" uses the`,
  `    ///  product of the six per-trait shares — the standard NFT rarity metric.`,
  `    ///  oneIn = SCALE^6 / Π(share_i). Max prod = (5.8e7)^6 ≈ 3.8e46, SCALE^6 =`,
  `    ///  1e54, both well below 2^256. badge is tier 0–5 derived from oneIn.`,
  `    function oneInOfSeed(uint256 seed) external view returns (BotRarity memory) {`,
  `        return _rarityOf(seed);`,
  `    }`,
  ``,
  `    /// @notice Same as oneInOfSeed but reads the seed from PowBots.catSeed(tokenId).`,
  `    function oneInOfToken(uint256 tokenId) external view returns (BotRarity memory) {`,
  `        return _rarityOf(_catSeed(tokenId));`,
  `    }`,
  ``,
  `    /// @notice Full rarity of an explicit trait set (e.g. a forged output's`,
  `    ///  inherited traits). oneIn is the same 1 / Π(share_i) as oneInOfSeed.`,
  `    function rarityOfTraits(uint256[6] memory t) external view returns (BotRarity memory) {`,
  `        return _rarityOfTraits(t);`,
  `    }`,
  ``,
  `    // ── Internal ────────────────────────────────────────────────────────────`,
  ``,
  `    function _rarityOf(uint256 seed) internal view returns (BotRarity memory r) {`,
  `        return _rarityOfTraits(_selectTraits(seed));`,
  `    }`,
  ``,
  `    function _rarityOfTraits(uint256[6] memory t) internal view returns (BotRarity memory r) {`,
  `        uint256 prod = 1;`,
  `        for (uint256 i = 0; i < 6; i++) prod *= RarityTable.shareOf(t[i]);`,
  `        r.oneIn = SCALE ** 6 / prod;`,
  `        r.rarestShare = SCALE;`,
  `        for (uint256 i = 0; i < 6; i++) {`,
  `            uint256 s = RarityTable.shareOf(t[i]);`,
  `            if (s < r.rarestShare) {`,
  `                r.rarestShare = s;`,
  `                r.rarestTraitId = t[i];`,
  `            }`,
  `        }`,
  `        r.badge = _tier(r.oneIn);`,
  `    }`,
  ``,
  `    /// @dev Badge tier 0–5 derived from oneIn, matching the UI's badge bands.`,
  `    ///  0=Mythic(≥8B) 1=Legendary(6B) 2=Epic(4.5B) 3=Rare(3.8B) 4=Uncommon(3.4B) 5=Common`,
  `    function _tier(uint256 oneIn) internal pure returns (uint8) {`,
  `        if (oneIn >= 8_000_000_000) return 0;`,
  `        if (oneIn >= 6_000_000_000) return 1;`,
  `        if (oneIn >= 4_500_000_000) return 2;`,
  `        if (oneIn >= 3_800_000_000) return 3;`,
  `        if (oneIn >= 3_400_000_000) return 4;`,
  `        return 5;`,
  `    }`,
  ``,
  `    function _catSeed(uint256 tokenId) internal view returns (uint256) {`,
  `        (bool ok, bytes memory data) = powbots.staticcall(`,
  `            abi.encodeWithSignature("catSeed(uint256)", tokenId)`,
  `        );`,
  `        require(ok, "catSeed failed");`,
  `        return abi.decode(data, (uint256));`,
  `    }`,
  ``,
  `    function _selectTraits(uint256 seed) internal view returns (uint256[6] memory t) {`,
  `        (bool ok, bytes memory data) = renderer.staticcall(`,
  `            abi.encodeWithSignature("selectTraits(uint256)", seed)`,
  `        );`,
  `        require(ok, "selectTraits failed");`,
  `        return abi.decode(data, (uint256[6]));`,
  `    }`,
  `}`,
];
writeFileSync(OUT_SOL, solLines.join("\n") + "\n");
console.error(`wrote ${OUT_SOL}`);

// ── Summary ────────────────────────────────────────────────────────────────
let mn = Infinity, mx = -Infinity, mnId = -1, mxId = -1;
for (let i = 0; i < 271; i++) {
  if (shares[i] < mn) { mn = shares[i]; mnId = i; }
  if (shares[i] > mx) { mx = shares[i]; mxId = i; }
}
console.error(`share range: ${(mn/SCALE).toFixed(6)} @${mnId} – ${(mx/SCALE).toFixed(6)} @${mxId}  (1/${Math.round(SCALE/mn)} – 1/${Math.round(SCALE/mx)})`);
