// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {PrismMigration} from "../src/PrismMigration.sol";

interface IHookSeedCall {
    function seed(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external returns (uint256);
}

interface IHookRead {
    function balanceOf(address) external view returns (uint256);
    function seeded() external view returns (bool);
    function owner() external view returns (address);
    function MIGRATION_VAULT() external view returns (address);
    function hookPositionTokenId() external view returns (uint256);
}

/// Runs the WHOLE launch sequence the way an operator does — vault, hook, `setToken`, `seed()` — against
/// real mainnet Uniswap v4, **with an airdrop configured**, at the shipped tick-44800 configuration.
///
/// This test exists because its absence let a critical bug ship green. `PrismMigration` took its `deployer`
/// from `msg.sender`; once the vault moved to CREATE2 that became the FACTORY, whose runtime holds no CALL
/// opcode, so `setToken` was permanently uncallable and the airdrop could never be wired. 192 tests passed
/// anyway, because **nothing exercised this path**: `DeployFork` hand-rolls a launch with `MIGRATION_AMOUNT
/// = 0` and therefore builds no vault at all, and every other test constructs the vault with `new` from the
/// test contract, which makes the test the deployer and works fine.
///
/// So the property under test is deliberately end-to-end rather than unit-shaped: with an airdrop
/// configured, every step of the real sequence must succeed and leave a state the renounce step accepts.
contract DeployFullRunFork is Test {
    uint256 constant FORK_BLOCK = 25604624;
    address constant FACTORY    = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // The shipped configuration (DEPLOY.md section 2 / merkle/make-env.mjs).
    bytes32 constant ROOT       = 0x2cd60218d3f802a855996dbcbf7db5db860f88c541468c7601e02e627d33e12f;
    uint256 constant RESERVE    = 4454677055887032075331;
    uint160 constant SHIP_SQRT  = 744133035780855425119189031190;
    int24   constant TICK_LOWER = -887200;
    int24   constant TICK_UPPER = 44800;
    uint128 constant LIQUIDITY  = 58060767042176831420;
    uint256 constant TARGET_FDV = 56679759771485417094;
    uint256 constant NONCE      = 0xC0FFEE;
    uint256 constant SUPPLY     = 5000 ether;

    Deploy d;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        d = new Deploy();
    }

    function test_TheWholeLaunchSequenceWorksWithAnAirdropConfigured() public {
        address owner = address(this);

        // --- step 1: the vault, deployed deterministically through the CREATE2 factory --------------
        address vault = d.deployVaultIfAbsent(owner, ROOT, NONCE);
        assertEq(vault, d.vaultAddressFor(owner, ROOT, NONCE), "vault is not at its predicted address");
        assertEq(PrismMigration(vault).merkleRoot(), ROOT, "wrong root");
        // The bug in one assertion: this was the FACTORY, and nothing checked it.
        assertEq(PrismMigration(vault).deployer(), owner, "the vault's deployer cannot wire it");
        assertTrue(PrismMigration(vault).deployer() != FACTORY, "deployer is the CREATE2 factory");

        // --- step 2: the hook, mined so its address carries the permission flags --------------------
        Deploy.RawConfig memory cfg = Deploy.RawConfig({
            merkleRoot:      ROOT,
            migrationAmount: RESERVE,
            treeTotal:       RESERVE,
            sqrtPriceX96:    SHIP_SQRT,
            tickLower:       TICK_LOWER,
            tickUpper:       TICK_UPPER,
            liquidity:       LIQUIDITY,
            targetFdvWei:    TARGET_FDV,
            saltNonce:       NONCE
        });
        d.validateConfig(cfg);   // the same validator the script runs

        address hook = d.deployHook(owner, vault, RESERVE, NONCE);
        assertEq(uint160(hook) & 0x3FFF, 0x2040, "mined address lacks the hook flags");
        assertEq(IHookRead(hook).balanceOf(vault), RESERVE, "reserve not minted to the vault");
        assertEq(IHookRead(hook).balanceOf(hook), SUPPLY - RESERVE, "float not left with the hook");
        assertEq(IHookRead(hook).MIGRATION_VAULT(), vault, "hook points at a different vault");

        // --- step 3: wire the token. THIS is the call that reverted NotDeployer() before the fix ----
        PrismMigration(vault).setToken(hook);
        assertEq(PrismMigration(vault).token(), hook, "setToken did not take effect");

        // --- step 4: seed, against the real PositionManager -----------------------------------------
        uint256 tokenId = IHookSeedCall(hook).seed(SHIP_SQRT, TICK_LOWER, TICK_UPPER, LIQUIDITY);
        assertTrue(IHookRead(hook).seeded(), "not seeded");
        assertEq(IHookRead(hook).hookPositionTokenId(), tokenId, "position not recorded");

        // The documented outcome, to the wei: the float is consumed bar the 1e9 rounding headroom.
        uint256 residual = IHookRead(hook).balanceOf(hook);
        assertEq(residual, 1000000004, "seed residual is not the documented headroom");

        // --- and the state the renounce step must accept --------------------------------------------
        // Not renouncing here: the script's owner check reads `msg.sender` while its broadcast acts as the
        // configured sender, and the two cannot both be satisfied from a test. Assert the three conditions
        // it checks instead, which is what makes this launch renounceable.
        assertTrue(vault.code.length > 0, "renounce would refuse: vault has no code");
        assertEq(PrismMigration(vault).token(), hook, "renounce would refuse: vault not wired");
        assertGe(uint256(LIQUIDITY), 58054960965472613736, "renounce would refuse: below the seed floor");
        assertEq(IHookRead(hook).owner(), owner, "owner should still hold at this point");

        console2.log("hook :", hook);
        console2.log("vault:", vault);
        console2.log("seeded PRISM (wei):", (SUPPLY - RESERVE) - residual);
    }

    /// A re-run must collide rather than mine a second system. With the vault at a nonce-derived address
    /// this silently produced a whole second 5,000 PRISM token.
    function test_ARerunCollidesInsteadOfMiningASecondSystem() public {
        address owner = address(this);
        address vault = d.deployVaultIfAbsent(owner, ROOT, NONCE);
        address hook  = d.deployHook(owner, vault, RESERVE, NONCE);

        // Move the deployer's nonce the way a stuck or cancelled wallet transaction would, then re-run.
        vm.setNonce(owner, vm.getNonce(owner) + 11);
        assertEq(d.deployVaultIfAbsent(owner, ROOT, NONCE), vault, "re-run produced a different vault");
        vm.expectRevert(bytes("predicted address already occupied - bump SALT_NONCE"));
        d.deployHook(owner, vault, RESERVE, NONCE);
        assertGt(hook.code.length, 0, "the original hook is still the only one");
    }
}
