// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {PrismMigration} from "../src/PrismMigration.sol";

/// The airdrop vault is created in the FIRST broadcast transaction and consumed as a CONSTRUCTOR
/// ARGUMENT by the second, which mints 4454.677 PRISM — 89% of supply — to it. While the vault was
/// created with `new`, its address moved with the deployer's nonce, and two things followed:
///
///   * A re-run mined a DIFFERENT hook address (different vault -> different initcode hash), so
///     `require(predicted.code.length == 0)` passed and produced a SECOND complete 5,000 PRISM system
///     with the first orphaned — while both the script and the runbook promised a re-run would revert.
///   * If the vault's own transaction failed while the hook's landed, the reserve was minted to an
///     address where nothing could ever be deployed again: only the deployer at that exact nonce could
///     have deployed there, and nonces only move forward. Terminal, 89% of supply.
///
/// Deploying the vault through the CREATE2 factory removes the nonce from the address entirely. These
/// tests pin that, because nothing else in the suite exercises the vault deployment path — `DeployFork`
/// hand-rolls a launch with no airdrop at all, so a regression here would otherwise be invisible.
contract VaultDeterminismFork is Test {
    uint256 constant FORK_BLOCK = 25604624;

    Deploy d;
    address constant OWNER = address(0xB0B);
    bytes32 constant ROOT  = 0x2cd60218d3f802a855996dbcbf7db5db860f88c541468c7601e02e627d33e12f;
    uint256 constant NONCE = 0xC0FFEE;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        d = new Deploy();
    }

    /// The address does not depend on the deployer's nonce. This is the whole property.
    function test_VaultAddressIsIndependentOfTheDeployerNonce() public {
        address before_ = d.vaultAddressFor(OWNER, ROOT, NONCE);

        // Move the deployer's nonce the way a stuck, cancelled or sped-up wallet transaction would.
        vm.setNonce(OWNER, vm.getNonce(OWNER) + 17);
        assertEq(d.vaultAddressFor(OWNER, ROOT, NONCE), before_, "vault address moved with the nonce");

        // And it really is where the deployment lands, at that same address, after the nonce moved.
        address deployed = d.deployVaultIfAbsent(OWNER, ROOT, NONCE);
        assertEq(deployed, before_, "vault did not land at its predicted address");
        assertGt(deployed.code.length, 0, "no code at the vault address");
        assertEq(PrismMigration(deployed).merkleRoot(), ROOT, "wrong root at the vault address");
    }

    /// Idempotent: a second call accepts the vault already there rather than making another. This is
    /// what lets a re-run get as far as the hook's already-deployed check instead of diverging here.
    function test_DeployingTwiceReturnsTheSameVaultAndDoesNotCreateASecond() public {
        address first  = d.deployVaultIfAbsent(OWNER, ROOT, NONCE);
        address second = d.deployVaultIfAbsent(OWNER, ROOT, NONCE);
        assertEq(second, first, "a second call produced a different vault");
    }

    /// The recovery property, stated directly: an address that the hook has already been told about can
    /// still be filled in afterwards. Under the old `new`-based deploy this was impossible, which is
    /// what made the 89%-of-supply state terminal rather than merely bad.
    function test_AVaultAddressTheHookAlreadyKnowsCanStillBeFilledInLater() public {
        address predicted = d.vaultAddressFor(OWNER, ROOT, NONCE);
        assertEq(predicted.code.length, 0, "precondition: nothing deployed there yet");

        // The hook would have been constructed with `predicted` and minted the reserve to it while it
        // was still codeless — the exact failure state. Recovery is simply deploying it now.
        address recovered = d.deployVaultIfAbsent(OWNER, ROOT, NONCE);
        assertEq(recovered, predicted, "recovery did not reach the address the hook was given");
        assertGt(recovered.code.length, 0, "recovery deployed nothing");

        // The claim this test is named for is that the recovered vault can be WIRED — without that,
        // reaching the address recovers nothing and the reserve is still lost. This previously asserted
        // `token() == address(0)`, which is true of any fresh vault whether or not it can ever be wired;
        // it could not fail, and that is precisely how a critical bug shipped green underneath it. Assert
        // the reachable-deployer property instead.
        assertEq(PrismMigration(recovered).deployer(), OWNER, "recovered vault cannot be wired by the launch key");
    }

    /// Different configurations must not collide, or one launch could be steered onto another's vault.
    function test_DistinctConfigurationsGetDistinctVaults() public {
        address a = d.vaultAddressFor(OWNER, ROOT, NONCE);
        assertTrue(a != d.vaultAddressFor(address(0xA11CE), ROOT, NONCE), "owner does not affect it");
        assertTrue(a != d.vaultAddressFor(OWNER, ROOT, NONCE + 1),        "salt nonce does not affect it");
        assertTrue(a != d.vaultAddressFor(OWNER, bytes32(uint256(1)), NONCE), "root does not affect it");
    }

    /// The vault salt is domain-separated from the hook's, even though both derive from the same
    /// (owner, chainid, SALT_NONCE) triple.
    function test_VaultSaltCannotCollideWithTheHookSaltBase() public view {
        bytes32 hookSaltBase = keccak256(abi.encode(OWNER, block.chainid, NONCE));
        assertTrue(d.vaultSalt(OWNER, NONCE) != hookSaltBase, "vault and hook salts collide");
    }

    /// The root is bound into the address, so a vault built for one root is never reachable as the vault
    /// for another. Named for what it actually shows: I cannot construct a same-address/different-root
    /// collision to exercise the `different root` require directly — that would need a keccak preimage —
    /// so this pins the property that makes the require unreachable in practice rather than the require.
    function test_TheRootIsBoundIntoTheVaultAddress() public {
        bytes32 otherRoot = bytes32(uint256(0xBEEF));
        address occupied = d.deployVaultIfAbsent(OWNER, otherRoot, NONCE);
        assertEq(PrismMigration(occupied).merkleRoot(), otherRoot, "deployed with the root it was asked for");
        assertTrue(d.vaultAddressFor(OWNER, ROOT, NONCE) != occupied, "two roots share one vault address");
    }

    /// A zero root is refused: it would mean an airdrop whose tree commits to nothing.
    function test_RefusesAZeroMerkleRoot() public {
        vm.expectRevert(bytes("vault needs a nonzero merkle root"));
        d.deployVaultIfAbsent(OWNER, bytes32(0), NONCE);
    }
}
