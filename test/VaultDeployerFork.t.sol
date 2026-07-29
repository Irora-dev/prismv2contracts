// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {PrismMigration} from "../src/PrismMigration.sol";

/// The vault is deployed through the canonical CREATE2 factory so its address does not depend on the
/// deployer's nonce. That introduced a critical bug, and this file exists so it can never return.
///
/// `PrismMigration` used to take its `deployer` from `msg.sender`. Deployed through the factory, the
/// factory IS `msg.sender` — and the factory's 69-byte runtime contains `CREATE2` and `RETURN` and no CALL
/// opcode of any kind, so `msg.sender == factory` is unreachable on a call. `setToken` was therefore
/// permanently uncallable by anyone: the deploy aborted in simulation (fail-safe), but the documented
/// hand-recovery path would have minted 4454.677 PRISM — 89% of supply — into a vault that could never be
/// wired to a token and has no sweep, and the renounce guard would then have refused forever, leaving a
/// live owner key. `deployer` is now an explicit constructor argument.
///
/// Why this went unnoticed for a whole commit: nothing called `setToken` on a CREATE2-deployed vault.
/// `DeployFork` hand-rolls a launch with NO airdrop, so it constructs no vault at all; every other test
/// builds one with `new` from the test contract, which makes the test the deployer and works fine; and the
/// recovery test in `VaultDeterminismFork.t.sol` asserted `token() == address(0)`, which is true of a
/// fresh vault whether or not it can ever be wired. An assertion that cannot fail is not a test.
contract VaultDeployerFork is Test {
    uint256 constant FORK_BLOCK = 25604624;
    address  constant FACTORY   = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    Deploy d;
    bytes32 constant ROOT  = 0x2cd60218d3f802a855996dbcbf7db5db860f88c541468c7601e02e627d33e12f;
    uint256 constant NONCE = 0xC0FFEE;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        d = new Deploy();
    }

    /// The launch key — not the factory — is the vault's deployer, and it can actually wire the token.
    /// This is the assertion whose absence let the bug ship.
    function test_TheLaunchKeyCanWireAFactoryDeployedVault() public {
        address owner = address(this);
        address vault = d.deployVaultIfAbsent(owner, ROOT, NONCE);

        assertEq(PrismMigration(vault).deployer(), owner, "deployer is not the launch key");
        assertTrue(PrismMigration(vault).deployer() != FACTORY, "deployer is the CREATE2 factory");

        // A token needs code and a nonzero vault balance to be accepted, so stand one up.
        MinimalToken t = new MinimalToken();
        t.mintTo(vault, 4454677055887032075331);
        PrismMigration(vault).setToken(address(t));
        assertEq(PrismMigration(vault).token(), address(t), "setToken did not take effect");
    }

    /// And nobody else can wire it, so making the deployer an argument did not widen access.
    function test_OnlyTheNamedDeployerCanWireIt() public {
        address vault = d.deployVaultIfAbsent(address(this), ROOT, NONCE);
        MinimalToken t = new MinimalToken();
        t.mintTo(vault, 1 ether);

        vm.prank(address(0xBEEF));
        vm.expectRevert(PrismMigration.NotDeployer.selector);
        PrismMigration(vault).setToken(address(t));

        vm.prank(FACTORY);
        vm.expectRevert(PrismMigration.NotDeployer.selector);
        PrismMigration(vault).setToken(address(t));
    }

    /// The deployer is part of the initcode, so it is bound into the address: a squatter cannot occupy the
    /// predicted address with a vault naming themselves. This is the same protection the root already had.
    function test_TheDeployerIsBoundIntoTheVaultAddress() public view {
        address mine   = d.vaultAddressFor(address(this), ROOT, NONCE);
        address theirs = d.vaultAddressFor(address(0xBEEF), ROOT, NONCE);
        assertTrue(mine != theirs, "two deployers share one vault address");
        // Same salt, different deployer argument => different initcode => different address.
        assertTrue(
            keccak256(d.vaultInitCode(ROOT, address(this))) != keccak256(d.vaultInitCode(ROOT, address(0xBEEF))),
            "the deployer argument does not enter the initcode"
        );
    }

    /// A zero deployer would be a vault nobody could ever wire, so the constructor refuses it outright.
    function test_AZeroDeployerIsRefused() public {
        vm.expectRevert(PrismMigration.ZeroDeployer.selector);
        new PrismMigration(ROOT, address(0));
    }

    /// The guard in `deployVaultIfAbsent` catches an adopted vault naming the wrong deployer, rather than
    /// trusting that the constructor argument was right.
    function test_AdoptingAVaultWithTheWrongDeployerIsRefused() public {
        address owner = address(this);
        address predicted = d.vaultAddressFor(owner, ROOT, NONCE);
        // Etch a vault at the predicted address whose root matches but whose deployer does not — the shape
        // the old bug produced, where the root check passed and nothing looked at the deployer.
        PrismMigration decoy = new PrismMigration(ROOT, address(0xBEEF));
        vm.etch(predicted, address(decoy).code);
        // `deployer` and `merkleRoot` are immutable, i.e. baked into the runtime code, so the etched copy
        // reports the decoy's values.
        assertEq(PrismMigration(predicted).merkleRoot(), ROOT, "etched vault should match on root");
        assertEq(PrismMigration(predicted).deployer(), address(0xBEEF), "etched vault keeps its deployer");

        vm.expectRevert(bytes("vault names a deployer that cannot wire it"));
        d.deployVaultIfAbsent(owner, ROOT, NONCE);
    }
}

contract MinimalToken {
    mapping(address => uint256) public balanceOf;
    function mintTo(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}
