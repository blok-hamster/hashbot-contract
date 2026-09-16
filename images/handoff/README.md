# Hashbots trait data, for the contract

Everything the contract needs to draw all 271 traits is in this folder.
There are no other dependencies: no IPFS, no server, no image library, no
drawing done on chain, and no off-chain call at any point after deploy.

## Start here

The short version, if you read nothing else:

- A bot is **six indexed PNGs stacked as `<image>` layers inside one SVG**. The
  browser composites them. The contract never touches a pixel.
- Each PNG is **six byte strings concatenated**. Four are constants. Two are
  read from storage. There is no encoder to write and no CRC to compute.
- The 8 files in `chunks/` are the only thing deployed as bytes. Deploy
  each with SSTORE2, in order, and keep the addresses.
- `manifest.json` and `chunks/index.json` are **not** deployed as written. The
  information in them is, packed into four flat arrays. See *The lookup table*.
- Some trait combinations are unreadable. Every pair was judged offline; the
  answers are one bit each, already in the chunks. See *The legibility rule*.

Suggested reading order: *What to deploy*, then *Reading the files*, then *How
a token image is built*, then *The legibility rule*. The rest is context.

Anything here that looks like an arbitrary choice &mdash; the layer order, the
threshold, the missing uniqueness check &mdash; has a section explaining what it
was measured against. Please read that section before changing it.

## What to deploy

**The folder is bigger than the deploy.** Three numbers, because confusing them
is expensive:

    the 17 data files here    347,309 bytes   send all of them
    the 8 chunk files         169,944 bytes   deploy verbatim
    the lookup table           ~1,975 bytes   you build this, see below

(plus this README and the checksums, a few KB more on disk and nothing on chain.)

Most of the difference is `manifest.json`, `chunks/index.json` and the four
sample SVGs. The samples are there to be looked at and deploy nothing. The two
JSON files do not deploy either — but the information in them does, in a much
smaller form.

### The chunks

8 files, 169,944 bytes, roughly 34.0M gas at 200 gas/byte plus
per-transaction overhead. Each chunk is one SSTORE2 deploy. Every chunk is under
the 24,576 byte EIP-170 limit on deployed code, which is why there are 8
of them rather than one. Store the address each deploys to, in order.

### The lookup table

The chunks hold pixels, palettes and the legibility bits. They do not hold the
answer to "where is trait 214's palette", and the contract needs that answer
before it can concatenate anything. That mapping is `manifest.json` plus
`chunks/index.json`, and it has to go on chain in some form.

**Do not store the JSON.** Verbatim it is 55,603 bytes, about 11.1M gas, to say
what packs into 1,975 bytes. The other 10.7M gas would buy key names, commas
and numbers spelled out in ASCII. Packed, it is four flat arrays:

     336 record offsets   3 bytes each, from the start of the concatenated data
     336 record lengths   2 bytes each, largest record is 10,998 bytes
     271 shape indices    1 byte  each, 64 distinct shapes
       8 chunk starts     3 bytes each, to turn a global offset into (address, offset)

Records are in `index.json` order: shapes 0 to 63, then palettes 0 to
270, then compat. Palette *i* belongs to trait *i*, so no separate
trait-to-palette map is needed. Shape indices come from
`manifest.traits[i].shape`.

### So the real bill

    art        169944 bytes   33.99M gas
    lookup       1975 bytes   0.40M gas
    total      171919 bytes   34.38M gas

The lookup table is 1.1% of the bytes. It is called out separately not
because it is large but because it is the part that is easy to miss when
budgeting, and easy to overpay for by an order of magnitude.

## Every file here

| file | bytes | what it is |
|---|---|---|
| `chunks/chunk-00.bin` | 23,087 | deploy this, one transaction each |
| `chunks/chunk-01.bin` | 23,020 | deploy this, one transaction each |
| `chunks/chunk-02.bin` | 23,337 | deploy this, one transaction each |
| `chunks/chunk-03.bin` | 22,409 | deploy this, one transaction each |
| `chunks/chunk-04.bin` | 21,915 | deploy this, one transaction each |
| `chunks/chunk-05.bin` | 24,100 | deploy this, one transaction each |
| `chunks/chunk-06.bin` | 24,552 | deploy this, one transaction each |
| `chunks/chunk-07.bin` | 7,524 | deploy this, one transaction each |
| `chunks/index.json` | 18,661 | where each record lives; pack this, do not deploy the JSON |
| `manifest.json` | 36,942 | which shape and palette each trait uses; pack this too |
| `compat.json` | 571 | legibility pairs, threshold and table sizes |
| `names.json` | 47,493 | trait_type and value per trait, for tokenURI attributes |
| `NAMES.md` | 11,618 | the same names as a table, for reading rather than parsing |
| `sample/bot-1.svg` | 16,651 | one finished bot, exactly what tokenURI returns inside its data URI |
| `sample/bot-2.svg` | 17,151 | one finished bot, exactly what tokenURI returns inside its data URI |
| `sample/bot-3.svg` | 14,463 | one finished bot, exactly what tokenURI returns inside its data URI |
| `sample/bot-4.svg` | 13,815 | one finished bot, exactly what tokenURI returns inside its data URI |

`SHA256SUMS.txt` covers all of the above.

## Reading the files

Every field, so none of this has to be inferred from the values.

### `manifest.json`

| field | what it is |
|---|---|
| `width`, `height` | 165 and 165. Every trait is this size. No trait is offset or cropped. |
| `layers` | the 6 layer names, **in painting order**, index 0 painted first |
| `shapes` | 64, the number of distinct pixel blocks |
| `shapeOffsets` | `[offset, length]` per shape, into the concatenated shape data |
| `traits` | 271 records, described below. **The array index is the trait id.** |
| `constants` | the four fixed PNG chunks, as hex. See *How a token image is built*. |

Each entry in `traits`:

| field | what it is |
|---|---|
| `layer` | index into `layers`. Not a name &mdash; 0=bg, 1=down, 2=skin, 3=head, 4=mouth, 5=eye. |
| `name` | the artist's filename. For your logs and for matching `names.json`. Not used at render time. |
| `shape` | index into `shapeOffsets`. Several traits share one shape; that is the colourway mechanism and is not a bug. |
| `plte` | `[offset, length]` into the concatenated palette data. **Palette *i* belongs to trait *i***, so this is redundant with the index and is here for checking. |
| `src` | `original` or `generated`. Provenance only; ignore it. |

Trait ids are **global, not per layer**. Trait 18 is the first `down`, not
the second `bg`. To roll a layer you need the id range for that layer,
which is contiguous: the traits array is sorted by layer.

    layer     first id   count
    bg             0      18
    down          18      40
    skin          58      23
    head          81      74
    mouth        155      37
    eye          192      79

### `chunks/index.json`

336 records, one per stored blob, in the order they are concatenated.

| field | what it is |
|---|---|
| `kind` | `shape`, `plte` or `compat` |
| `id` | the index within that kind: shape *n*, palette for trait *n*, compat table *n* |
| `chunk` | which `chunk-NN.bin` holds it, 0-based |
| `off` | byte offset **within that chunk**, not global |
| `len` | length in bytes |

Counts: 64 shape, 271 plte, 1 compat. So to fetch a record you need the
deployed address of `chunk[chunk]` and then `SSTORE2.read(addr, off, off + len)`.
That is the whole access path; there is no indirection beyond it.

### `compat.json`

The legibility answers, described in *The legibility rule* below. `pairs` is
the list of layer pairs that were judged, `counts` is traits per layer, `sizes`
gives the byte length of each pair's table, and `threshold`, `margin` and
`minOverlap` record how the judgement was made. The **bits themselves are in
the chunks**, not in this JSON.

### `names.json`

`layers` maps a layer key to its display name. `traits` is one record per
trait, with `file` (matching `manifest.traits[i].name`), `trait_type` and
`value`. These are the strings a marketplace shows and ranks rarity from.

All 271 values are distinct. That is deliberate and was expensive: traits
that shared a name, or that had different names but looked the same, were cut
rather than renamed. Two ids with one name would show as one trait on a rarity
board while being priced as two.

Where the names live on chain is your call. They are not in the chunks. The
reference collection keeps its names in the renderer's own storage, which is
one option and not the only one.

## How a token image is built

A bot is six PNGs stacked as `<image>` layers inside an SVG. The browser does
the compositing. The contract does not composite anything.

Each PNG is built by concatenating six byte strings, in this order:

    signature + IHDR + PLTE + tRNS + IDAT + IEND

Four of those never change and are constants you can embed directly:

    signature  89504e470d0a1a0a
    IHDR       0000000d49484452000000a5000000a508030000000af5cde8
    tRNS       0000000174524e530040e6d866
    IEND       0000000049454e44ae426082

The other two come from storage:

  - **PLTE** is the `plte` record for that trait: `manifest.traits[i].plte`
    gives `[offset, length]` into the palette data.
  - **IDAT** is the shape it uses: `manifest.traits[i].shape` is an index into
    `manifest.shapeOffsets`, which gives `[offset, length]`.

**These records are complete PNG chunks already.** Length, type, payload and
CRC, all present. Do not wrap them in another chunk header and do not compute a
CRC — concatenate the bytes and stop. That is the entire renderer.

271 traits share only 64 distinct shapes, because a colourway has the
same pixels as the drawing it came from and differs only in its palette. That
sharing is why the whole set fits in 166 KB.

The image is 165 x 165, colour type 3 (indexed), bit depth 8. Palette slot 0
is transparent, which is what the one-byte tRNS says.

### One trait, all the way through

Trait 226, `eye/eye 15-c.png`, to make the indirection concrete:

    manifest.traits[226].shape  = 53
    manifest.traits[226].plte   = [29580, 36]

    index.json record { kind: "shape", id: 53 }  -> chunk 5, off 21012, len 180
    index.json record { kind: "plte",  id: 226 }  -> chunk 7, off 5028, len 36

    IDAT = SSTORE2.read(chunkAddr[5], 21012, 21192)
    PLTE = SSTORE2.read(chunkAddr[7], 5028, 5064)

    png  = sig + ihdr + PLTE + trns + IDAT + iend

The first bytes of each confirm you are in the right place: the palette record
begins `00 00 00 18 PLTE` &mdash; a big-endian length of 24, then `PLTE` &mdash; and the
shape record begins `00 00 00 a8 IDAT`, a length then `IDAT`. If what you read does
not start with the chunk type, the offsets are wrong and nothing downstream
will tell you so.

Then base64 the PNG, wrap it, and stack 6 of them:

    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 165 165"
         shape-rendering="crispEdges">
      <image width="165" height="165" style="image-rendering:pixelated"
             href="data:image/png;base64,..."/>
      ... one per layer, bg first, eye last ...
    </svg>

`shape-rendering="crispEdges"` and `image-rendering:pixelated` both matter, and
both are needed: without them the browser smooths the pixels when the SVG is
scaled up and the art stops being pixel art. The four files in `sample/` are
exactly this, so diff against them if a bot comes out looking wrong.

## Layer order

    bg -> down -> skin -> head -> mouth -> eye

Last is on top. `bg` is painted first, `eye` last. This order is not arbitrary
and should not be changed: it was measured against the artist's own finished
bots. Getting it wrong puts trailing items in front of the torso and masks in
front of visors.

Trait counts per layer, and what each layer costs to store:

    layer   traits     bytes    share
    bg        18    118667    69.8%
    down      40      6328     3.7%
    skin      23     24370    14.3%
    head      74      6426     3.8%
    mouth     37      5927     3.5%
    eye       79      7475     4.4%

    compat             690     0.4%
    shared              61     0.0%

Trait count and storage cost are not the same ranking, and that is worth
knowing before anyone asks for more art. `bg` is 18 of 271 traits and 70% of
the bytes, because backgrounds are full-canvas and compress badly. A face part
covering a few hundred pixels is nearly free.

The "shared" row is one shape charged to no single layer, because it is used
by more than one: `head/head 3.png` and `mouth/mouth 4.png`.
Every trait involved is fully transparent — these are the
deliberately empty options, a bot that has no headgear and a bot that has no
mouthpiece. Empty in one layer is the same 165 x 165 of nothing as empty in
another, so it is stored once. One shape index appearing under two layers is
correct, not a bug.

Keep the empty traits. They are what makes a bare-faced bot possible, and at
61 bytes for all of them they cost nothing.

## The legibility rule

Some trait combinations are unreadable: a dark visor on a dark face. Judging
colour on chain is expensive, so every pair was judged offline and the answers
are stored as one bit each, in `compat`.

| pair | combinations | bytes |
|---|---|---|
| `down` over `bg` | 40 x 18 | 90 |
| `skin` over `bg` | 23 x 18 | 52 |
| `head` over `skin` | 74 x 23 | 213 |
| `mouth` over `skin` | 37 x 23 | 107 |
| `eye` over `skin` | 79 x 23 | 228 |

Threshold 20.7 with a margin of 0.2 in CIE76 dE, over a minimum overlap of
300 pixels. Bit set means the pair is fine.

Only these 5 pairs are stored, because only these 5 can obscure each
other. `head`, `mouth` and `eye` are judged against `skin` and not against
`bg`, because the chassis is behind all three wherever they are drawn.

### Reading a bit

Each table is a flat bitmap, the top layer's trait index as the outer loop:

    k = a * counts[bottom] + b          // a, b are per-layer indices, not global ids
    ok = (table[k >> 3] >> (k & 7)) & 1

Per-layer indices, not the global trait ids from `manifest.traits`. Subtract
the layer's first id, from the table in *Reading the files*. Table lengths are
`ceil(counts[top] * counts[bottom] / 8)`, which is what check 5 confirms.

### The rule at mint time

    roll one trait per layer from the hash

    // 1. background first. A background is scenery; moving it costs the bot
    //    nothing, so it yields to both body layers rather than either yielding.
    while (!ok(down, bg) || !ok(skin, bg))
        bg = (bg + 1) % counts[bg]

    // 2. then each layer above it, in painting order. The drawing never
    //    changes, only which colourway of it is used, so rarity is untouched.
    for (layer of [skin, head, mouth, eye])
        while (!ok(layer, beneath(layer)))
            layer = nextColourwayOfSameDrawing(layer)

A bit lookup and a branch. No colour maths on chain, no loops over pixels.

**Both loops terminate, and that is checked rather than hoped for.**

Step 1: all 920 `(down, skin)` pairs have a legible background, and the
worst-off pair still has 16 of 18 to choose from. So the loop cannot run
past one lap, and usually stops on the first or second step.

Step 2: **every drawing has at least one colourway that clears every backdrop
it can land on.** Proven over all 5,504 judged pairs, exhaustively, not
sampled. A zero there means it cannot happen, not that it has not happened yet.

If you change the trait set, both of these have to be rechecked. The first is
re-derived every time this folder is packaged and will refuse to package a set
that fails it; the second is `scripts/probe-guarantee.mjs` on our side.

`nextColourwayOfSameDrawing` needs to know which ids are siblings. They are
contiguous in `manifest.traits` &mdash; a drawing is immediately followed by its
colourways &mdash; and they are the ids sharing one `shape`. Either works; the
`shape` field is the one that cannot drift.

Turned off, **11.5% of raw rolls** contain at least one trait you cannot
make out against what is behind it. That figure is computed from the shipped
bytes: the five pairs share only `bg` and `skin`, so with those fixed the rest
are independent and the whole space factorises exactly. It is not a sample.

Turned on, it removes every clash these tables can see, which is what makes it
worth the two reads. It is not a claim that every bot looks good &mdash; the
threshold is a legibility floor, not a taste filter.

## Decisions already made, and why

These are settled, not open. They are written down because each one looks like
an oversight if you find it without the reasoning.

### Uniqueness is deliberately not enforced

There is no on-chain check that two bots differ, and one should not be added.

There are 3,581,961,120 possible combinations against a supply of
16,376. The cost of a collision:

       minted     twin pairs   chance of one
        1,000         0.0001           0.01%
        2,500         0.0009           0.09%
        5,000         0.0035           0.35%
       10,000         0.0140           1.39%
       16,376         0.0374           3.67%

A uniqueness rule is a storage read and a storage write **on every mint**, paid
by every minter, to insure a 3.67% chance of one duplicate pair that
only materialises at full sell-out. That is a bad trade, and it was made
knowingly. If it is added later it has to run **after** the legibility swap,
not before: the swap moves traits, so two different rolls can settle onto the
same bot.

What makes that arithmetic trustworthy is check 6 below: no two traits draw the
same picture. That was false until recently &mdash; twelve traits were pixel copies
of another trait, which would have overstated the real variety by billions and
priced two rarities for one image.

### The trait set was cut, not padded

The set went from 335 traits to 271: **65 removed, 1 added**. The 65 were the
same trait twice &mdash; colourways so close that no buyer would see a difference,
plus a few exact pixel copies. The 1 is a genuinely new colour, added because
cutting a duplicate happened to remove the only colourway of one drawing that
cleared five of the chassis, and the guarantee in *The legibility rule* has to
stay at zero. Fewer combinations, all of them real.

Please do not restore anything from an older build to raise the combination
count. The number in this README is the honest one.

### Two more, covered above

The **layer order** was measured against the artist's finished bots rather than
chosen, and the **fully transparent traits** are bots with no headgear or no
mouthpiece rather than missing files. Both are under *Layer order*.

## Still open

**Backgrounds are 70% of the payload for 7% of the traits.** They are
smooth gradients stored as pixels, which is the worst way to store a smooth
gradient. As SVG `radialGradient` elements they fit to about 3 parts in 255,
and the layer drops from 116 KB to roughly 15 KB &mdash; about
21M gas saved, and 8 chunks down to about 3.

It is not free: the renderer gains a second code path, because a gradient
background is an SVG element rather than an `<image>`, and the `bg` rows of the
legibility tables would be rebuilt against the refitted colours. **Tell us
before you start**, because it changes what gets stored and is far cheaper to
decide now than after deploy.

## What is not here, on purpose

- **The artist's PNGs.** Not needed to render; needed to verify check 4, which
  is ours to run. Ask if you want them.
- **Any Solidity.** The renderer is short enough that writing it against this
  README is cleaner than being handed ours to adapt.
- **A `tokenURI` implementation or a metadata schema.** `names.json` has the
  strings; how you assemble them is your call.
- **Addresses.** Nothing has been deployed.
- **The gallery, the viewer and the unsplit blobs.** They live in our build
  directory. Everything you need is in this folder and nothing you need is
  outside it.

## What has already been checked

`scripts/verify-handoff.mjs` was run on 2026-09-13 and passed. It
reads nothing but these files — not the build directory, not the encoder's
memory — and establishes six things:

1. the 8 chunks reassemble, via `index.json` alone, into the three blobs
2. no chunk exceeds the 24,576 byte limit on deployed code
3. every byte of every chunk is referenced by some record, so nothing is
   being paid for that nobody reads
4. all 271 traits rebuild from the chunk bytes and match the artist's
   originals pixel for pixel — 262 exactly, 9 off by at most 2 of 255
   from palette quantising, all of those backgrounds
5. the legibility tables are exactly the size their pair counts require
6. the 271 traits draw 270 distinct pictures — no trait is a copy of
   another, the one repeat being the deliberately blank trait that
   head/head 3.png and mouth/mouth 4.png share

Check 4 needs the artist's PNGs, which are not in this folder, so it is ours to
run and not yours. The rest are self-contained: if you want to confirm the
bytes independently before spending gas, checks 1 to 3 and 5 need only what is
here, plus `SHA256SUMS.txt` to confirm nothing changed in transit.
