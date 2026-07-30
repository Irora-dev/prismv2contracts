// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20}              from "solady/src/tokens/ERC20.sol";
import {Ownable}            from "solady/src/auth/Ownable.sol";
import {ReentrancyGuard}    from "solady/src/utils/ReentrancyGuard.sol";

import {IPositionManager}   from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions}            from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IHooks}               from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}         from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks}                from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey}              from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency}             from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams}           from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta}         from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {BaseHook}           from "./base/BaseHook.sol";
import {PrismArt}           from "./PrismArt.sol";
import {PrismMirror}        from "./PrismMirror.sol";

interface IPoolInit {
    function initializePool(PoolKey memory key, uint160 sqrtPriceX96) external;
}

/// @notice one v4 pool. five thousand facets.
/// @author 0xsolazy (https://github.com/0xsolazy/)
/// @custom:website  Prism (https://prism.0xsolazy.eth.limo/)
/// @custom:x        Prism (https://x.com/prism_lp/)
/// @custom:inspired thanks to Vectorized's DN404 (https://github.com/Vectorized/dn404) — packed
///   owner+index slot, Uint32Map (8 ids per slot), packed AddressData, derived art seed.
contract PrismHookV2 is ERC20, BaseHook, Ownable, ReentrancyGuard {

    using TransientStateLibrary for IPoolManager;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev `seed()` already called.
    error AlreadySeeded();

    /// @dev The pool has not been seeded yet.
    error NotSeeded();

    /// @dev A required address is the zero address.
    error ZeroAddress();

    /// @dev Caller is neither owner nor approved for the NFT.
    error NotOwnerOrApproved();

    /// @dev TokenId has no owner or `from` mismatch.
    error InvalidTokenId();

    /// @dev Caller is not the mirror.
    error MirrorOnly();

    /// @dev NFT transfer recipient is address(0).
    error TransferToZero();

    /// @dev NFT transfer source equals recipient (would be a free pending-harvest).
    error SelfTransferDisallowed();

    /// @dev [V2] NFT transfer recipient is a realignment-excluded address (pool / self).
    ///   The core invariant of the fee layer: fee-share NFTs may only
    ///   ever rest on realignment-eligible addresses, so `totalShares` can never exceed
    ///   the whole-token supply held by eligible users.
    error ExcludedRecipient();

    /// @dev [V2] Someone tried to initialize the host pool other than through `seed()`.
    error UnauthorizedInitialize();

    /// @dev [V2] Bad migration params (amount exceeds supply, or amount>0 with a zero vault).
    error BadMigration();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Seeded         (uint256 indexed posmTokenId, uint160 sqrtPriceX96, uint128 liquidity);
    event NFTMinted      (address indexed to,   uint256 indexed tokenId);
    event NFTBurned      (address indexed from, uint256 indexed tokenId);
    event FeesPoked      (uint256 ethGained, uint256 prismGained);
    /// @dev [V2] The POSM collect inside `pokeFees` reverted and was swallowed. Fees are intact and
    ///   remain in the position, but they are NOT being distributed — a keeper should treat this as
    ///   an alarm, because a compounding uncollected backlog is what makes the swap-path
    ///   fee-timing residual profitable.
    event PokeCollectFailed();
    event FeesForfeited  (uint256 ethAmount, uint256 prismAmount);
    event PrismFeeBurned (uint256 amount);
    event Claimed        (uint256 indexed tokenId, address indexed owner, uint256 ethOut, uint256 prismOut);
    event PendingCredited(address indexed user, uint256 ethAmount, uint256 prismAmount);
    event PendingWithdrawn(address indexed user, uint256 ethAmount, uint256 prismAmount);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint256 public constant SUPPLY       = 5000 ether;
    uint256 public constant UNIT         = 1 ether;
    uint24  public constant POOL_FEE     = 10_000;
    int24   public constant TICK_SPACING = 200;

    /// @dev [V2] Canonical burn sink. EXCLUDED from the fee layer, so PRISM sent here (e.g. by
    ///   the Spectrum buy-and-burn, or this token's own fee burn) is truly removed from circulation
    ///   — it mints no fee-shares and earns nothing. Without this, "burning" to 0xdEaD would instead
    ///   make it a fee-earning dead holder that dilutes everyone — the exact bug v2 exists to prevent.
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    /// @dev [V2] Fee split (community decision). ETH fees go 100% to holders. Of the PRISM-denominated
    ///   fees, `PRISM_BURN_BPS` is sent to the BURN_SINK (removed from circulation) and the remainder
    ///   goes to holders. Immutable by design.
    uint256 public constant PRISM_BURN_BPS = 2_000; // 20%
    uint256 private constant BPS           = 10_000;

    /// @dev Accumulator scaling. 1e12 fits per-share fees in uint128 (vs 1e18 which
    /// would saturate at ~340 ETH/share). Precision floor is 1 wei per share with
    /// totalShares ≤ 1e12, identical to a 1e18 scaling for any realistic claim cadence.
    uint256 private constant ACC_SCALE = 1e12;

    /// @dev [V2] Max NFT MINTS performed per transfer. Bounds the realign loop so a large
    ///   buy/receive can never revert out-of-gas; the un-minted remainder is caught up via
    ///   `syncNFTs`. Only the *mint* direction is capped — capping burns/moves could leave an
    ///   address with more shares than backing (an unbacked-share bug), so those stay eager.
    ///
    ///   Sized against **EIP-7825**, which caps a single transaction at 2^24 = 16,777,216 gas
    ///   regardless of the block gas limit. Each mint writes two virgin `_setFeeDebt` slots, which
    ///   cost 20,000 gas each (not 100) once any fee has ever accrued — i.e. always, in production.
    ///   Measured on a mainnet fork with fees accrued: ~76,000 gas per mint, so 128 mints ≈ 9.9M gas,
    ///   leaving ~41% headroom under the cap. **Do not raise this without re-measuring against that
    ///   cap.** At 256 a large claim costs ~19.5M gas and fits in NO transaction, which would leave the
    ///   two largest holders of the published snapshot (287.24 and 228.04 PRISM) unable to claim at all
    ///   — and `PrismMigration` has no sweep, so their PRISM would be locked forever.
    ///
    ///   IMPORTANT — this bounds the MINT direction only, so it does NOT make every transfer fit in a
    ///   transaction. The move and burn loops are deliberately uncapped (capping them could leave an
    ///   address holding more shares than backing, which is the unbacked-share bug), so a large enough
    ///   single transfer still exceeds the 2^24 cap, and the ceiling is a few hundred whole tokens rather
    ///   than a few thousand. Cost per NFT depends on whether the fee accumulators are warm: once any fee
    ///   has been collected `_setFeeDebt` writes into non-virgin slots, so a move costs roughly 2.7x what
    ///   it does on a pool that has never distributed. **Production is the warm case — size against that.**
    ///   `test/GasCeiling.t.sol` measures both and derives the ceiling from the warm figure; treat it as the
    ///   source of truth rather than a number quoted here, since a comment cannot be re-measured.
    ///   Above the ceiling a holder must split the transfer. Chunking always works and an oversized attempt
    ///   reverts rather than half-completing, so this is a large-holder UX cliff, not stuck funds.
    uint256 private constant MAX_REALIGN = 128;

    /// @dev Transient slot for the realignment-skip flag.
    uint256 private constant _SILENT_SLOT =
        0x9a8f8d1e3c5b7a9d6e2f4a8c7b5d3f9e1a6c4b8d2e7f5a9c3b1d6e8f2a4c7b9d;

    /// @dev [V2] Transient slot: set only for the duration of `seed()`, so `_beforeInitialize`
    ///   can reject any pool initialization that this hook did not itself originate.
    uint256 private constant _SEEDING_SLOT =
        0x3f1c7b2a9e5d8c4f6b0a1d3e7c9f2b5a8d4e6c1f0b3a7d9e2c5f8b1a4d6e3c07;

    /// @dev [V2] Transient slot: the first tokenId minted in the current transaction (0 if none).
    ///   Used to quarantine freshly-minted shares from same-tx fee capture (anti-JIT).
    uint256 private constant _TXMINT_LO_SLOT =
        0x7a2e5c8b1f4d9a6c3e0b7d2f5a8c1e4b9d6f3a0c7e2b5d8f1a4c9e6b3d0f7a21;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         IMMUTABLES                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:°•.°+.*•´.*:*/

    address public immutable POSM;
    address public immutable PERMIT2;
    PrismMirror public immutable mirror;

    /// @dev [V2] Optional airdrop-reserve holder (the migration contract). Minted its reserve at
    ///   construction and EXCLUDED from the fee layer, so the unclaimed reserve never mints
    ///   fee-shares nor dilutes real holders. address(0) if there is no migration reserve.
    address public immutable MIGRATION_VAULT;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       PACKED STORAGE                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    bool    public seeded;
    /// @dev [V2] When true, the next fee collection is FORFEITED (added to reserve, not
    ///   distributed). Armed at seed and whenever `totalShares` falls to 0, so fees that
    ///   accrue while no shares exist can never be swept by the first later shareholder.
    bool    public forfeitNextCollection;
    uint256 public hookPositionTokenId;
    int24   public globalTickLower;
    int24   public globalTickUpper;

    /// @dev Monotonic ERC-721 id counter. First minted id is 1.
    uint256 private _nextTokenId;

    /// @dev Live NFT count. Doubles as the share denominator for fee distribution.
    uint256 public totalShares;

    /// @dev Cumulative fees per share, scaled by `ACC_SCALE`. Monotonic, full uint256.
    ///   [V2] Debt is now stored full-width, so these are never truncated on write.
    uint256 public accFeesPerShareETH;
    uint256 public accFeesPerSharePRISM;

    /// @dev Packed owner + ownedIndex per tokenId.
    ///   bits [  0..159] = owner address  (uint160)
    ///   bits [160..191] = ownedIndex     (uint32)
    ///   bits [192..255] = reserved
    /// One cold SSTORE per mint instead of two (`_ownerOfNFT` + `_ownedIndex`).
    mapping(uint256 => uint256) private _oo;

    /// @dev Per-user packed array of owned tokenIds, 8 uint32 per slot.
    ///   _ownedSlot(user, k) → uint256 word holding tokenIds at owned-indices k*8 .. k*8+7
    /// For a user holding ≤ 8 NFTs everything lives in ONE storage slot — 5k warm
    /// SSTORE per subsequent mint instead of a fresh cold slot per id.
    mapping(address => mapping(uint256 => uint256)) private _ownedSlots;

    /// @dev Packed per-user metadata.
    ///   bits [ 0.. 31] = ownedLength (uint32)
    ///   bits [32.. 63] = flags (reserved)
    ///   bits [64..255] = reserved
    /// Replaces the previous `_nftBalance` standalone mapping.
    mapping(address => uint256) private _addressData;

    /// @dev [V2] Per-NFT fee debt, stored full-width (one uint256 each).
    ///   An earlier design packed both into one slot as uint128 and wrote `uint128(accFeesPerShare*)`,
    ///   a truncating cast that would silently wrap once an accumulator exceeded 2^128 and
    ///   cause unbounded over-claim. Full-width storage removes that footgun at the cost of
    ///   one extra cold SSTORE per mint/claim (acceptable; see the lazy-mint note in v2 docs).
    mapping(uint256 => uint256) private _ethDebt;
    mapping(uint256 => uint256) private _prismDebt;

    /// @dev Pending withdrawable balances (credited from burns / NFT moves / claim ETH fallback).
    mapping(address => uint256) public pendingETH;
    mapping(address => uint256) public pendingPRISM;

    /// @dev NFT approvals (single + operator).
    mapping(uint256 => address)                  private _nftApprovals;
    mapping(address => mapping(address => bool)) private _nftOperatorApprovals;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       PACKING HELPERS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev DN404-style: own a slot's high bits with `ownedIndex`, low bits with `owner`.
    function _ownerOf(uint256 id) internal view returns (address) {
        return address(uint160(_oo[id]));
    }
    function _ownedIndexOf(uint256 id) internal view returns (uint32) {
        return uint32(_oo[id] >> 160);
    }
    function _setOo(uint256 id, address owner, uint32 index) internal {
        _oo[id] = uint256(uint160(owner)) | (uint256(index) << 160);
    }

    /// @dev `_ownedSlots[user][index/8]` holds 8 packed uint32 tokenIds.
    function _ownedGet(address user, uint256 index) internal view returns (uint32) {
        return uint32(_ownedSlots[user][index >> 3] >> ((index & 7) << 5));
    }
    function _ownedSet(address user, uint256 index, uint32 value) internal {
        uint256 slotIdx = index >> 3;
        uint256 shift   = (index & 7) << 5;
        uint256 word    = _ownedSlots[user][slotIdx];
        // Clear the 32-bit slot then OR in the new value.
        _ownedSlots[user][slotIdx] = (word & ~(uint256(0xFFFFFFFF) << shift)) | (uint256(value) << shift);
    }

    function _ownedLength(address user) internal view returns (uint32) {
        return uint32(_addressData[user]);
    }
    function _setOwnedLength(address user, uint32 len) internal {
        uint256 v = _addressData[user];
        _addressData[user] = (v & ~uint256(0xFFFFFFFF)) | uint256(len);
    }

    function _ethDebtOf(uint256 id)   internal view returns (uint256) { return _ethDebt[id]; }
    function _prismDebtOf(uint256 id) internal view returns (uint256) { return _prismDebt[id]; }
    function _setFeeDebt(uint256 id, uint256 ethD, uint256 prismD) internal {
        _ethDebt[id]   = ethD;
        _prismDebt[id] = prismD;
    }

    /// @dev Deterministic per-id art seed. No storage.
    /// Including `address(this)` decorrelates seeds across deployments.
    function _deriveSeed(uint256 id) internal view returns (bytes32) {
        return keccak256(abi.encode(id, address(this)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    constructor(
        IPoolManager _poolManager,
        address      _owner,
        address      _posm,
        address      _permit2,
        address      _migrationVault,
        uint256      _migrationAmount
    ) BaseHook(_poolManager) {
        // `_poolManager` is checked too: BaseHook stores it without validating, and every consumer of
        // it short-circuits on `!seeded`, so a zero here would stay silent until `seed()` — the last
        // step of an atomic deploy — failed on `onlyPoolManager`.
        if (_owner == address(0) || _posm == address(0) || _permit2 == address(0)
            || address(_poolManager) == address(0)) revert ZeroAddress();
        // Migration reserve must fit in supply, and a nonzero amount needs a real vault that is
        // not one of the other excluded infra addresses (else the split is meaningless/unsafe).
        if (_migrationAmount > SUPPLY) revert BadMigration();
        if (_migrationAmount > 0) {
            if (_migrationVault == address(0) || _migrationVault == _posm || _migrationVault == _permit2
                || _migrationVault == address(_poolManager) || _migrationVault == BURN_SINK)
                revert BadMigration();
        } else {
            // A zero reserve with a nonzero vault would silently and PERMANENTLY exclude an arbitrary
            // address from the fee layer: it could hold PRISM, would mint no fee-shares, would earn
            // nothing, and `syncNFTs` would revert `ExcludedRecipient` for it forever. Since the vault
            // is unused at a zero reserve, require it to be unset rather than leave it unvalidated.
            if (_migrationVault != address(0)) revert BadMigration();
        }

        POSM            = _posm;
        PERMIT2         = _permit2;
        MIGRATION_VAULT = _migrationVault;

        mirror = new PrismMirror(address(this));

        _initializeOwner(_owner);

        // Split the fixed supply: the airdrop reserve to the (excluded) migration vault, the
        // remainder to the hook to seed pool liquidity. Both endpoints are excluded, so neither
        // mint creates fee-shares.
        if (_migrationAmount > 0) {
            _mint(_migrationVault, _migrationAmount);
            _mint(address(this), SUPPLY - _migrationAmount);
        } else {
            _mint(address(this), SUPPLY);
        }

        // The ERC20 allowance to Permit2 MUST be infinite: solady fixes canonical Permit2's
        // allowance at type(uint256).max and REVERTS any other value (Permit2AllowanceIsFixedAtInfinity),
        // so a finite value here would brick construction. The meaningful [V2] scope-down is at the
        // Permit2 layer below: POSM may pull at most SUPPLY PRISM, rather than the uint160 max.
        _approve(address(this), _permit2, type(uint256).max);
        IAllowanceTransfer(_permit2).approve(address(this), _posm, uint160(SUPPLY), type(uint48).max);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       ERC20 METADATA                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function name()   public pure override returns (string memory) { return "Prism"; }
    function symbol() public pure override returns (string memory) { return "PRISM"; }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          V4 HOOK                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true; // [V2] gate initialization to seed() only
        p.afterSwap        = true;
    }

    /// @dev [V2] Only `seed()` may initialize this hook's pool. Any other `initialize` call
    ///   (a front-run trying to set the opening price) reverts. `seed()` sets a transient flag
    ///   for exactly the duration of its POSM multicall, which is the only legitimate initializer.
    function _beforeInitialize(address /*sender*/, PoolKey calldata /*key*/, uint160 /*sqrtPriceX96*/)
        internal view override returns (bytes4)
    {
        if (!_isSeeding()) revert UnauthorizedInitialize();
        return IHooks.beforeInitialize.selector;
    }

    function _afterSwap(
        address /*sender*/,
        PoolKey  calldata /*key*/,
        SwapParams calldata /*params*/,
        BalanceDelta /*delta*/,
        bytes calldata
    ) internal pure override returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            SEED                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function seed(
        uint160 sqrtPriceX96,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity
    ) external onlyOwner returns (uint256 tokenId) {
        if (seeded) revert AlreadySeeded();
        seeded                = true;
        forfeitNextCollection = true; // [V2] forfeit fees accrued before the first shareholder
        globalTickLower       = tickLower;
        globalTickUpper       = tickUpper;

        PoolKey memory key = _hostKey();

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory mintParams = new bytes[](2);
        mintParams[0] = abi.encode(key, tickLower, tickUpper, liquidity, uint256(0), SUPPLY, address(this), bytes(""));
        mintParams[1] = abi.encode(key.currency0, key.currency1);

        bytes[] memory mc = new bytes[](2);
        mc[0] = abi.encodeWithSelector(IPoolInit.initializePool.selector, key, sqrtPriceX96);
        mc[1] = abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            block.timestamp + 60
        );

        tokenId             = IPositionManager(POSM).nextTokenId();
        hookPositionTokenId = tokenId;

        _setSeeding(true);              // [V2] authorize exactly this one initialization
        IPositionManager(POSM).multicall(mc);
        _setSeeding(false);

        emit Seeded(tokenId, sqrtPriceX96, liquidity);
    }

    function _hostKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0:   Currency.wrap(address(0)),
            currency1:   Currency.wrap(address(this)),
            fee:         POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(address(this))
        });
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     ERC20 → NFT SYNC                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev [V2] Single source of truth for "not a fee-share participant" — all eight members are in the
    ///   one expression below, and both the realignment gate and the NFT-transfer destination guard call
    ///   it, so the two exclusion sets can never drift apart. Drift between them is the failure mode.
    ///
    ///   Read the expression, not a list in a comment, and do not add one: a prose list of the members
    ///   here is a second copy that nothing keeps in step with the code, and on this function of all
    ///   functions a stale list tells a reader the parking hole is open when it is closed.
    /// @dev Addresses that must never hold fee-shares. The test is not "is this infrastructure" but
    ///   "could a share resting here ever be claimed" — a share on an address that cannot call
    ///   `withdrawPending()` still counts in `totalShares`, so it dilutes every real holder's slice
    ///   and the fees allotted to it are destroyed. That is the parking failure mode, and it is
    ///   reachable by a plain `transfer()` or by naming the address as a swap recipient, so it does
    ///   not require an attacker — a mis-integrated router or aggregator does it by accident.
    ///
    ///   `mirror` and `PERMIT2` are the unrecoverable cases: the mirror forwards `msg.sender` to this
    ///   hook as `caller` and never originates a call to itself, so nothing can ever act as it; and
    ///   solady fixes canonical Permit2's allowance at infinity while Permit2 itself can never sign
    ///   or approve, so its balance can never move. `POSM` is recoverable via its permissionless
    ///   SWEEP, but fees already booked to it are not, so it is excluded too.
    ///
    ///   NOTE this is a denylist standing in for a claimability property, so it can only ever cover
    ///   *known* members of an unbounded set. Swap routers (e.g. the Universal Router) are the
    ///   residual: PRISM left on one mints dead shares, though the shares self-heal via the router's
    ///   permissionless sweep. Integrators must sweep to the end user in the same transaction.
    function _isExcluded(address a) internal view returns (bool) {
        return a == address(0) || a == address(poolManager) || a == address(this)
            || a == MIGRATION_VAULT || a == BURN_SINK
            || a == POSM || a == PERMIT2 || a == address(mirror);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (_isSilent()) return;

        bool fromIsUser = !_isExcluded(from);
        bool toIsUser   = !_isExcluded(to);

        // A transfer may mint at most the number of whole-token boundaries the RECIPIENT actually
        // crossed. Taking that from the balance delta rather than from `amount` is what makes it
        // exact: a transfer that crosses no boundary mints nothing, while a sub-1 transfer that tips
        // a fractional balance past a whole token still mints its one share.
        //
        // `amount / UNIT + 1` looks equivalent and is not. The `+1` is claimable by a transfer that
        // moved nothing, and the bound is per CALL with nothing carried across a transaction, so a
        // stranger could still `transfer(x, 0)` in a loop and force shares onto `x` at roughly the
        // ordinary per-share cost — the bound raises it by ~1.2x, not the 128x it implies — and free of
        // even the `_maybePoke` cost when the loop runs inside a `PoolManager.unlock` callback. Deriving
        // the budget from the delta removes the free unit: a transfer that crosses no boundary mints
        // nothing, however many times it is repeated.
        //
        // DO NOT read this bound as making forced minting expensive. It does not — see
        // `test/ForcedShareCost.t.sol`, which pins the real behaviour:
        //
        //   * Against a FULLY mirrored holder it is genuinely self-limiting. Pushing a balance over a
        //     boundary mints, and pulling it back burns exactly what was minted, so the round trip nets
        //     zero shares. Measured.
        //   * Against an UNDER-MIRRORED holder it costs ZERO PRISM, gas only. `fromLoses` is 0 while a
        //     gap exists, so pulling the value back burns nothing and the minted share stays.
        //     `MAX_REALIGN` guarantees such a gap for anyone receiving more than 128 whole tokens in one
        //     transfer, and `syncNFTs` is caller-only, so a contract that cannot call it stays
        //     under-mirrored indefinitely. A Uniswap V2 pair is the reachable case — `skim(to)` is
        //     permissionless.
        //
        // Do NOT try to close that second case by clamping mints further; it is not a defect. Each round
        // mints one share for one whole token that genuinely arrived, and it **saturates at the victim's
        // own entitlement** (`balanceOf / UNIT`) — measured 128 → 200 and no further. So it creates
        // nothing and steals nothing: it only accelerates a catch-up the holder was always owed, and no
        // unbacked share is ever produced. "Balance crossed a boundary, so mint a share" is also exactly
        // what a normal buyer needs, so a guard that blocked it would strand every genuine contract
        // holder permanently. The controls here are the exclusion set and not creating a non-claiming
        // pool — NOT the cost of forcing a mint. Do not cite this bound as a security argument.
        //
        // `from == to` moves no value, so it crosses nothing; an under-mirrored holder catches up
        // with `syncNFTs`, which exists for exactly that and is already self-service.
        uint256 mintBudget;
        if (toIsUser && to != from) {
            uint256 postBalance = balanceOf(to);       // post-transfer, so subtract to get the pre
            mintBudget = postBalance / UNIT - (postBalance - amount) / UNIT;
        }

        if (fromIsUser && toIsUser) _realignPair(from, to, mintBudget);
        else if (fromIsUser)        _realignSolo(from, mintBudget);
        else if (toIsUser)          _realignSolo(to, mintBudget);
    }

    function _maybePoke() private {
        if (!seeded || totalShares == 0) return;
        if (poolManager.isUnlocked()) return;
        pokeFees();
    }

    function _realignPair(address from, address to, uint256 mintBudget) private {
        uint256 fromTarget = balanceOf(from) / UNIT;
        uint256 toTarget   = balanceOf(to)   / UNIT;
        uint256 fromCur    = _ownedLength(from);
        uint256 toCur      = _ownedLength(to);

        uint256 fromLoses = fromCur > fromTarget ? fromCur - fromTarget : 0;
        uint256 toGains   = toTarget > toCur     ? toTarget - toCur     : 0;

        uint256 transferable = fromLoses < toGains ? fromLoses : toGains;
        uint256 toBurn       = fromLoses - transferable;
        uint256 toMint       = toGains   - transferable;
        // Clamp only the FRESH-MINT portion. Moves and burns stay eager and uncapped: capping those
        // could leave an address holding more shares than backing, which is the unbacked-share bug.
        //
        // The budget is charged against the MINT ONLY, deliberately, even though `transferable` has
        // already consumed some of the same boundary crossings. It looks like a double-count and is not:
        // `toMint` is `toGains - transferable`, so it can only ever mint shares the recipient is ALREADY
        // ENTITLED TO — it holds the backing, it simply has not been mirrored yet. `MAX_REALIGN` creates
        // exactly that gap for anyone receiving more than 128 whole tokens in one transfer, and this is
        // the only channel that closes it automatically.
        //
        // DO NOT charge the mint against `mintBudget - transferable` instead. That makes the gap exactly
        // invariant under inflows: for a fully mirrored sender `transferable == mintBudget`, so the room
        // is always zero and nothing heals. A holder who bought 300 whole tokens through a router would
        // then sit at 128 shares through every later buy, its 172-share gap frozen, taking **20% less**
        // of a fee round than an identical holder who happened to know about
        // `syncNFTs` (which is caller-only, so a contract holder can never catch up at all). Trading a
        // permanent fee loss for honest holders against a slower griefing vector is the wrong trade: the
        // griefing steals nothing, saturates at the victim's own entitlement, and leaves the attacker
        // flat, whereas the frozen gap is a real and permanent loss. See `test/GapHealing.t.sol`.
        if (toMint > mintBudget) toMint = mintBudget;

        if (toMint > 0) _maybePoke();

        for (uint256 i = 0; i < transferable; i++) {
            uint256 tokenId = _pickTail(from);
            _move(from, to, tokenId);
        }
        for (uint256 i = 0; i < toBurn; i++) {
            uint256 tokenId = _pickTail(from);
            _burnNFT(from, tokenId);
        }
        _mintCapped(to, toMint); // [V2] bounded; remainder caught up via syncNFTs
    }

    function _realignSolo(address user, uint256 mintBudget) private {
        uint256 target = balanceOf(user) / UNIT;
        uint256 cur    = _ownedLength(user);

        if (target > cur) {
            uint256 toMint = target - cur;
            if (toMint > mintBudget) toMint = mintBudget;   // see _afterTokenTransfer
            _maybePoke();
            _mintCapped(user, toMint); // [V2] bounded; remainder caught up via syncNFTs
        } else if (cur > target) {
            uint256 toBurn = cur - target;
            for (uint256 i = 0; i < toBurn; i++) {
                uint256 tokenId = _pickTail(user);
                _burnNFT(user, tokenId);
            }
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     NFT INTERNAL OPS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _mintNFT(address to) private {
        unchecked {
            uint256 tokenId = ++_nextTokenId;
            _noteMint(tokenId); // [V2] anti-JIT: mark this tx's first mint id
            uint32  index   = _ownedLength(to);
            _setOo(tokenId, to, index);
            _ownedSet(to, index, uint32(tokenId));
            _setOwnedLength(to, index + 1);
            _setFeeDebt(tokenId, accFeesPerShareETH, accFeesPerSharePRISM);
            totalShares = totalShares + 1;
            mirror.emitTransfer(address(0), to, tokenId);
            emit NFTMinted(to, tokenId);
        }
    }

    /// @dev [V2] Mint at most `MAX_REALIGN` of the `want` owed NFTs, so a single transfer can
    ///   never revert out-of-gas on the mint loop. Any remainder is left un-mirrored (the holder
    ///   holds the whole tokens but not yet all NFTs) and can be caught up via `syncNFTs`. This
    ///   only ever *under*-mirrors, so `totalShares` stays ≤ eligible supply — never above it.
    function _mintCapped(address to, uint256 want) private {
        uint256 n = want < MAX_REALIGN ? want : MAX_REALIGN;
        for (uint256 i = 0; i < n; i++) _mintNFT(to);
    }

    /// @dev Burn an NFT held by `from`.
    function _burnNFT(address from, uint256 tokenId) private {
        _captureAndCreditPending(from, tokenId);

        uint32 index   = _ownedIndexOf(tokenId);
        uint32 lastIdx = _ownedLength(from) - 1;

        if (index != lastIdx) {
            uint32 lastTokenId = _ownedGet(from, lastIdx);
            _ownedSet(from, index, lastTokenId);
            // Update moved token's owned index in its packed _oo slot.
            _setOo(lastTokenId, from, index);
        }
        _setOwnedLength(from, lastIdx);

        delete _oo[tokenId];
        delete _ethDebt[tokenId];
        delete _prismDebt[tokenId];
        delete _nftApprovals[tokenId];

        unchecked { totalShares = totalShares - 1; }
        // [V2] If the float has fully exited, any fees accruing until the next shareholder
        // appear belong to no one — forfeit the next collection so nobody can sweep them.
        if (totalShares == 0) forfeitNextCollection = true;
        mirror.emitTransfer(from, address(0), tokenId);
        emit NFTBurned(from, tokenId);
    }

    function _move(address from, address to, uint256 tokenId) private {
        _captureAndCreditPending(from, tokenId);
        _setFeeDebt(tokenId, accFeesPerShareETH, accFeesPerSharePRISM);

        uint32 fromIdx = _ownedIndexOf(tokenId);
        uint32 lastIdx = _ownedLength(from) - 1;

        if (fromIdx != lastIdx) {
            uint32 lastTokenId = _ownedGet(from, lastIdx);
            _ownedSet(from, fromIdx, lastTokenId);
            _setOo(lastTokenId, from, fromIdx);
        }
        _setOwnedLength(from, lastIdx);

        uint32 toIdx = _ownedLength(to);
        _ownedSet(to, toIdx, uint32(tokenId));
        _setOo(tokenId, to, toIdx);
        _setOwnedLength(to, toIdx + 1);

        delete _nftApprovals[tokenId];
        mirror.emitTransfer(from, to, tokenId);
    }

    function _captureAndCreditPending(address holder, uint256 tokenId) private {
        // [V2] anti-JIT: a share minted earlier in THIS tx forfeits any same-tx capture on
        // move/burn, closing the sell-side variant of the atomic skim (fresh share is owed ~0).
        if (_mintedThisTx(tokenId)) return;
        uint256 owedETH   = (accFeesPerShareETH   - _ethDebtOf(tokenId))   / ACC_SCALE;
        uint256 owedPRISM = (accFeesPerSharePRISM - _prismDebtOf(tokenId)) / ACC_SCALE;
        if (owedETH == 0 && owedPRISM == 0) return;
        if (owedETH   > 0) pendingETH[holder]   += owedETH;
        if (owedPRISM > 0) pendingPRISM[holder] += owedPRISM;
        emit PendingCredited(holder, owedETH, owedPRISM);
    }

    /// @dev Pick the tail tokenId from `user`'s owned set.
    function _pickTail(address user) private view returns (uint256) {
        return _ownedGet(user, _ownedLength(user) - 1);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       FEE DISTRIBUTION                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function pokeFees() public {
        if (!seeded || totalShares == 0) return;
        if (poolManager.isUnlocked()) return;

        uint256 ethBefore   = address(this).balance;
        uint256 prismBefore = balanceOf(address(this));

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(hookPositionTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(Currency.wrap(address(0)), Currency.wrap(address(this)), address(this));

        // [V2] try/catch: a POSM-side failure (pause, migration, deadline change) must NOT brick
        // the token. On failure we simply accrue nothing this call; a later poke recovers. The
        // contract is immutable with no admin, so a bare revert here would be unrecoverable.
        try IPositionManager(POSM).modifyLiquidities(abi.encode(actions, params), block.timestamp + 60) {
            // [V2] Floor-at-zero (defense-in-depth): the balance can only increase across the
            // collect today (no hook callback fires mid-operation given the two-flag permission
            // set), but a plain subtraction would underflow-revert here — OUTSIDE the catch — if a
            // future variant ever let it decrease. Flooring keeps a bad reading a no-op, not a brick.
            uint256 ethNow      = address(this).balance;
            uint256 prismNow    = balanceOf(address(this));
            uint256 ethGained   = ethNow   > ethBefore   ? ethNow   - ethBefore   : 0;
            uint256 prismGained = prismNow > prismBefore ? prismNow - prismBefore : 0;

            // [V2] Forfeit the first collection after any zero-share period: the collected fees
            // accrued (partly) while no shares existed, so they belong to no holder. They stay in
            // the hook as reserve (over-collateral) rather than being swept by the first
            // shareholder. This closes the "first shareholder sweeps the zero-share backlog" skim.
            if (forfeitNextCollection) {
                forfeitNextCollection = false;
                if (ethGained > 0 || prismGained > 0) emit FeesForfeited(ethGained, prismGained);
            } else {
                // ETH fees: 100% to holders.
                if (ethGained > 0) accFeesPerShareETH += ethGained * ACC_SCALE / totalShares;
                // PRISM fees: PRISM_BURN_BPS to the burn sink, remainder to holders.
                if (prismGained > 0) {
                    uint256 prismBurn      = prismGained * PRISM_BURN_BPS / BPS;
                    uint256 prismToHolders = prismGained - prismBurn;
                    if (prismBurn > 0) {
                        // Both endpoints excluded -> no realign, no shares; PRISM removed from circulation.
                        _transfer(address(this), BURN_SINK, prismBurn);
                        emit PrismFeeBurned(prismBurn);
                    }
                    if (prismToHolders > 0) accFeesPerSharePRISM += prismToHolders * ACC_SCALE / totalShares;
                }
                if (ethGained > 0 || prismGained > 0) emit FeesPoked(ethGained, prismGained);
            }
        } catch {
            // Fees remain in the position and accrue on the next successful poke. Deliberately still
            // non-reverting — this contract is immutable with no admin, so a bare revert on a POSM-side
            // failure (pause, migration, deadline change) would be unrecoverable.
            //
            // But it must not be SILENT. What bounds the swap-path backlog is a keeper collecting often,
            // and a keeper cannot bound a backlog it cannot see: without this event a failing collect is
            // indistinguishable from "nothing accrued", so a POSM problem would let the backlog compound
            // while every poke still appeared to succeed — and a share minted late then takes a slice of
            // a backlog it never earned. Alarm on this event.
            emit PokeCollectFailed();
        }
    }

    function claim(uint256 tokenId) external nonReentrant {
        pokeFees();
        _claimOne(tokenId);
    }

    function claimMany(uint256[] calldata tokenIds) external nonReentrant {
        pokeFees();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (_ownerOf(tokenIds[i]) != address(0)) _claimOne(tokenIds[i]);
        }
    }

    function withdrawPending() external nonReentrant {
        _withdrawPendingTo(msg.sender);
    }

    function withdrawPendingTo(address recipient) external nonReentrant {
        if (recipient == address(0)) revert TransferToZero();
        // [V2] Don't let a user route their own fees into a dead/excluded sink (pool or hook),
        // where PRISM would become stuck reserve and ETH would be unrecoverable.
        if (_isExcluded(recipient)) revert ExcludedRecipient();
        _withdrawPendingTo(recipient);
    }

    /// @notice [V2] Mint up to `max` fee-share NFTs still owed to the CALLER — i.e. whole tokens
    ///   the caller holds that were not mirrored because a transfer hit the per-tx `MAX_REALIGN`
    ///   cap. Self-only (you can only sync your own address). Safe: only ever mints shares fully backed
    ///   by tokens the caller already holds, so it can never push `totalShares` above eligible supply.
    ///
    ///   Being self-only does NOT by itself put an address's share count beyond third-party reach:
    ///   `_afterTokenTransfer` realigns the RECIPIENT off its `balanceOf`, so a bare `transfer(x, 0)`
    ///   reaches an under-mirrored `x` from outside. What limits that is the mint budget there, which is
    ///   derived from the balance delta and so caps a valueless transfer at one share — keep it. Without
    ///   that bound a stranger could force up to `MAX_REALIGN` shares onto `x` per call, repeatedly: never
    ///   an unbacked share and no gain to the caller, but it lets anyone raise `x`'s cost to move its own
    ///   balance and — against a contract holding PRISM that cannot call `withdrawPending` — maximise the
    ///   share of every fee round diverted to shares nobody will ever claim.
    ///   `max == 0` means "as many as fit up to the internal per-call cap".
    function syncNFTs(uint256 max) external nonReentrant {
        address user = msg.sender;
        if (_isExcluded(user)) revert ExcludedRecipient();
        uint256 target = balanceOf(user) / UNIT;
        uint256 cur    = _ownedLength(user);
        if (target <= cur) return;
        uint256 want = target - cur;
        if (max != 0 && want > max) want = max;
        _maybePoke();
        _mintCapped(user, want);
    }

    /// @dev [V2] ETH and PRISM legs are independent: a recipient that rejects ETH no longer
    ///   blocks the PRISM leg, and a failed ETH send restores the credit (retry to another
    ///   recipient) instead of reverting the whole call. Balances are zeroed before the send
    ///   (checks-effects), and the function is `nonReentrant` at every entry point.
    /// @dev DO NOT add a permissionless `pushPending(holder)` here. It makes the problem it would be
    ///   meant to mitigate strictly worse. The intent would be to rescue fees credited to a
    ///   contract that cannot call `withdrawPending` (an ordinary Uniswap V2/V3 pool holding PRISM is
    ///   the unavoidable case). Paying those fees out, however, sends PRISM *to* that contract, and
    ///   since it is not excluded, `_afterTokenTransfer` then realigns it and mints it MORE fee-shares
    ///   — a ratchet in which every push raises its permanent cut of every future round. It would also
    ///   let anyone take a pool's rescued fees for
    ///   themselves via `skim()`, and let anyone pin a contract holder's fees to that holder before it
    ///   could route them elsewhere with `withdrawPendingTo`.
    ///
    ///   So the stranded-fee residual stands, documented at `_isExcluded`: value credited to a
    ///   non-claiming contract stays credited and unspent, which is inert. That is strictly better than
    ///   a mechanism that compounds the dilution and hands the proceeds to whoever calls first. Do not
    ///   add this without solving the realign-on-arrival problem first.
    function _withdrawPendingTo(address recipient) private {
        uint256 prismAmount = pendingPRISM[msg.sender];
        if (prismAmount > 0) {
            pendingPRISM[msg.sender] = 0;
            _transfer(address(this), recipient, prismAmount);
        }

        uint256 ethAmount = pendingETH[msg.sender];
        uint256 ethSent   = 0;
        if (ethAmount > 0) {
            pendingETH[msg.sender] = 0;
            (bool ok,) = recipient.call{value: ethAmount}("");
            if (ok) { ethSent = ethAmount; }
            // Restore so the caller can retry. Assignment is correct here, and deliberately so. It can
            // read as clobbering credit that a hostile recipient creates mid-flight while holding the
            // caller's allowance. It cannot. This branch runs only when `ok` is false, which
            // means the recipient's frame reverted or ran out of gas — and either way every state change
            // it made was rolled back with it, including any credit. For credit to survive to this line
            // the recipient would have to return successfully, and then `ok` is true and this line never
            // runs. So the slot is always exactly zero here and `=` and `+=` are indistinguishable.
            // Pinned by `test_FailedSendRestoresExactlyAndTheHostilePullLeavesNoTrace`.
            else    { pendingETH[msg.sender] = ethAmount; }
        }

        if (prismAmount > 0 || ethSent > 0) emit PendingWithdrawn(msg.sender, ethSent, prismAmount);
    }

    /// @dev [V2] Pull-based: credits the owner's `pending*` balances and makes NO external call.
    ///   Value only ever leaves via `withdrawPending*` (which the owner controls). This removes
    ///   an arbitrary all-gas ETH push, the entombment path, and the claim-loop reentrancy
    ///   surface in one move. Kept permissionless (safe now — it can only credit the owner).
    function _claimOne(uint256 tokenId) private {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) revert InvalidTokenId();

        uint256 owedETH   = (accFeesPerShareETH   - _ethDebtOf(tokenId))   / ACC_SCALE;
        uint256 owedPRISM = (accFeesPerSharePRISM - _prismDebtOf(tokenId)) / ACC_SCALE;

        // [V2] anti-JIT: a share minted earlier in THIS tx cannot realize fees booked after its
        // mint within the same tx. A legitimately-fresh share is owed ~0 anyway, so no honest
        // loss; this defeats the atomic mint->poke->claim/burn skim.
        if (_mintedThisTx(tokenId)) { owedETH = 0; owedPRISM = 0; }

        _setFeeDebt(tokenId, accFeesPerShareETH, accFeesPerSharePRISM);

        if (owedETH   > 0) pendingETH[owner]   += owedETH;
        if (owedPRISM > 0) pendingPRISM[owner] += owedPRISM;
        if (owedETH > 0 || owedPRISM > 0) emit PendingCredited(owner, owedETH, owedPRISM);

        emit Claimed(tokenId, owner, owedETH, owedPRISM);
    }

    /// @dev Mirrors the anti-JIT quarantine so the view and `claim` cannot disagree. A share minted
    ///   earlier in THIS transaction has its owed amount zeroed by `_claimOne` (and its debt advanced,
    ///   so the amount is destroyed rather than deferred). Without the same check here, this view is
    ///   optimistic inside any transaction that has already minted — and a batching keeper reading it
    ///   to decide what to claim would "claim" amounts that evaporate.
    function pendingFees(uint256 tokenId) external view returns (uint256 owedETH, uint256 owedPRISM) {
        if (_ownerOf(tokenId) == address(0)) return (0, 0);
        if (_mintedThisTx(tokenId)) return (0, 0);
        owedETH   = (accFeesPerShareETH   - _ethDebtOf(tokenId))   / ACC_SCALE;
        owedPRISM = (accFeesPerSharePRISM - _prismDebtOf(tokenId)) / ACC_SCALE;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     MIRROR CALLBACKS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier onlyMirror() {
        if (msg.sender != address(mirror)) revert MirrorOnly();
        _;
    }

    function handleNFTTransfer(address from, address to, uint256 tokenId, address caller)
        external onlyMirror nonReentrant
    {
        if (to == address(0)) revert TransferToZero();
        if (from == to)       revert SelfTransferDisallowed();
        // [V2] Core fix: a fee-share NFT may never be moved onto a realignment-excluded
        // address. Without this guard positions could be parked on the
        // PoolManager (or the hook), where they were never re-synced or burned yet still
        // counted in `totalShares` — permanently diverting a share of every fee.
        if (_isExcluded(to)) revert ExcludedRecipient();

        address owner = _ownerOf(tokenId);
        if (owner == address(0) || owner != from) revert InvalidTokenId();
        if (caller != owner && _nftApprovals[tokenId] != caller && !_nftOperatorApprovals[owner][caller]) {
            revert NotOwnerOrApproved();
        }

        // NOTE: we deliberately do NOT poke here. Forcing a ~200k-gas POSM collect on every
        // marketplace NFT transfer is not worth it to crystallize a seller's small
        // accrued-since-last-poke fees — a seller who cares can `claim` first (opt-in). The
        // residual seller->buyer fee drift is the documented fee-timing property of booking fees on
        // collection; it is bounded by collecting often, not by taxing every transfer.
        _move(from, to, tokenId);

        _setSilent(true);
        _transfer(from, to, UNIT);
        _setSilent(false);
    }

    function handleNFTApprove(address spender, uint256 tokenId, address caller) external onlyMirror {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) revert InvalidTokenId();
        if (caller != owner && !_nftOperatorApprovals[owner][caller]) revert NotOwnerOrApproved();
        _nftApprovals[tokenId] = spender;
        mirror.emitApproval(owner, spender, tokenId);
    }

    function handleNFTSetApprovalForAll(address operator, bool approved, address caller) external onlyMirror {
        _nftOperatorApprovals[caller][operator] = approved;
        mirror.emitApprovalForAll(caller, operator, approved);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          NFT VIEWS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function nftOwnerOf(uint256 tokenId) external view returns (address o) {
        o = _ownerOf(tokenId);
        if (o == address(0)) revert InvalidTokenId();
    }

    function nftBalanceOf(address owner)               external view returns (uint256) { return _ownedLength(owner); }
    /// @dev Throws for a nonexistent id, as ERC-721 requires and as `nftTokenURI`/`seedOf` already do.
    ///   This matters more here than in a static collection: an ERC-20 outflow burns fee-share NFTs
    ///   automatically, so "this id no longer exists" is a routine state rather than an edge case, and
    ///   returning `address(0)` would leave a consumer unable to tell a burned id from a live-but-
    ///   unapproved one.
    function nftGetApproved(uint256 tokenId) external view returns (address) {
        if (_ownerOf(tokenId) == address(0)) revert InvalidTokenId();
        return _nftApprovals[tokenId];
    }
    function nftIsApprovedForAll(address o, address s) external view returns (bool)    { return _nftOperatorApprovals[o][s]; }

    function nftTokenURI(uint256 tokenId) external view returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert InvalidTokenId();
        return PrismArt.tokenURI(tokenId, _deriveSeed(tokenId));
    }

    /// @dev Unpacks the per-user packed array into a fresh memory array. View only.
    function ownedTokensOf(address owner) external view returns (uint256[] memory ids) {
        uint256 n = _ownedLength(owner);
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = uint256(_ownedGet(owner, i));
    }

    /// @dev Art seed for `tokenId`. Pure function of (id, this); no storage read for seed.
    function seedOf(uint256 tokenId) external view returns (bytes32) {
        if (_ownerOf(tokenId) == address(0)) revert InvalidTokenId();
        return _deriveSeed(tokenId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       SILENT FLAG                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _setSilent(bool v) private {
        assembly { tstore(_SILENT_SLOT, v) }
    }

    function _isSilent() private view returns (bool v) {
        assembly { v := tload(_SILENT_SLOT) }
    }

    /// @dev [V2] Seeding flag — true only for the duration of `seed()`.
    function _setSeeding(bool v) private {
        assembly { tstore(_SEEDING_SLOT, v) }
    }
    function _isSeeding() private view returns (bool v) {
        assembly { v := tload(_SEEDING_SLOT) }
    }

    /// @dev [V2] First tokenId minted this tx (0 if none). Set once per tx in `_mintNFT`.
    function _firstMintThisTx() private view returns (uint256 v) {
        assembly { v := tload(_TXMINT_LO_SLOT) }
    }
    function _noteMint(uint256 tokenId) private {
        if (_firstMintThisTx() == 0) {
            assembly { tstore(_TXMINT_LO_SLOT, tokenId) }
        }
    }
    /// @dev A share is quarantined from fee capture/claim iff it was minted earlier in THIS tx.
    ///   Since `_nextTokenId` is monotonic, every id minted this tx is `>=` the first one.
    function _mintedThisTx(uint256 tokenId) private view returns (bool) {
        uint256 lo = _firstMintThisTx();
        return lo != 0 && tokenId >= lo;
    }

    receive() external payable {}
}
