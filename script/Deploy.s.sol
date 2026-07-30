// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PrismHookV2}   from "../src/PrismHookV2.sol";
import {PrismMigration} from "../src/PrismMigration.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title  PRISM v2 mainnet deploy script.
/// @notice Deploys and seeds the system, and deliberately STOPS SHORT of renouncing ownership:
///           1. deploy PrismMigration(merkleRoot)
///           2. CREATE2-deploy PrismHookV2 at a mined, flag-valid address (mints the airdrop
///              reserve to the migration vault, the rest to the hook)
///           3. hook.seed(price, ticks, liquidity)   [initializes the {ETH,PRISM} pool]
///         Then `script/Renounce.s.sol`, and LATER `script/OpenAirdrop.s.sol`, as separate steps.
///
///         The airdrop is NOT opened here. `setToken` is the switch that makes the reserve
///         distributable, and it now lives in `OpenAirdrop.s.sol` so the float can trade for hours
///         before 89% of the supply becomes movable.
///
/// @dev READ THIS BEFORE BROADCASTING — the two things operators get wrong.
///
///   **This is THREE transactions, not one** (two with no airdrop). `vm.startBroadcast()` emits one
///   transaction per state-changing top-level call, on sequential nonces. `_extsload` is a staticcall and
///   is not broadcast. This script's `require`s therefore run
///   during *simulation* only — the `Deploy` contract is never deployed on-chain, so nothing here can
///   revert a transaction that has already been mined. Simulation still catches every deterministic
///   configuration mistake before anything is signed, which is what these checks are for; what it
///   cannot catch is an on-chain failure of an individual step (out of gas against a
///   simulation-derived limit, a reorg, a state race).
///
///   **That is why renounce is not in this script.** A reverted `seed()` does NOT stop the next
///   transaction from landing. If renounce went out against an unseeded hook, the result would be
///   terminal: `seed()` is the only owner-gated function and `_beforeInitialize` rejects any pool
///   initialization not originating inside it, so the pool could never be created by anyone, the fee
///   logic would no-op forever, and the entire 5,000 PRISM supply would sit in an ownerless contract
///   with no exit. Keeping the owner key until `seeded()` is confirmed on-chain makes that
///   unreachable, and costs only a second transaction.
///
///   Broadcast with `--slow` so each transaction is confirmed before the next is sent, and if any step
///   reverts, finish the remaining steps by hand rather than re-running this script.
///
///   A re-run fails safely, at the CREATE2 step, because the vault is deployed deterministically
///   (step 1) rather than at the deployer's nonce. Every input to the hook's mined address is therefore
///   identical between runs, so the second run finds the hook already there and stops.
///
///   That holds only while the vault is deployed deterministically. Create it with `new` and its address
///   moves with the nonce, so a re-run mines a DIFFERENT hook address, `require(predicted.code.length ==
///   0)` passes, and you get a second complete 5,000 PRISM system with the first orphaned along with any
///   ETH already paid into its pool. Prefer finishing by hand regardless — a re-run stopping is a
///   backstop, not a plan.
///
/// Configure via env (see .env.example). Run:
///   forge script script/Deploy.s.sol --rpc-url $RPC --sender <deployer> --broadcast --slow --verify
contract Deploy is Script {
    // Canonical Ethereum-mainnet infrastructure (immutable singletons).
    address constant POOL_MANAGER    = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM            = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2         = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // CREATE2_FACTORY (0x4e59…4956C, the canonical deterministic-deployment proxy) is inherited from
    // forge-std Script.
    uint160 constant HOOK_FLAGS      = 0x2040; // beforeInitialize (1<<13) | afterSwap (1<<6)
    uint256 constant SUPPLY          = 5000 ether;
    /// Domain separator so the vault's CREATE2 salt can never coincide with the hook's, even though both
    /// are derived from the same (owner, chainid, SALT_NONCE).
    bytes32 constant VAULT_SALT_DOMAIN = keccak256("PRISM.migration-vault.v2");

    /// The deploy configuration exactly as the environment supplies it — every field at its RAW width,
    /// before any narrowing cast. Narrowing is part of what has to be validated (see `validateConfig`),
    /// so it cannot happen before the validator sees the values.
    struct RawConfig {
        bytes32 merkleRoot;
        uint256 migrationAmount;
        uint256 treeTotal;      // MERKLE_TOTAL; only meaningful when migrationAmount > 0
        uint256 sqrtPriceX96;
        int256  tickLower;
        int256  tickUpper;
        uint256 liquidity;
        uint256 targetFdvWei;
        uint256 saltNonce;
    }

    /// The same values, narrowed to the widths `seed()` actually takes.
    struct SeedParams {
        uint160 sqrtPriceX96;
        int24   tickLower;
        int24   tickUpper;
        uint128 liquidity;
    }

    function run() external {
        // ── Config (from env) ─────────────────────────────────────────────────────────────────
        RawConfig memory cfg = RawConfig({
            merkleRoot:      vm.envBytes32("MERKLE_ROOT"),       // from merkle/generate.mjs
            migrationAmount: vm.envUint("MIGRATION_AMOUNT"),    // airdrop reserve (wei); 0 = no airdrop
            treeTotal:       vm.envOr("MERKLE_TOTAL", uint256(0)),
            sqrtPriceX96:    vm.envUint("SEED_SQRT_PRICE_X96"),
            tickLower:       vm.envInt("SEED_TICK_LOWER"),
            tickUpper:       vm.envInt("SEED_TICK_UPPER"),
            liquidity:       vm.envUint("SEED_LIQUIDITY"),
            targetFdvWei:    vm.envUint("TARGET_FDV_WEI"),
            saltNonce:       vm.envUint("SALT_NONCE")
        });

        // ── Preflight validation (fail BEFORE broadcasting anything) ──────────────────────────
        // Runs in simulation, which is exactly where configuration errors must be caught: forge
        // simulates the whole script first and aborts without signing anything if one fails.
        SeedParams memory p = validateConfig(cfg);
        console2.log("implied launch FDV (wei of ETH):", impliedFdvWei(cfg.sqrtPriceX96));

        bytes32 merkleRoot      = cfg.merkleRoot;
        uint256 migrationAmount = cfg.migrationAmount;

        if (migrationAmount > 0) {
            // Everything in validateConfig is env-vs-env: it cannot tell whether MERKLE_ROOT belongs to
            // the tree the amounts came from. A root from the wrong snapshot, or a stale one left here
            // after regenerating, deploys perfectly cleanly and locks the ENTIRE reserve forever — no
            // sweep exists. MERKLE_TOTAL cannot catch it either, since it is a second hand-copied
            // number subject to the same slip.
            //
            // So verify cryptographically: take one real leaf that generate.mjs emitted and prove it
            // against the root actually being deployed. If they belong to different trees this fails.
            string memory canary = vm.readFile(vm.envString("CANARY_PATH"));
            require(vm.parseJsonBytes32(canary, ".root") == merkleRoot,
                    "MERKLE_ROOT does not match the canary file - wrong or stale root");
            require(vm.parseJsonUint(canary, ".total") == cfg.treeTotal,
                    "MERKLE_TOTAL does not match the canary file");
            address cAcct = vm.parseJsonAddress(canary, ".account");
            verifyCanaryLeaf(
                merkleRoot, cAcct, vm.parseJsonUint(canary, ".amount"),
                vm.parseJsonBytes32Array(canary, ".proof"));
            console2.log("canary leaf verified against MERKLE_ROOT:", cAcct);
        }

        uint160 sqrtPriceX96 = p.sqrtPriceX96;
        int24   tickLower    = p.tickLower;
        int24   tickUpper    = p.tickUpper;
        uint128 liquidity    = p.liquidity;
        // The seed deposits single-sided PRISM from the hook's balance (SUPPLY - migrationAmount);
        // the operator must ensure `liquidity` needs <= that. (Verified post-seed below.)

        address owner = msg.sender; // the broadcasting key; must sign seed(), then renounces.

        vm.startBroadcast();

        // 1. Migration vault (holds the airdrop reserve; excluded from the fee layer by the hook).
        //
        // Deployed through the CREATE2 factory, not with `new`, so its address is a function of the
        // configuration rather than of the deployer's nonce. Two properties depend on that, and neither
        // survives a plain CREATE:
        //
        //   * A re-run is blocked. The vault is a constructor argument to the hook, so a nonce-derived
        //     vault address gives a different initcode hash and therefore a different mined hook address
        //     — the "already occupied" check would pass and hand you a SECOND complete supply with the
        //     first orphaned. With CREATE2 the vault address is identical between runs, so the hook
        //     address is identical, so the check below fires as documented.
        //   * The reserve is not strandable beyond recovery. If this step fails while the hook deploy
        //     lands, the hook mints the reserve to this address regardless. A nonce-derived address could
        //     never be deployed to again, so 89% of supply would be gone for good; with CREATE2 the vault
        //     can still be deployed at that exact address afterwards, so the state is recoverable.
        //     `Renounce.s.sol` refuses to seal a launch until it is.
        //
        // Deploy only if absent, which makes this step idempotent and is what lets a re-run get far
        // enough to hit the hook check instead of quietly diverging here.
        //
        // Check the factory FIRST: the vault goes through it too, so this check has to precede the first
        // use of the factory. A call to a codeless address returns `(true, "")`, so a check placed after
        // the vault deploy would see `ok == true` and the failure would surface as "vault not deployed at
        // the predicted address" — still failing closed, but naming the wrong cause.
        require(CREATE2_FACTORY.code.length > 0, "CREATE2 factory not deployed on this chain");

        address vault = migrationAmount > 0
            ? deployVaultIfAbsent(owner, merkleRoot, cfg.saltNonce)
            : address(0);

        // 2. Mine a flag-valid CREATE2 salt for the exact constructor args, then deploy. The args and the
        //    mining live in `deployHook` so the whole sequence is testable with an airdrop configured;
        //    do not rebuild them here, or the two copies can drift and the mined address stops matching.
        // The canonical factory does not mix `msg.sender` into the salt, and the miner scans from 0 —
        // so the winning salt is fully public and anyone can deploy the identical initcode to the
        // predicted address first, making this step revert. The squatted contract is a *legitimate*
        // hook (the address is bound to the initcode hash, so hostile code cannot land there), but it
        // is a cheap, repeatable denial of service. Offsetting the search by a per-deployer nonce means
        // a griefer cannot predict the next attempt: bump SALT_NONCE and re-run.
        // SALT_NONCE must be a SECRET, and it must be set. The owner address and the chain id are both
        // public, so with a nonce of 0 the winning salt is fully derivable and the predicted address is
        // squattable on demand. This does not make squatting impossible (the
        // canonical factory ignores msg.sender, so a leaked nonce is squattable again); it makes the
        // address unpredictable to someone who does not know your nonce.
        address predicted = deployHook(owner, vault, migrationAmount, cfg.saltNonce);
        PrismHookV2 hook = PrismHookV2(payable(predicted));

        // 3. Confirm the reserve landed in the vault — but do NOT wire the token here.
        //
        // Wiring is what opens the airdrop: `PrismMigration.claim` refuses while `token` is zero, and it
        // is permissionless, so the instant `setToken` lands anyone holding a proof can move a holder's
        // allocation. Doing that inside the deploy would make 4454.677 PRISM claimable in the same
        // sequence that creates the pool — one transaction BEFORE the pool exists — leaving no
        // window in which the float can trade before 89% of the supply is in circulation.
        //
        // So it lives in `script/OpenAirdrop.s.sol`, run deliberately once the pool has had time to trade.
        // `setToken` is deployer-only with no deadline and lives on the vault rather than the hook, so the
        // hook can be seeded and renounced immediately while the airdrop stays wireable indefinitely.
        //
        // The consequence to plan for: the deploy key acquires one more job AFTER the renounce, so it has
        // to survive until the airdrop is opened. Until `setToken` runs, nothing but that key can open it
        // and the reserve is unreachable.
        if (migrationAmount > 0) {
            require(hook.balanceOf(vault) == migrationAmount, "reserve not minted to vault");
        }

        // 4. Seed the {ETH,PRISM} pool (one-shot; initializes + mints the LP position to the hook).
        uint256 tokenId = hook.seed(sqrtPriceX96, tickLower, tickUpper, liquidity);
        require(hook.seeded() && tokenId > 0, "seed failed");
        uint256 float_ = SUPPLY - migrationAmount;
        uint256 seededPrism = float_ - hook.balanceOf(predicted);
        validateSeededAmount(float_, seededPrism, vm.envOr("MIN_SEED_PRISM", uint256(0)));

        // Read the pool's OWN tick after seeding rather than trusting the input: PoolManager.pools is
        // storage slot 6, and slot0 packs the tick in bits 160..183.
        {
            bytes32 slot0 = _extsload(keccak256(abi.encode(_poolId(predicted), uint256(6))));
            int24 poolTick = int24(uint24(uint256(slot0) >> 160));
            validatePoolTick(poolTick, tickUpper);
            console2.log("pool opened at tick:", vm.toString(int256(poolTick)));
        }

        vm.stopBroadcast();

        // Ownership is deliberately NOT renounced here — see the note at the top of this file. Renounce
        // only after confirming on-chain that the seed landed, via `script/Renounce.s.sol`.

        console2.log("PRISM seeded into the pool (wei):", seededPrism);
        console2.log("PrismHookV2 :", predicted);
        console2.log("PrismMirror :", address(hook.mirror()));
        console2.log("PrismMigration (vault):", vault);
        console2.log("LP position tokenId :", tokenId);
        console2.log("Airdrop reserve (wei):", migrationAmount);
        console2.log("");
        console2.log("DEPLOYED AND SEEDED. Ownership is STILL HELD - the token is not final yet.");
        console2.log("Confirm on-chain, then renounce:");
        console2.log("  cast call <hook> 'seeded()(bool)'   # must be true");
        console2.log("  HOOK=<hook> forge script script/Renounce.s.sol --rpc-url $RPC_URL --broadcast");
        if (migrationAmount > 0) {
            console2.log("");
            console2.log("THE AIRDROP IS NOT OPEN. Only the seeded float can trade right now - the reserve");
            console2.log("above sits in the vault and is not distributable until you run, hours later:");
            console2.log("  HOOK=<hook> VAULT=<vault> RESERVE=<reserve> \\");
            console2.log("    forge script script/OpenAirdrop.s.sol --rpc-url $RPC_URL --broadcast");
            console2.log("");
            console2.log(">>> KEEP THE DEPLOY KEY. That step needs it again, AFTER the renounce, and nothing");
            console2.log(">>> else can ever open the airdrop - no sweep, no fallback. Lose the key before");
            console2.log(">>> running it and the entire reserve is stranded permanently.");
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    CONFIG VALIDATION                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    //
    // These are `public pure` on purpose, and `run()` calls them rather than inlining the checks.
    // Every guard here defends a configuration mistake that would otherwise deploy CLEANLY and brick an
    // immutable contract forever, so each one needs a test — and a test can only defend a guard it
    // shares code with. Keep it that way: a test that replays these checks inline instead of calling
    // them defends nothing, because reverting the real guard leaves the whole suite green.
    //
    // Parameterised rather than env-driven for a specific reason: `vm.setEnv` is process-global and
    // forge runs a contract's tests in PARALLEL, so env-driven tests race and flake. `Renounce.s.sol`
    // already took this approach for the same reason.

    /// Implied fully-diluted valuation in wei of ETH, derived from the price itself rather than from a
    /// recomputed tick: `p (PRISM per ETH) = (sqrtPriceX96 / 2^96)^2`, `FDV = SUPPLY / p`. Split into two
    /// steps so the intermediate cannot overflow.
    /// @notice The airdrop vault's address for a given configuration — a pure function of it, with no
    ///   dependence on the deployer's nonce. That independence is what makes a re-run collide instead of
    ///   diverging, and what makes a half-finished deploy recoverable rather than terminal.
    /// @dev Public so the property can be tested directly. Reading it out of `run()` would mean setting
    ///   up the whole environment, and `vm.setEnv` is process-global while forge runs tests in parallel.
    function vaultAddressFor(address owner_, bytes32 root, uint256 saltNonce) public view returns (address) {
        return computeCreate2Address(
            vaultSalt(owner_, saltNonce), keccak256(vaultInitCode(root, owner_)), CREATE2_FACTORY
        );
    }

    function vaultInitCode(bytes32 root, address deployer_) public pure returns (bytes memory) {
        return abi.encodePacked(type(PrismMigration).creationCode, abi.encode(root, deployer_));
    }

    /// @dev `block.chainid` is mixed in so the same configuration cannot be replayed to the same address
    ///   on another chain, and VAULT_SALT_DOMAIN so this can never collide with the hook's own salt base.
    function vaultSalt(address owner_, uint256 saltNonce) public view returns (bytes32) {
        return keccak256(abi.encode(owner_, block.chainid, saltNonce, VAULT_SALT_DOMAIN));
    }

    /// @notice Deploy the vault at its deterministic address, or accept the one already there.
    /// @dev Idempotent on purpose: a re-run must reach the hook's already-deployed check rather than
    ///   silently producing a second vault, and a recovery run must be able to fill in a vault whose
    ///   original deployment failed while the hook's mint landed.
    /// @notice Mine a flag-valid CREATE2 salt for the exact constructor args and deploy the hook.
    /// @dev Public so the full launch sequence is testable with an airdrop configured, and it must stay
    ///   exercised that way: inlined in `run()` it can only be covered with `migrationAmount == 0` (the
    ///   plain fork test uses zero and builds no vault), which never reaches the vault or `setToken` at
    ///   all. See `test/DeployFullRunFork.t.sol`.
    function deployHook(address owner_, address vault, uint256 migrationAmount, uint256 saltNonce)
        public returns (address)
    {
        bytes memory args =
            abi.encode(IPoolManager(POOL_MANAGER), owner_, POSM, PERMIT2, vault, migrationAmount);
        bytes32 saltBase = keccak256(abi.encode(owner_, block.chainid, saltNonce));
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(PrismHookV2).creationCode, args, saltBase);
        // Read this before acting on it: the message has two causes and only one makes bumping correct.
        // BEFORE any launch the occupant is a squatter, and a new SALT_NONCE is the right answer. AFTER your
        // own launch the occupant is YOUR OWN HOOK -- and since the nonce feeds the salt, bumping it moves
        // the predicted address somewhere empty, so this guard goes quiet and the deploy succeeds, handing
        // you a SECOND complete 5,000 PRISM system with its own pool and its own airdrop reserve. Check
        // whether a hook of yours is already live before changing anything.
        require(
            predicted.code.length == 0,
            "predicted address occupied - if a SQUATTER, bump SALT_NONCE; if it is YOUR OWN hook from an earlier launch, STOP: bumping deploys a second complete token"
        );
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, type(PrismHookV2).creationCode, args));
        require(ok, "CREATE2 deploy failed");
        // Confirm something is actually there: a factory-less or misbehaving chain can return ok==true
        // having deployed nothing, which would otherwise only surface as an opaque ABI-decode revert.
        require(predicted.code.length > 0, "hook not deployed at the predicted address");
        require(uint160(predicted) & 0x3FFF == HOOK_FLAGS, "hook flags mismatch");
        require(PrismHookV2(payable(predicted)).balanceOf(predicted) == SUPPLY - migrationAmount,
                "hook supply split wrong");
        return predicted;
    }

    function deployVaultIfAbsent(address owner_, bytes32 root, uint256 saltNonce) public returns (address) {
        require(root != bytes32(0), "vault needs a nonzero merkle root");
        address vault = vaultAddressFor(owner_, root, saltNonce);
        if (vault.code.length == 0) {
            (bool ok,) =
                CREATE2_FACTORY.call(abi.encodePacked(vaultSalt(owner_, saltNonce), vaultInitCode(root, owner_)));
            require(ok, "vault CREATE2 deploy failed");
        }
        require(vault.code.length > 0, "vault not deployed at the predicted address");
        // If something else already occupies the address, it must be the vault this configuration means.
        require(PrismMigration(vault).merkleRoot() == root, "vault at that address has a different root");
        // The check that matters most: the vault must name a deployer that can actually call `setToken`.
        // Deploying through the CREATE2 factory makes `msg.sender` the FACTORY — an address with no CALL
        // opcode in its runtime — so a vault that derived its deployer from `msg.sender` would have
        // `setToken` unreachable forever, and the reserve could be minted into a vault that can never be
        // wired to a token. `PrismMigration` takes the authority as a constructor argument for that
        // reason; assert it on-chain rather than trust the argument, because there is no second chance
        // after the reserve is minted.
        require(PrismMigration(vault).deployer() == owner_, "vault names a deployer that cannot wire it");
        return vault;
    }

    function impliedFdvWei(uint256 sqrtPriceX96) public pure returns (uint256) {
        require(sqrtPriceX96 > 0, "SEED_SQRT_PRICE_X96 == 0");
        return (SUPPLY * (uint256(1) << 96) / sqrtPriceX96) * (uint256(1) << 96) / sqrtPriceX96;
    }

    /// Validates the whole raw configuration and returns it narrowed to `seed()`'s widths.
    function validateConfig(RawConfig memory c) public pure returns (SeedParams memory p) {
        require(c.migrationAmount <= SUPPLY, "MIGRATION_AMOUNT > SUPPLY");
        require(c.liquidity > 0, "SEED_LIQUIDITY == 0");
        require(c.sqrtPriceX96 > 0, "SEED_SQRT_PRICE_X96 == 0");

        // Narrowing casts are silent. A value one digit too long is truncated into a *valid but
        // completely different* parameter — a 2^128-overflowing liquidity becomes a dusting, and a tick
        // of 16777416 becomes 200, a ~2,000,000x price error. Round-trip each one.
        p.liquidity    = uint128(c.liquidity);
        p.sqrtPriceX96 = uint160(c.sqrtPriceX96);
        p.tickLower    = int24(c.tickLower);
        p.tickUpper    = int24(c.tickUpper);
        require(uint256(p.liquidity)    == c.liquidity,    "SEED_LIQUIDITY truncated");
        require(uint256(p.sqrtPriceX96) == c.sqrtPriceX96, "SEED_SQRT_PRICE_X96 truncated");
        require(int256(p.tickLower)     == c.tickLower,    "SEED_TICK_LOWER truncated");
        require(int256(p.tickUpper)     == c.tickUpper,    "SEED_TICK_UPPER truncated");

        // Pin the price to v4's own usable range BEFORE any arithmetic uses it. Without this bound the
        // FDV check degenerates at both extremes instead of failing by name: below sqrtPrice 272 the
        // implied-FDV multiplication overflows into a bare arithmetic panic (0x11) carrying no message,
        // and at the top of uint160 it truncates to 0, which then satisfies a purely relative +-25% band
        // against any small TARGET_FDV_WEI. Both are fail-safe (the deploy aborts, or v4 rejects it
        // later), but a guard whose entire job is to produce a NAMED failure during simulation should
        // not hand the operator an unexplained panic. Bounds are v4's MIN_SQRT_PRICE and
        // MAX_SQRT_PRICE - 1.
        require(c.sqrtPriceX96 >= 4295128739
             && c.sqrtPriceX96 <  1461446703485210103287273052203988822378723970342,
                "SEED_SQRT_PRICE_X96 outside v4's usable range");

        // Tick hygiene. The pool's spacing is 200 and v4's usable range is +-887272; a misaligned or
        // inverted range either reverts deep inside POSM with an opaque error or silently changes the
        // launch price.
        require(p.tickLower % 200 == 0 && p.tickUpper % 200 == 0, "ticks must be multiples of 200");
        require(p.tickLower < p.tickUpper, "SEED_TICK_LOWER >= SEED_TICK_UPPER");
        require(p.tickLower >= -887200 && p.tickUpper <= 887200, "tick out of range");

        // Alignment and range say nothing about PRICE. `SEED_TICK_UPPER = 887200` is aligned and
        // in-range and sells the entire supply for one gwei — and because the liquidity required at an
        // extreme tick is tiny, "count your digits" gives no warning: the value looks like `272`.
        // So require the operator to state the valuation they intend, and check the price against it.
        require(c.targetFdvWei > 0, "TARGET_FDV_WEI not set - state the valuation you intend");

        // ABSOLUTE bounds first. A purely relative band cannot catch a nonsense valuation, because it
        // only ever compares the price to a number the same operator typed:
        //   * `impliedFdvWei` floors to 0 for any sqrtPrice above ~5.6e39, which covers 1,938 aligned,
        //     in-range ticks (499800..887200). Since `1 * 3 / 4 == 0` in integer arithmetic, a zero FDV
        //     sits INSIDE the band against `TARGET_FDV_WEI = 1` — so the whole "sells the entire supply
        //     for one gwei" launch this band exists to stop passed every guard. The v4 range check alone
        //     does NOT close this: the truncation region is far below MAX_SQRT_PRICE.
        //   * A units error that scales both inputs passes to the wei. `TARGET_FDV_WEI = 100` meaning
        //     "100 ETH", with the price derived from the same mistake, implies exactly 100 WEI and is
        //     accepted.
        //   * `c.targetFdvWei * 3 / 4` panics unnamed above ~3.85e76.
        require(c.targetFdvWei >= 0.001 ether && c.targetFdvWei <= 1e30,
                "TARGET_FDV_WEI implausible - state the valuation in WEI of ETH");
        uint256 fdvWei = impliedFdvWei(c.sqrtPriceX96);
        require(fdvWei >= 0.001 ether,
                "implied FDV is essentially zero - SEED_SQRT_PRICE_X96 sells the supply for nothing");
        require(fdvWei >= c.targetFdvWei * 3 / 4 && fdvWei <= c.targetFdvWei * 5 / 4,
                "SEED_SQRT_PRICE_X96 implies an FDV more than 25% from TARGET_FDV_WEI");

        // An airdrop needs a real root, and a real root needs an airdrop. Either half alone deploys
        // cleanly and locks the reserve forever: a zero root can never be satisfied (that would need a
        // keccak preimage of 0), and a nonzero root with a zero reserve deploys no vault at all.
        require((c.migrationAmount > 0) == (c.merkleRoot != bytes32(0)),
                "MERKLE_ROOT/MIGRATION_AMOUNT mismatch");

        if (c.migrationAmount > 0) {
            require(c.treeTotal > 0, "MERKLE_TOTAL not set");
            // Equality, not `>=`. Note what the canary does and does not prove: it verifies one real
            // leaf against MERKLE_ROOT, so it pins the ROOT — it says nothing about the SUM of the
            // leaves. `.total` is an unverified field in the same file, so MERKLE_TOTAL inherits no
            // cryptographic strength, and moving `.total` and MERKLE_TOTAL together defeats this check.
            // Only reading the tree does. MIGRATION_AMOUNT is the number that actually decides how much
            // is minted into a sweepless vault, and it stays hand-copied. With only a lower bound, any
            // value in [treeTotal, SUPPLY - MIN_SEED]
            // passes every guard while quietly minting PRISM no proof can ever reach: up to 495 PRISM,
            // ~9.9% of supply, taken straight out of the tradable float. Both MIN_SEED guards are
            // relative to the float, so they shrink with it and cannot see this. Excess reserve has no
            // use — nothing can withdraw it — so there is no legitimate reason for the two to differ.
            require(c.migrationAmount == c.treeTotal, "MIGRATION_AMOUNT != MERKLE_TOTAL");
        }

        // The owner address and the chain id are both public, so with a nonce of 0 the winning CREATE2
        // salt is fully derivable and the predicted address is squattable on demand.
        require(c.saltNonce != 0, "SALT_NONCE must be set to a random secret, not 0");
    }

    /// Recomputes a canary leaf from `(account, amount)` and walks `proof` to the root, using the same
    /// double-hash and sorted-pair order as `PrismMigration._verify`.
    function verifyCanaryLeaf(bytes32 root, address account, uint256 amount, bytes32[] memory proof)
        public pure
    {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        for (uint256 i; i < proof.length; ++i) {
            leaf = leaf <= proof[i]
                ? keccak256(abi.encodePacked(leaf, proof[i]))
                : keccak256(abi.encodePacked(proof[i], leaf));
        }
        require(leaf == root, "canary proof does NOT verify against MERKLE_ROOT");
    }

    /// Post-seed check on how much PRISM actually entered the pool.
    ///
    /// `balanceOf < float` only proves 1 wei moved, which is not a launch. An undersized seed deploys
    /// perfectly and bricks the token: with a float below one whole PRISM, `totalShares` can never leave
    /// 0, so `pokeFees` returns early forever and every fee the pool ever earns is unclaimable — while
    /// the unseeded remainder is stranded in an ownerless contract with no exit.
    function validateSeededAmount(uint256 float_, uint256 seededPrism, uint256 minSeedEnv) public pure {
        // MIN_SEED_PRISM may only ever RAISE the bar. Honouring it downward would be worse than having no
        // check at all: `MIN_SEED_PRISM=0` would let almost the whole supply strand in the hook and still
        // deploy.
        uint256 floor90 = (float_ * 90) / 100;
        uint256 minSeed = minSeedEnv < floor90 ? floor90 : minSeedEnv;
        require(seededPrism >= minSeed, "seeded PRISM below 90% of the float");
        // And the absolute floor has to be in WHOLE tokens, not one. A share requires a whole token, so
        // a ~1-PRISM pool yields buyers 0 whole tokens (price impact eats the rest), `totalShares` never
        // leaves 0, `pokeFees` returns early forever and every fee is forfeited permanently. A `>= 1 ether`
        // floor does not prevent that; the floor has to be in whole tokens.
        require(seededPrism >= 50 ether, "seed too small for whole-token buys: fee layer would never start");
    }

    /// The price must end up AT tickUpper. A price ABOVE it is a phantom quote with no liquidity behind
    /// it that any one-wei trade erases, and nothing else in this script can catch that.
    function validatePoolTick(int24 poolTick, int24 tickUpper) public pure {
        require(poolTick == tickUpper, "pool did not open AT SEED_TICK_UPPER (phantom price)");
    }

    /// @dev The v4 pool id for this hook's one canonical {ETH,PRISM} pool.
    function _poolId(address hookAddr) private pure returns (bytes32) {
        return keccak256(abi.encode(
            address(0),      // currency0 = ETH
            hookAddr,        // currency1 = PRISM (the hook itself)
            uint24(10000),   // fee
            int24(200),      // tickSpacing
            hookAddr         // hooks
        ));
    }

    function _extsload(bytes32 slot) private view returns (bytes32 v) {
        (bool ok, bytes memory ret) = POOL_MANAGER.staticcall(
            abi.encodeWithSignature("extsload(bytes32)", slot));
        require(ok && ret.length >= 32, "extsload failed");
        v = abi.decode(ret, (bytes32));
    }
}
