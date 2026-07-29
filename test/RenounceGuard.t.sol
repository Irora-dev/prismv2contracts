// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Renounce} from "../script/Renounce.s.sol";

/// Stands in for the hook so `seeded()`/`owner()` can be driven independently, without needing a
/// flag-valid CREATE2 deployment.
contract HookStub {
    bool public seeded;
    address public owner;
    bool public renounced;
    address public MIGRATION_VAULT;
    uint256 public hookPositionTokenId;
    address public POSM;
    function setSeeded(bool v) external { seeded = v; }
    function setOwner(address v) external { owner = v; }
    function setVault(address v) external { MIGRATION_VAULT = v; }
    function setPosition(address posm, uint256 id) external { POSM = posm; hookPositionTokenId = id; }
    function renounceOwnership() external { renounced = true; owner = address(0); }
}

/// Stands in for POSM's one liquidity view.
contract PosmStub {
    mapping(uint256 => uint128) public liq;
    function set(uint256 id, uint128 v) external { liq[id] = v; }
    function getPositionLiquidity(uint256 id) external view returns (uint128) { return liq[id]; }
}

/// Stands in for the airdrop vault. `token` is what `setToken` would have written.
contract VaultStub {
    address public token;
    function setToken(address v) external { token = v; }
}

/// Renouncing is the last irreversible action of the launch, and renouncing an UNSEEDED hook is
/// terminal: `seed()` is the only owner-gated function and nothing else can ever initialize the pool,
/// so the token would be inert with its entire supply stranded. These assert the guard refuses that.
///
/// The guards are exercised through `renounce(address)` rather than `run()` so no process-wide env var
/// is involved — `vm.setEnv` is global and forge runs a contract's tests in parallel, so env-driven
/// tests race and flake.
contract RenounceGuard is Test {
    Renounce script_;
    HookStub hook;

    function setUp() public {
        script_ = new Renounce();
        hook = new HookStub();
    }

    function test_RefusesToRenounceAnUnseededHook() public {
        hook.setSeeded(false);
        hook.setOwner(address(this));
        vm.expectRevert(bytes("hook is NOT seeded - renouncing now would brick it permanently"));
        script_.renounce(address(hook));
        assertFalse(hook.renounced(), "nothing was renounced");
    }

    function test_RefusesWhenSenderIsNotOwner() public {
        hook.setSeeded(true);
        hook.setOwner(address(0xDEADBEEF));
        vm.expectRevert(bytes("sender is not the current owner"));
        script_.renounce(address(hook));
        assertFalse(hook.renounced(), "nothing was renounced");
    }

    function test_RefusesACodelessHook() public {
        vm.expectRevert(bytes("HOOK has no code"));
        script_.renounce(address(0xC0DE1355));
    }

    /// And the happy path still works, so the guards are not simply blocking everything.
    function test_RenouncesASeededHookOwnedByTheSender() public {
        hook.setSeeded(true);
        // `renounce` is entered by an external call from this test, so its `msg.sender` — the address
        // the owner check compares against — is this contract, not the script.
        hook.setOwner(address(this));
        script_.renounce(address(hook));
        assertTrue(hook.renounced(), "renounced");
        assertEq(hook.owner(), address(0), "owner cleared");
    }

    /*──────────────────────────────────────────────────────────────────────────────────────────────*/
    /*  The vault post-conditions.                                                                  */
    /*                                                                                              */
    /*  The vault is created by the FIRST broadcast transaction and consumed as a constructor        */
    /*  argument by the SECOND, which mints the entire airdrop reserve to it. If the first fails      */
    /*  while the rest are mined, 89% of the supply is minted to an address that has no code and can  */
    /*  never have any. Before these checks existed, that state passed every remaining gate: the      */
    /*  three checks above only look at the hook, `setToken` against a codeless address succeeds       */
    /*  silently, and `Deploy.s.sol`'s own post-conditions run only in simulation, where the vault     */
    /*  always exists. Renouncing is the last transaction that can still refuse.                      */
    /*──────────────────────────────────────────────────────────────────────────────────────────────*/

    function _seededOwned() internal {
        hook.setSeeded(true);
        hook.setOwner(address(this));
    }

    function test_RefusesWhenTheAirdropVaultHasNoCode() public {
        _seededOwned();
        hook.setVault(address(0xBADC0DE)); // an address that never received a deployment
        vm.expectRevert(bytes("MIGRATION_VAULT has no code - the airdrop reserve is unreachable"));
        script_.renounce(address(hook));
        assertFalse(hook.renounced(), "nothing was renounced");
    }

    /// An UNWIRED vault must NOT block the renounce. Opening the airdrop is a separate step run hours
    /// after launch (`OpenAirdrop.s.sol`), so requiring it here would either force the airdrop open before
    /// the renounce — defeating the delay — or push the operator into leaving a live owner on the hook for
    /// a day. `setToken` is deployer-gated with no deadline, so deferring it is safe.
    function test_AnUnwiredVaultDoesNotBlockTheRenounce() public {
        _seededOwned();
        VaultStub vault = new VaultStub();   // deployed, but setToken has not run yet
        hook.setVault(address(vault));
        script_.renounce(address(hook));
        assertTrue(hook.renounced(), "an unopened airdrop blocked the renounce");
    }

    /// A vault wired to something that is not this hook is never legitimate: it would pay out a token no
    /// holder wants, and `tokenFinal` latches on the first claim, so it cannot be undone.
    function test_RefusesWhenTheVaultIsWiredToADifferentToken() public {
        _seededOwned();
        VaultStub vault = new VaultStub();
        vault.setToken(address(0xA11CE));    // wired, but not to this hook
        hook.setVault(address(vault));
        vm.expectRevert(bytes("MIGRATION_VAULT is wired to a different token - do NOT renounce"));
        script_.renounce(address(hook));
        assertFalse(hook.renounced(), "nothing was renounced");
    }

    function test_RenouncesWhenTheVaultIsPresentAndCorrectlyWired() public {
        _seededOwned();
        VaultStub vault = new VaultStub();
        vault.setToken(address(hook));
        hook.setVault(address(vault));
        script_.renounce(address(hook));
        assertTrue(hook.renounced(), "renounced");
    }

    /// A launch with no airdrop has no vault at all, and must still be renounceable.
    function test_RenouncesWithNoAirdropVaultConfigured() public {
        _seededOwned();
        hook.setVault(address(0));
        script_.renounce(address(hook));
        assertTrue(hook.renounced(), "renounced");
    }

    /*──────────────────────────────────────────────────────────────────────────────────────────────*/
    /*  The seeded-liquidity post-condition.                                                        */
    /*                                                                                              */
    /*  Every seed check in Deploy.s.sol runs in SIMULATION, and the runbook's own advice when a step */
    /*  reverts is to finish by hand — where `seed()` becomes a `cast send` with four typed values    */
    /*  and no validation at all. A dropped digit seeds a fraction of the float, strands the rest in  */
    /*  a contract about to become ownerless, and cannot be retried because `seed()` is one-shot.     */
    /*  Reading the POSITION rather than the transaction is what makes this hold on that path too.    */
    /*                                                                                              */
    /*  The floor is passed as an ARGUMENT, never via `vm.setEnv`. Setting it in one test leaked into    */
    /*  every test that did not set it — forge runs a contract's tests in parallel and the env is        */
    /*  process-global — which broke the happy-path test above until the entry point was parameterised.  */
    /*──────────────────────────────────────────────────────────────────────────────────────────────*/

    /// The shipped `MIN_SEED_LIQUIDITY`, i.e. SEED_LIQUIDITY less one part in ten thousand.
    uint256 constant FLOOR = 58054960965472613736;

    function _seededWithLiquidity(uint128 actual) internal returns (PosmStub posm) {
        _seededOwned();
        hook.setVault(address(0));
        posm = new PosmStub();
        posm.set(7, actual);
        hook.setPosition(address(posm), 7);
    }

    function test_RefusesWhenTheSeededLiquidityIsBelowTheFloor() public {
        _seededWithLiquidity(5_806_076_704_217_683_142);       // a dropped digit: 10% of intended
        vm.expectRevert(
            bytes("seeded liquidity is below MIN_SEED_LIQUIDITY - the pool was under-seeded, do NOT renounce")
        );
        script_.renounce(address(hook), FLOOR);
        assertFalse(hook.renounced(), "nothing was renounced");
    }

    function test_RenouncesWhenTheSeededLiquidityMeetsTheFloor() public {
        _seededWithLiquidity(58_060_767_042_176_831_420);      // the shipped SEED_LIQUIDITY
        script_.renounce(address(hook), FLOOR);
        assertTrue(hook.renounced(), "renounced");
    }

    /// A hook claiming to be seeded while holding no position is refused rather than read as zero.
    function test_RefusesWhenSeededButNoPositionExists() public {
        _seededOwned();
        hook.setVault(address(0));
        PosmStub posm = new PosmStub();
        hook.setPosition(address(posm), 0);
        vm.expectRevert(bytes("hook holds no LP position despite reporting seeded"));
        script_.renounce(address(hook), FLOOR);
    }

    /// Unset, the check is skipped and the vault guards still apply — so an operator on an older .env
    /// is never blocked by a variable they do not have.
    function test_SkipsTheLiquidityCheckWhenTheFloorIsUnset() public {
        _seededWithLiquidity(1);                               // absurdly low, but unchecked
        script_.renounce(address(hook), 0);                    // 0 = no floor
        assertTrue(hook.renounced(), "renounced");
    }
}
