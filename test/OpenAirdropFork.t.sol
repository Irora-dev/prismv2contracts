// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deploy}      from "../script/Deploy.s.sol";
import {OpenAirdrop} from "../script/OpenAirdrop.s.sol";
import {PrismMigration} from "../src/PrismMigration.sol";

interface IHookIface {
    function balanceOf(address) external view returns (uint256);
    function seed(uint160, int24, int24, uint128) external returns (uint256);
    function seeded() external view returns (bool);
    function MIGRATION_VAULT() external view returns (address);
}

/// Opening the airdrop is a separate action from the deploy, so the ~545 PRISM float can trade for
/// hours before the 4454.677 PRISM reserve becomes movable. These pin the property that makes the split
/// real — that a full deploy leaves the airdrop CLOSED — and the guards on the step that opens it.
///
/// Why the property matters: `PrismMigration.claim` refuses while `token` is unset and is permissionless
/// once set, so `setToken` is a switch that opens the reserve to everyone at once. Inside the deploy it
/// would land one transaction BEFORE the pool is even created.
contract OpenAirdropFork is Test {
    uint256 constant FORK_BLOCK = 25604624;

    bytes32 constant ROOT       = 0x2cd60218d3f802a855996dbcbf7db5db860f88c541468c7601e02e627d33e12f;
    uint256 constant RESERVE    = 4454677055887032075331;
    uint160 constant SHIP_SQRT  = 744133035780855425119189031190;
    int24   constant TICK_LOWER = -887200;
    int24   constant TICK_UPPER = 44800;
    uint128 constant LIQUIDITY  = 58060767042176831420;
    uint256 constant NONCE      = 0xC0FFEE;

    Deploy d;
    OpenAirdrop opener;
    address vault;
    address hook;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        d = new Deploy();
        opener = new OpenAirdrop();
        vault = d.deployVaultIfAbsent(address(this), ROOT, NONCE);
        hook  = d.deployHook(address(this), vault, RESERVE, NONCE);
    }

    function _seed() internal {
        IHookIface(hook).seed(SHIP_SQRT, TICK_LOWER, TICK_UPPER, LIQUIDITY);
    }

    /// The deploy must leave the airdrop CLOSED. This is the whole point of the change.
    function test_ADeployedAndSeededLaunchLeavesTheAirdropClosed() public {
        _seed();
        assertTrue(IHookIface(hook).seeded(), "seeded");
        assertEq(IHookIface(hook).balanceOf(vault), RESERVE, "reserve is in the vault");
        // Closed: the token is unwired, so nothing can be distributed yet.
        assertEq(PrismMigration(vault).token(), address(0), "airdrop is already open after the deploy");
        // And an attempted claim really does refuse, rather than merely being unlikely to be tried.
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(PrismMigration.TokenNotSet.selector);
        PrismMigration(vault).claim(address(0xBEEF), 1, proof);
    }

    /// And the separate step opens it, over a live pool.
    function test_OpenAirdropWiresTheVault() public {
        _seed();
        opener.checkOpenAirdrop(hook, vault, RESERVE, address(this));   // every precondition holds
        PrismMigration(vault).setToken(hook);                          // what the script broadcasts
        assertEq(PrismMigration(vault).token(), hook, "vault was not wired");

        // And the gate is genuinely open: the same call that reverts `TokenNotSet` while closed now gets
        // as far as proof verification instead. Asserting the revert CHANGED is what shows the gate moved;
        // `token() != 0` is true either way and shows nothing.
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(PrismMigration.InvalidProof.selector);
        PrismMigration(vault).claim(address(0xBEEF), 1, proof);
    }

    /// Refuses before the pool exists — the sequencing this split exists to enforce.
    function test_RefusesToOpenOverAnUnseededPool() public {
        assertFalse(IHookIface(hook).seeded(), "precondition: not seeded");
        vm.expectRevert(bytes("pool is not seeded - seed before opening the airdrop"));
        opener.checkOpenAirdrop(hook, vault, RESERVE, address(this));
    }

    /// Refuses a second time, so a live distribution cannot be re-pointed mid-flight.
    function test_RefusesToReopenAnAlreadyOpenAirdrop() public {
        _seed();
        PrismMigration(vault).setToken(hook);          // this contract IS the vault's deployer
        vm.expectRevert(bytes("airdrop already open - token is wired"));
        opener.checkOpenAirdrop(hook, vault, RESERVE, address(this));
    }

    /// Refuses a mismatched hook/vault pair, in the direction a swapped argument would produce.
    function test_RefusesAVaultThisHookDoesNotName() public {
        _seed();
        address otherVault = d.deployVaultIfAbsent(address(this), bytes32(uint256(0xBEEF)), NONCE);
        assertTrue(otherVault != vault, "precondition: a different vault");
        vm.expectRevert(bytes("this hook does not name that vault"));
        opener.checkOpenAirdrop(hook, otherVault, RESERVE, address(this));
    }

    /// Refuses a wrong reserve figure, which would mean the wrong vault or a partial deploy.
    function test_RefusesAReserveThatDoesNotMatch() public {
        _seed();
        vm.expectRevert(bytes("vault does not hold the expected reserve"));
        opener.checkOpenAirdrop(hook, vault, RESERVE - 1, address(this));
    }

    /// Only the vault's deployer can open it, named clearly rather than surfacing as NotDeployer().
    function test_RefusesANonDeployerSender() public {
        _seed();
        vm.expectRevert(bytes("sender is not the vault's deployer"));
        opener.checkOpenAirdrop(hook, vault, RESERVE, address(0xBEEF));
    }

    /// A zero reserve means there is no airdrop, so there is nothing to open.
    function test_RefusesAZeroReserve() public {
        _seed();
        vm.expectRevert(bytes("RESERVE not set - there is no airdrop to open"));
        opener.checkOpenAirdrop(hook, vault, 0, address(this));
    }
}
