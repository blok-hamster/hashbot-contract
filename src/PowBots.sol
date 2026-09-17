// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IHashToken} from "./interfaces/IHashToken.sol";
import {IPool} from "./interfaces/IPool.sol";
import {EpochMath} from "./libraries/EpochMath.sol";
import {KeccakPacked} from "./libraries/KeccakPacked.sol";
import {Base64} from "./libraries/Base64.sol";
import {PowBotsLib} from "./libraries/PowBotsLib.sol";
import {RarityTable} from "./libraries/RarityTable.sol";
import {HashBotsRenderer} from "./HashBotsRenderer.sol";

/// @title HashBots — a Hashcats-style PoW NFT collection.
/// @dev A bot exists only when someone finds keccak256(miner, nonce, prevWork, anchor) below
///      the moving on-chain target and pays the epoch entry price. No premint, no allowlist,
///      no admin keys that can mint. See docs/IMPLEMENTATION_PLAN.md + docs/BUILD_SPEC.md.
contract PowBots is ERC721, ERC2981, Ownable, ReentrancyGuard {
    // ── Difficulty ─────────────────────────────────────────────────────────────
    uint256 public constant MAX_FLOOR_BITS   = 26; // full difficulty floor at epoch 0
    uint256 public constant RETARGET_WINDOW  = 8;  // mints per retarget
    uint256 public constant TARGET_INTERVAL  = 10; // target seconds per bot
    uint256 public constant MAX_RETARGET_UP  = 2;  // 2x harder per window
    uint256 public constant MAX_RETARGET_DOWN = 4; // 4x easier per window
    uint256 public constant BURST_SHIFT_CAP  = 16; // max streak multiplier (bits)
    uint256 public constant BURST_COOL       = 60; // seconds per burst bit to cool
    uint256 public constant FAILSAFE_MAX     = 20; // idle windows before difficulty halve
    uint256 public constant WALL_FROM_CAP    = 16376; // production wall kick-in
    uint256 public constant WALL_DIV_DEFAULT = 200;

    // ── Mining ─────────────────────────────────────────────────────────────────
    uint256 public constant ANCHOR_WINDOW = 250; // blocks a solution stays valid
    uint256 public constant ROLL_PERIOD   = 300; // 5-min bucket for traits/seed
    uint256 public constant UNIQUE_WINDOW_CAP = 1024; // production window between uniques
    uint256 public constant UNIQUE_TOTAL_CAP  = 16;

    // ── Econ ───────────────────────────────────────────────────────────────────
    uint256 public constant BURN_BASE         = 1000; // $BOT per burn (in own epoch)
    uint256 public constant BURN_DELAY        = 600;  // seconds before burn allowed
    uint256 public constant RENT_BPS          = 6000; // 60% of mint -> general holders
    uint256 public constant TREASURY_BPS      = 700;  // 7% of mint -> treasury
    uint256 public constant STAKE_RENT_BPS    = 300;  // 3% of mint -> staked bot bonus pool
    uint256 public constant HOOK_BPS          = 3000; // 30% of mint -> buyback pool
    uint256 public constant RENT_PRECISION    = 1e6;
    uint256 public constant TREASURY_RENT_BPS = 1000; // retained for backwards compatibility
    uint256 public constant CLAIM_TAX_BPS     = 200;  // 2% tax on rent claim → treasury

    // ── Forge ─────────────────────────────────────────────────────────────────
    uint256 public constant FORGE_FEE      = 0.0005 ether; // decision sheet row 1, doc:130
    uint256 public constant FORGE_REWARD   = 1000e18;      // $BOT per forge, flat, doc:129
    uint256 public constant FORGE_COOLDOWN = 60;           // decision sheet row 3
    uint256 public constant FORGE_AGE_GATE = 600;          // doc:132 — inputs must be this old
    uint256 public constant FORGE_LOCK     = 24 hours;     // doc:133 — output can't sell/forge 24h
    uint256 public constant FORGE_ID_START = 100001;       // above the mint id space (wall caps at 16,376)

    // ── Staking ───────────────────────────────────────────────────────────────
    uint256 public constant STAKE_MAX_BITS = 8;     // decision sheet row 4, doc:200
    uint256 public constant STAKE_REWARD_PRECISION = 1e18;

    uint256 public immutable supplyFloor; // production 4096 (doc:134); configurable for tests

    IHashToken public immutable bot;
    IPool public immutable pool;
    HashBotsRenderer public renderer;

    // Configurable at deploy (defaults to the production constants in Deploy.s.sol).
    uint256 public immutable wallFrom;
    uint256 public immutable wallDiv;
    uint256 public immutable uniqueWindow;
    uint256 public immutable uniqueTotal;

    // ── State ──────────────────────────────────────────────────────────────────
    uint256 public totalMinted;
    uint256 public currentEpoch;
    uint256 public floorBits; // difficulty floor = floorBits + currentEpoch
    uint256 public baseTarget;   // pre-burst target
    uint256 public currentTarget; // baseTarget >> networkBurst (informational)
    uint256 public networkBurst;  // stored; caller-relevant value is effectiveNetworkBurst()
    uint256 public lastBurstAt;
    uint256 public lastMintTime;
    uint256 public lastRetargetMinted;
    uint256 public windowStartTime;
    uint256 public lastWork; // exact winning hash of the previous bot (chains everything)
    uint256 public aliveCount;
    uint256 public burnedCount;
    uint256 public uniquesTaken;
    uint256 public rentPerWeight; // rent accrued per unit of weight, scaled by RENT_PRECISION
    uint256 public totalWeight;   // sum of catWeight over all live bots
    uint256 public forgeCount;    // forge outputs created
    uint256 public treasuryCollected; // accumulated treasury rent share (withdrawable)

    uint256 public inviteUntil;
    mapping(bytes32 => bool) public validInviteHashes;
    mapping(address => bool) public isInvited;

    /// @notice Helper to check whether invite code gating is currently active based on timestamp.
    function isInviteGated() public view returns (bool) {
        return inviteUntil != 0 && block.timestamp < inviteUntil;
    }

    /// @notice Backwards-compatible getter returning true if invite gating is currently active.
    function inviteGated() external view returns (bool) {
        return isInviteGated();
    }

    mapping(address => uint256) public personalBurst;
    mapping(address => uint256) public personalLastMint;

    mapping(uint256 => uint256) public catSeed;
    mapping(uint256 => address) public catMiner;
    mapping(uint256 => uint256) public catDepth;
    mapping(uint256 => uint256) public catMintTime;
    mapping(uint256 => uint256) public catPricePaid;
    mapping(uint256 => bool) public catBurned;
    mapping(uint256 => address) public catBurnedBy;
    mapping(uint256 => bool) public catUnique;
    mapping(uint256 => uint256) public collectedScaled;
    mapping(uint256 => uint256) public catWeight;   // 1/3/9/27 — common/rare/epic/legendary
    mapping(uint256 => bool) public catForged;      // created by forge: traits stored, no seed
    mapping(uint256 => uint256) public catEpoch;    // stored epoch for forged tokens
    mapping(uint256 => bool) public forgeLocked;    // 24h lock on forge outputs
    mapping(address => uint256) public lastForgeAt; // per-wallet forge cooldown
    mapping(uint256 => uint256[6]) internal catForgeTraits; // explicit traits of forged tokens

    // ── Staking state ───────────────────────────────────────────────────────
    mapping(uint256 => bool) public staked;             // true if token is staked
    mapping(uint256 => uint256) public stakeUnlock;     // block.timestamp when unstake becomes available
    mapping(address => uint256) public stakedCount;     // staked bots per wallet (1 bit each)
    mapping(uint256 => uint256) public stakedShareWeight; // frozen share weight at stake time
    mapping(uint256 => uint256) public stakeLockDays;   // lock term chosen (7/30/90)
    uint256 public totalStakedShareWeight;               // sum of all frozen share weights
    uint256 public stakeRewardPerWeight;                 // accumulated reward per unit share weight
    mapping(uint256 => uint256) public stakeRewardCollected; // reward already claimed per tokenId

    // ── Events ─────────────────────────────────────────────────────────────────
    event CatMined(
        uint256 indexed tokenId, address indexed miner, uint256 seed, uint256 work,
        uint256 target, uint8 unique
    );
    event CatBurned(uint256 indexed tokenId, address indexed burner, uint256 tokensOut);
    event Retargeted(uint256 oldBaseTarget, uint256 newBaseTarget);
    event UniqueDrawn(uint256 tokenId, address miner);
    event PaceChanged(uint256 newBaseTarget);
event RentClaimed(uint256 indexed tokenId, address indexed holder, uint256 amount);
    event Forged(uint256 indexed outId, uint256 indexed a, uint256 indexed b, uint256 c, address forger, uint256 weight, uint256 fee);
    event RendererSet(address indexed renderer);
    event Staked(uint256 indexed tokenId, address indexed staker, uint256 lockDays, uint256 shareWeight);
    event Unstaked(uint256 indexed tokenId, address indexed staker);
    event StakeRewardClaimed(uint256 indexed tokenId, address indexed staker, uint256 payout, uint256 penalty);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event InviteGatedSet(bool enabled);
    event InviteUntilSet(uint256 timestamp);
    event InviteCodeAdded(bytes32 indexed codeHash);
    event InviteCodeRevoked(bytes32 indexed codeHash);
    event AddressInvited(address indexed account, bool status);
    event InviteRedeemed(address indexed miner, bytes32 indexed codeHash);

    constructor(
        string memory name_,
        string memory symbol_,
        IHashToken _bot,
        IPool _pool,
        uint256 _initialFloorBits,
        uint256 _wallFrom,
        uint256 _wallDiv,
        uint256 _uniqueWindow,
        uint256 _uniqueTotal,
        uint256 _supplyFloor
    ) ERC721(name_, symbol_) Ownable(msg.sender) {
        require(_initialFloorBits <= MAX_FLOOR_BITS, "E01");
        require(_wallFrom <= WALL_FROM_CAP, "E02");
        require(_wallDiv > 0, "E03");
        require(_uniqueWindow > 0, "E04");
        require(_uniqueTotal <= UNIQUE_TOTAL_CAP, "E05");
        bot = _bot;
        pool = _pool;
        wallFrom = _wallFrom;
        wallDiv = _wallDiv;
        uniqueWindow = _uniqueWindow;
        uniqueTotal = _uniqueTotal;
        supplyFloor = _supplyFloor;
        floorBits = _initialFloorBits;
        baseTarget = _bitsToTarget(_initialFloorBits);
        currentTarget = baseTarget;
        lastMintTime = block.timestamp;
        windowStartTime = block.timestamp;
        lastBurstAt = block.timestamp;

        // Default 5% royalty on secondary sales (ERC-2981)
        _setDefaultRoyalty(msg.sender, 500);
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    function _bitsToTarget(uint256 bits) internal pure returns (uint256) {
        return PowBotsLib.bitsToTarget(bits);
    }

    function _targetToBits(uint256 target) internal pure returns (uint256) {
        return PowBotsLib.targetToBits(target);
    }

    function _bitLength(uint256 x) internal pure returns (uint256) {
        return PowBotsLib.bitLength(x);
    }

    function epochFloor(uint256 epoch) public view returns (uint256) {
        return _bitsToTarget(floorBits + epoch);
    }

    function epochOf(uint256 tokenId) public view returns (uint256) {
        // Mined bots use the pure id->epoch schedule; forge outputs carry the
        // epoch that existed when they were forged.
        return catForged[tokenId] ? catEpoch[tokenId] : EpochMath.epochOfToken(tokenId);
    }

    function mintPrice() public view returns (uint256) {
        return EpochMath.mintPrice(currentEpoch);
    }

    function uniquesRemaining() public view returns (uint256) {
        return uniqueTotal - uniquesTaken;
    }

    function effectiveNetworkBurst() public view returns (uint256) {
        return _burstDecay(networkBurst, lastBurstAt);
    }

    function _burstDecay(uint256 stored, uint256 lastAt) internal view returns (uint256) {
        return PowBotsLib.burstDecay(stored, lastAt, BURST_COOL);
    }

    /// @dev Bits of mining difficulty a wallet has cancelled by staking. Each locked
    ///      bot is 1 bit off its holder's personal streak (doc:198), capped at the
    ///      signed maximum, decision sheet row 4.
    function stakeBits(address miner) public view returns (uint256) {
        uint256 n = stakedCount[miner];
        return n > STAKE_MAX_BITS ? STAKE_MAX_BITS : n;
    }

    /// @dev Personal difficulty contribution after staking: burst minus staked bits,
    ///      clamped at zero. A freshly-staked wallet mines at the base personal rate.
    function effectivePersonalBurst(address miner) public view returns (uint256) {
        uint256 burst = _burstDecay(personalBurst[miner], personalLastMint[miner]);
        uint256 eased = stakeBits(miner);
        return burst > eased ? burst - eased : 0;
    }

    /// @dev Personal target: (baseTarget >> networkBurst) >> personalBurst-after-staking.
    ///      Capped at 20 bits max difficulty (1,048,576 hashes max) so searching always finishes in ~1-10s.
    function targetFor(address miner) public view returns (uint256) {
        uint256 t = baseTarget >> effectiveNetworkBurst();
        uint256 target = t >> effectivePersonalBurst(miner);
        uint256 minTarget = PowBotsLib.bitsToTarget(20);
        return target < minTarget ? minTarget : target;
    }

    /// @dev Effective target bit-width for humans/UI.
    function targetBitsFor(address miner) public view returns (uint256) {
        return _targetToBits(targetFor(miner));
    }

    /// @dev One eth_call that tells a miner / the UI everything it needs.
    function getStatus(address miner)
        public
        view
        returns (
            uint256 target,
            uint256 targetBits,
            uint256 floorBitsNow,
            bytes32 anchor,
            uint256 anchorNum,
            uint256 prevWork,
            uint256 price,
            uint256 netBurst,
            uint256 persBurst,
            uint256 alive,
            uint256 minted,
            uint256 epoch,
            uint256 lastMint,
            bool canMine
        )
    {
        target = targetFor(miner);
        targetBits = _targetToBits(target);
        floorBitsNow = floorBits + currentEpoch;
        anchorNum = block.number > 0 ? block.number - 1 : 0;
        anchor = blockhash(anchorNum);
        prevWork = lastWork;
        price = mintPrice();
        netBurst = effectiveNetworkBurst();
        persBurst = effectivePersonalBurst(miner);
        alive = aliveCount;
        minted = totalMinted;
        epoch = currentEpoch;
        lastMint = lastMintTime;
        canMine = target > 1;
    }

    // ── Mint — the only way bots exist ─────────────────────────────────────────

    /// @param nonce    uint64 big-endian, the only free variable.
    /// @param prevWork must equal lastWork() (the previous bot's winning hash).
    /// @param anchorNum block whose hash is `anchor`; must be within ANCHOR_WINDOW.
    /// @param anchor   blockhash(anchorNum).
    function mint(uint64 nonce, uint256 prevWork, uint256 anchorNum, bytes32 anchor)
        public
        payable
        nonReentrant
        returns (uint256 tokenId)
    {
        uint256 price = mintPrice();
        PowBotsLib.validateMintParams(
            msg.value, price, anchorNum, block.number,
            anchor, blockhash(anchorNum), prevWork, lastWork,
            isInviteGated(), isInvited[msg.sender]
        );

        address miner = msg.sender;
        _maybeRetarget();

        uint256 target = targetFor(miner);
        uint256 h = KeccakPacked.workHash(miner, nonce, prevWork, anchor);
        require(h < target, "Above target");

        // ── State updates ──
        totalMinted++;
        tokenId = totalMinted;
        uint256 depth = h == 0 ? 256 : 256 - _bitLength(h);
        catDepth[tokenId] = depth;
        catMiner[tokenId] = miner;
        catPricePaid[tokenId] = price;
        catMintTime[tokenId] = block.timestamp;

        uint256 bucket = block.timestamp / ROLL_PERIOD;
        uint256 seed = KeccakPacked.seedHash(h, bucket);
        catSeed[tokenId] = seed;

        uint8 unique = 0;
        if (totalMinted % uniqueWindow == 0 && uniquesTaken < uniqueTotal) {
            uniquesTaken++;
            unique = 1;
            catUnique[tokenId] = true;
            emit UniqueDrawn(tokenId, miner);
        }

        currentEpoch = EpochMath.epochForNextMint(totalMinted);

        // Bursts: decay then +1, capped.
        uint256 net = _burstDecay(networkBurst, lastBurstAt) + 1;
        networkBurst = net > BURST_SHIFT_CAP ? BURST_SHIFT_CAP : net;
        lastBurstAt = block.timestamp;
        currentTarget = baseTarget >> networkBurst;

        uint256 pers = _burstDecay(personalBurst[miner], personalLastMint[miner]) + 1;
        personalBurst[miner] = pers > BURST_SHIFT_CAP ? BURST_SHIFT_CAP : pers;
        personalLastMint[miner] = block.timestamp;

        lastWork = h;

        uint256 hookShare = _distributeFee(price);
        catWeight[tokenId] = 1;
        collectedScaled[tokenId] = rentPerWeight;
        totalWeight += 1;
        aliveCount++;

        _safeMint(miner, tokenId);
        lastMintTime = block.timestamp;

        _refundExcess(miner, price);

        emit CatMined(tokenId, miner, seed, h, target, unique);
        return tokenId;
    }

    /// @notice Redeem an invite code to permanently authorize msg.sender for mining.
    function redeemInvite(string memory code) public {
        bytes32 codeHash = PowBotsLib.validateInviteRedeem(code);
        require(validInviteHashes[codeHash], "Invalid invite code");
        isInvited[msg.sender] = true;
        emit InviteRedeemed(msg.sender, codeHash);
    }

    /// @notice Redeem an invite code and execute a mint in a single transaction.
    function mintWithInvite(
        uint64 nonce,
        uint256 prevWork,
        uint256 anchorNum,
        bytes32 anchor,
        string memory inviteCode
    ) external payable returns (uint256 tokenId) {
        if (!isInvited[msg.sender]) {
            redeemInvite(inviteCode);
        }
        return mint(nonce, prevWork, anchorNum, anchor);
    }

    // ── Burn — the only way $BOT is created, the only way bots die ────────────

    function burn(uint256 tokenId) external nonReentrant {
        PowBotsLib.validateBurn(_ownerOf(tokenId), msg.sender, catBurned[tokenId], staked[tokenId], tokenId, totalMinted, catMintTime[tokenId]);

        catBurned[tokenId] = true;
        catBurnedBy[tokenId] = msg.sender;

        uint256 tokenEpoch = epochOf(tokenId);
        uint256 epochsPassed = currentEpoch - tokenEpoch;
        uint256 amount = (BURN_BASE * 1e18) >> epochsPassed;
        if (amount == 0) amount = 1;

        // Active Staker Burn Boost: +10% (1-2 staked), +20% (3-7 staked), +30% (8+ staked)
        uint256 boost = burnBoostPct(msg.sender);
        if (boost > 0) {
            amount = (amount * (100 + boost)) / 100;
        }

        bot.mint(msg.sender, amount);
        totalWeight -= catWeight[tokenId]; // the bot's weight leaves the pool permanently
        aliveCount--;
        burnedCount++;
        _burn(tokenId);

        emit CatBurned(tokenId, msg.sender, amount);
    }

    /// @notice Returns the $BOT burn reward bonus percentage for a wallet based on active staked count.
    function burnBoostPct(address account) public view returns (uint256) {
        uint256 count = stakedCount[account];
        if (count >= 8) return 30;
        if (count >= 3) return 20;
        if (count >= 1) return 10;
        return 0;
    }

    /// @notice Pull rent. Travels with the token — the claim lives on the bot, and
    ///         the amount is the bot's weight × the rent accrued per weight unit.
    ///         A 2% claim tax is deducted and sent to admin revenue.
    function collectRent(uint256 tokenId) external nonReentrant {
        uint256 accrued = catWeight[tokenId] * rentPerWeight;
        uint256 scaled = accrued - collectedScaled[tokenId];
        (uint256 amount, uint256 tax) = PowBotsLib.validateRentClaim(_ownerOf(tokenId), msg.sender, scaled, RENT_PRECISION, CLAIM_TAX_BPS);
        collectedScaled[tokenId] = accrued;
        treasuryCollected += tax;
        uint256 payout = amount - tax;
        (bool ok,) = payable(msg.sender).call{value: payout}("");
        require(ok, "Transfer failed");
        emit RentClaimed(tokenId, msg.sender, payout);
    }

    // ── Forge — 3 of one tier into 1 of the next ────────────────────────────

    /// @notice Consume three tokens of the same tier, owned by this wallet, and mint one
    ///         token of the next tier up. Weight is preserved exactly (never created,
    ///         never destroyed); the output inherits the rarest trait per slot by the
    ///         published rarity table (ties break by lowest token id); and it keeps the
    ///         combined rent claim of the three inputs.
    /// @dev Decision sheet row 2 (forge epoch pressure): the fee is FORGE_FEE but never
    ///      below the next-mint price, so forging never produces "cheap" tier upgrades.
    function forge(uint256 a, uint256 b, uint256 c)
        external
        payable
        nonReentrant
        returns (uint256 outId)
    {
        uint256 fee = FORGE_FEE < mintPrice() ? mintPrice() : FORGE_FEE;
        uint256 w = catWeight[a];
        PowBotsLib.validateForge(PowBotsLib.ForgeInputs({
            a: a, b: b, c: c,
            ownerA: _ownerOf(a), ownerB: _ownerOf(b), ownerC: _ownerOf(c),
            sender: msg.sender,
            weightA: w, weightB: catWeight[b], weightC: catWeight[c],
            stakedA: staked[a], stakedB: staked[b], stakedC: staked[c],
            mintTimeA: catMintTime[a], mintTimeB: catMintTime[b], mintTimeC: catMintTime[c],
            lockedA: forgeLocked[a], lockedB: forgeLocked[b], lockedC: forgeLocked[c],
            lastForgeAt: lastForgeAt[msg.sender], aliveCount: aliveCount, supplyFloor: supplyFloor,
            msgValue: msg.value, fee: fee
        }));
        uint256 now_ = block.timestamp;

        uint256 hookShare = _distributeFee(fee);

        uint256[6] memory traits = _inheritTraits(a, b, c);

        // Inputs die: weight leaves the pool.
        aliveCount -= 3;
        totalWeight -= 3 * w;
        burnedCount += 3;
        catBurned[a] = true;
        catBurned[b] = true;
        catBurned[c] = true;
        catBurnedBy[a] = msg.sender;
        catBurnedBy[b] = msg.sender;
        catBurnedBy[c] = msg.sender;
        _burn(a);
        _burn(b);
        _burn(c);

        // Output: next tier, weight preserved, combined rent claim kept.
        forgeCount++;
        outId = FORGE_ID_START + forgeCount;
        uint256 outWeight = 3 * w;
        catForged[outId] = true;
        catWeight[outId] = outWeight;
        catMintTime[outId] = now_;
        catEpoch[outId] = currentEpoch;
        for (uint256 i = 0; i < 6; i++) catForgeTraits[outId][i] = traits[i];
        forgeLocked[outId] = true;
        collectedScaled[outId] = collectedScaled[a] + collectedScaled[b] + collectedScaled[c];
        lastForgeAt[msg.sender] = now_;

        totalWeight += outWeight; // net network weight unchanged
        aliveCount += 1;
        _safeMint(msg.sender, outId);

        bot.mint(msg.sender, FORGE_REWARD);

        _refundExcess(msg.sender, fee);

        emit Forged(outId, a, b, c, msg.sender, outWeight, fee);
    }

    /// @dev The output, for each trait slot, takes the rarest value present among the
    ///      three inputs; a tie on share is broken by the lowest token id (doc:157-158).
    ///      No randomness anywhere: it is all published-table + id arithmetic.
    function _inheritTraits(uint256 a, uint256 b, uint256 c)
        internal
        view
        returns (uint256[6] memory out)
    {
        uint256[3] memory inputs = [a, b, c];
        uint256[6][3] memory inputTraits;
        for (uint256 k = 0; k < 3; k++) {
            uint256 id = inputs[k];
            for (uint256 slot = 0; slot < 6; slot++) {
                inputTraits[k][slot] = _traitOf(id, slot);
            }
        }
        return PowBotsLib.inheritTraits(inputs, inputTraits);
    }

    /// @dev A token's shown trait id for `slot` (0..5): stored for forge outputs
    ///      (no seed), derived from the seed via the renderer otherwise.
    function _traitOf(uint256 tokenId, uint256 slot) internal view returns (uint256) {
        if (catForged[tokenId]) return catForgeTraits[tokenId][slot];
        return renderer.selectTraits(catSeed[tokenId])[slot];
    }

    /// @notice The forge tier of a token ("Common"/"Rare"/"Epic"/"Legendary").
    function tierOf(uint256 tokenId) public view returns (string memory) {
        uint256 w = catWeight[tokenId];
        if (w == 27) return "Legendary";
        if (w == 9) return "Epic";
        if (w == 3) return "Rare";
        return "Common";
    }

    /// @notice The six stored trait ids of a forge output (0 for mined bots).
    function getForgeTraits(uint256 tokenId) external view returns (uint256[6] memory) {
        return catForgeTraits[tokenId];
    }

    /// @notice Lock `tokenId` for a fixed term (7, 30, or 90 days).
    ///         Weight is frozen at stake time. Staker's share = catWeight × termMult × statusMult.
    ///         Max multiplier: 90d (3.0×) × Legendary (2.0×) = 6.0× a basic 7d Common stake.
    ///         While staked, the owner's personal mining difficulty falls by 1 bit.
    ///         The bot still earns rent, but cannot be sold, forged or burned.
    ///         No early unstaking is possible — the bot is locked to the second.
    function stake(uint256 tokenId, uint256 lockDays) external nonReentrant {
        PowBotsLib.validateStake(
            _ownerOf(tokenId), msg.sender,
            catBurned[tokenId], staked[tokenId], forgeLocked[tokenId], catMintTime[tokenId],
            stakedCount[msg.sender], STAKE_MAX_BITS, lockDays
        );

        uint256 shareWeight = PowBotsLib.computeShareWeight(catWeight[tokenId], lockDays);
        require(shareWeight > 0, "Zero share");

        staked[tokenId] = true;
        stakeUnlock[tokenId] = block.timestamp + (lockDays * 1 days);
        stakeLockDays[tokenId] = lockDays;
        stakedShareWeight[tokenId] = shareWeight;
        totalStakedShareWeight += shareWeight;
        stakeRewardCollected[tokenId] = stakeRewardPerWeight; // snapshot current accumulator
        stakedCount[msg.sender] += 1;
        emit Staked(tokenId, msg.sender, lockDays, shareWeight);
    }

    /// @notice Unlock a staked bot. The lock must have fully expired — no early unstaking,
    ///         no fee, no admin override. The bot is locked to the second.
    function unstake(uint256 tokenId) external nonReentrant {
        PowBotsLib.validateUnstake(staked[tokenId], _ownerOf(tokenId), msg.sender, stakeUnlock[tokenId]);

        // Auto-claim any remaining staking rewards at full rate (lock is expired)
        _settleStakeReward(tokenId, msg.sender);

        totalStakedShareWeight -= stakedShareWeight[tokenId];
        stakedShareWeight[tokenId] = 0;
        staked[tokenId] = false;
        stakeLockDays[tokenId] = 0;
        stakedCount[msg.sender] -= 1;
        emit Unstaked(tokenId, msg.sender);
    }

    /// @notice Claim staking rewards for a locked bot. If the lock has not yet expired,
    ///         a 50% early-claim penalty applies: half goes back to stakers, half to buyback.
    ///         After the lock expires, 100% of reward is paid out.
    function claimStakingRewards(uint256 tokenId) external nonReentrant {
        _settleStakeReward(tokenId, msg.sender);
    }

    /// @dev Internal: compute pending reward, apply early penalty if needed, transfer ETH.
    function _settleStakeReward(uint256 tokenId, address claimer) internal {
        uint256 sw = stakedShareWeight[tokenId];
        if (sw == 0) return; // nothing staked or already settled

        uint256 accumulated = sw * stakeRewardPerWeight;
        uint256 pending = (accumulated - stakeRewardCollected[tokenId]) / STAKE_REWARD_PRECISION;
        stakeRewardCollected[tokenId] = accumulated;

        if (pending == 0) return;

        (uint256 payout, uint256 penaltyToStakers, uint256 penaltyToBuyback) =
            PowBotsLib.computeStakeRewardClaim(
                _ownerOf(tokenId), claimer,
                staked[tokenId], stakeUnlock[tokenId],
                pending
            );

        // Recycle penalty to remaining stakers
        if (penaltyToStakers > 0 && totalStakedShareWeight > 0) {
            stakeRewardPerWeight += (penaltyToStakers * STAKE_REWARD_PRECISION) / totalStakedShareWeight;
        }
        // Send penalty to buyback pool
        if (penaltyToBuyback > 0) {
            pool.deposit{value: penaltyToBuyback}();
        }
        // Pay the claimer
        if (payout > 0) {
            (bool ok,) = payable(claimer).call{value: payout}("");
            require(ok, "Reward transfer failed");
        }
        emit StakeRewardClaimed(tokenId, claimer, payout, penaltyToStakers + penaltyToBuyback);
    }

    /// @notice Deposit staking rewards. Anyone (or any future product contract) can fund
    ///         the staking reward pool by sending ETH here. The reward is distributed
    ///         proportionally to all currently staked share weights.
    function depositStakingReward() external payable {
        require(msg.value > 0, "No ETH");
        require(totalStakedShareWeight > 0, "No stakers");
        stakeRewardPerWeight += (msg.value * STAKE_REWARD_PRECISION) / totalStakedShareWeight;
    }

    /// @dev Accept plain ETH transfers as staking reward deposits.
    receive() external payable {
        if (totalStakedShareWeight > 0 && msg.value > 0) {
            stakeRewardPerWeight += (msg.value * STAKE_REWARD_PRECISION) / totalStakedShareWeight;
        }
    }

    // ── ERC721 hooks ─────────────────────────────────────────────────────────

    /// @dev A forge output cannot be sold for 24h (doc:133). Only transfers carry a
    ///      non-zero `auth`; the forge's own mint-through and burns use address(0).
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        if (auth != address(0)) {
            PowBotsLib.validateTransfer(forgeLocked[tokenId], catMintTime[tokenId], staked[tokenId]);
        }
        return super._update(to, tokenId, auth);
    }

    // ── Difficulty internals ───────────────────────────────────────────────────

    function _maybeRetarget() internal {
        if (totalMinted - lastRetargetMinted < RETARGET_WINDOW) return;
        uint256 elapsed = block.timestamp - windowStartTime;
        uint256 newBase = PowBotsLib.computeRetarget(
            baseTarget, elapsed, epochFloor(currentEpoch), totalMinted, wallFrom, wallDiv
        );

        if (newBase != baseTarget) {
            uint256 oldBase = baseTarget;
            baseTarget = newBase;
            currentTarget = baseTarget >> networkBurst;
            emit Retargeted(oldBase, newBase);
        }

        lastRetargetMinted = totalMinted;
        windowStartTime = block.timestamp;
    }

    function _distributeFee(uint256 fee) internal returns (uint256 hookShare) {
        uint256 holderShare = (fee * RENT_BPS) / 10000;       // 60% to general holders rent
        uint256 treasuryCut = (fee * TREASURY_BPS) / 10000;   // 7% to treasury
        uint256 stakeBonus  = (fee * STAKE_RENT_BPS) / 10000; // 3% to staked bot bonus pool
        hookShare = fee - holderShare - treasuryCut - stakeBonus; // 30% to buyback pool

        treasuryCollected += treasuryCut;

        if (totalWeight > 0 && holderShare > 0) {
            rentPerWeight += (holderShare * RENT_PRECISION) / totalWeight;
        }

        if (totalStakedShareWeight > 0 && stakeBonus > 0) {
            stakeRewardPerWeight += (stakeBonus * STAKE_REWARD_PRECISION) / totalStakedShareWeight;
        } else if (stakeBonus > 0) {
            // If no active stakers currently exist, divert the 3% stake bonus to buyback pool
            hookShare += stakeBonus;
        }

        pool.deposit{value: hookShare}();
    }

    function _refundExcess(address recipient, uint256 fee) internal {
        if (msg.value > fee) {
            (bool ok,) = payable(recipient).call{value: msg.value - fee}("");
            require(ok, "Refund failed");
        }
    }

    // ── Admin fail-safe ────────────────────────────────────────────────────────

    /// @notice Only owner. If mining stalls (>FAILSAFE_MAX idle windows) halve difficulty.
    ///         No one can use this to mint or withdraw — it only makes the puzzle easier.
    function setPace() external onlyOwner {
        require(block.timestamp - lastMintTime > FAILSAFE_MAX * TARGET_INTERVAL, "Not idle");
        if (baseTarget < type(uint256).max / 2) baseTarget = baseTarget * 2; // halve difficulty
        currentTarget = baseTarget >> networkBurst;
        emit PaceChanged(currentTarget);
    }

    /// @notice One-time setter for the on-chain art renderer.
    function setRenderer(HashBotsRenderer _renderer) external onlyOwner {
        require(address(renderer) == address(0), "Renderer already set");
        require(address(_renderer) != address(0), "Zero renderer");
        renderer = _renderer;
        emit RendererSet(address(_renderer));
    }

    // ── Treasury revenue ───────────────────────────────────────────────────────

    /// @notice Withdraw accumulated treasury rent share. Only owner.
    function withdrawTreasury() external onlyOwner nonReentrant {
        uint256 amount = treasuryCollected;
        require(amount > 0, "Nothing to withdraw");
        treasuryCollected = 0;
        (bool ok,) = payable(owner()).call{value: amount}("");
        require(ok, "Transfer failed");
        emit TreasuryWithdrawn(owner(), amount);
    }

    /// @notice Set the timestamp until which invite code gating is active. Only owner.
    function setInviteUntil(uint256 timestamp) external onlyOwner {
        inviteUntil = timestamp;
        emit InviteUntilSet(timestamp);
    }

    /// @notice Toggle invite code requirement on/off. Only owner.
    function setInviteGated(bool _inviteGated) external onlyOwner {
        inviteUntil = _inviteGated ? type(uint256).max : 0;
        emit InviteGatedSet(_inviteGated);
    }

    /// @notice Add a plain string invite code. Only owner.
    function addInviteCode(string calldata code) external onlyOwner {
        bytes32 codeHash = keccak256(bytes(code));
        validInviteHashes[codeHash] = true;
        emit InviteCodeAdded(codeHash);
    }

    /// @notice Add a pre-hashed invite code. Only owner.
    function addInviteHash(bytes32 codeHash) external onlyOwner {
        validInviteHashes[codeHash] = true;
        emit InviteCodeAdded(codeHash);
    }

    /// @notice Revoke a pre-hashed invite code. Only owner.
    function removeInviteHash(bytes32 codeHash) external onlyOwner {
        validInviteHashes[codeHash] = false;
        emit InviteCodeRevoked(codeHash);
    }

    /// @notice Explicitly grant or revoke invitation status for a wallet address. Only owner.
    function setAddressInvited(address account, bool status) external onlyOwner {
        isInvited[account] = status;
        emit AddressInvited(account, status);
    }

    /// @notice Update the default ERC-2981 royalty. Only owner.
    /// @param receiver Address to receive royalties.
    /// @param feeNumerator Royalty fee in basis points (e.g. 500 = 5%).
    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    /// @notice ERC-165 interface detection (ERC721 + ERC2981).
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ── On-chain metadata (seed + traits; art rendering is the UI's domain) ───

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // Render any bot that was ever minted or forged, alive or burned. The art is
        // immutable (derived from the seed / stored traits), and the metadata carries a
        // "Burned" flag — so a burned bot still shows its picture, marked as gone.
        require(catMintTime[tokenId] != 0, "Nonexistent token");

        // If the renderer is set, delegate to it for full on-chain SVG art.
        if (address(renderer) != address(0)) {
            if (catForged[tokenId]) {
                // Forge outputs have no seed — their traits are inherited and stored.
                return renderer.renderForgedTokenURI(
                    tokenId,
                    catForgeTraits[tokenId],
                    catWeight[tokenId],
                    epochOf(tokenId),
                    catBurned[tokenId]
                );
            }
            return renderer.renderTokenURI(
                tokenId,
                catSeed[tokenId],
                epochOf(tokenId),
                catDepth[tokenId],
                catUnique[tokenId],
                catBurned[tokenId]
            );
        }

        // Fallback: metadata-only JSON (no image).
        string memory seedHex = Strings.toHexString(catSeed[tokenId]);
        string memory json = string(
            abi.encodePacked(
                '{"name":"HashBot #',
                Strings.toString(tokenId),
                '","description":"Mineable PoW HashBot. Seed-born art, fully determined on-chain.",',
                '"attributes":[{"trait_type":"Epoch","value":"',
                Strings.toString(epochOf(tokenId)),
                '"},{"trait_type":"Depth Bits","value":"',
                Strings.toString(catDepth[tokenId]),
                '"},{"trait_type":"Unique","value":"',
                catBurned[tokenId] ? "Burned" : (catUnique[tokenId] ? "Yes" : "No"),
                '"},{"trait_type":"Seed","value":"',
                seedHex,
                '"}]}'
            )
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }
}