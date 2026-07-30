// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PrismMigration} from "../src/PrismMigration.sol";

interface IHookRead {
    function balanceOf(address) external view returns (uint256);
    function MIGRATION_VAULT() external view returns (address);
    function seeded() external view returns (bool);
}

/// @title  Open the airdrop.
/// @notice The single action that makes the reserve distributable, and the last step of the launch that
///   needs the deploy key. Run it when the pool has had time to trade — hours, not seconds.
///
/// @dev Why this is not part of the deploy. `PrismMigration.claim` refuses while `token` is unset and is
///   permissionless once it is set, so `setToken` is the switch that opens the airdrop to everyone at
///   once. Wiring it inside `Deploy.s.sol` put 4454.677 PRISM — 89% of supply — into circulation in the
///   same four-transaction sequence that created the pool, and in fact one transaction *before* the pool
///   existed. That left no interval in which the ~545 PRISM float could trade before the rest of the
///   supply became movable.
///
///   Splitting it out is free because of where `setToken` lives: it is on the VAULT, not the hook, it is
///   gated on the vault's immutable `deployer`, and it has no deadline. So the hook can be seeded and
///   renounced immediately — buyers get an ownerless token from the first block — while the airdrop stays
///   wireable for as long as you like.
///
///   THE COST, and it is a real one: the deploy key gains a job that outlives the renounce. Until this
///   script runs, nothing but that key can open the airdrop, and there is no sweep and no alternative
///   path — so if it is lost in the interval, the entire reserve is stranded permanently. Renouncing the
///   hook does NOT retire the key; this does. Keep it exactly as safe as you did for the deploy.
///
///   Run:
///     HOOK=<hook> VAULT=<vault> RESERVE=<wei> \
///       forge script script/OpenAirdrop.s.sol --rpc-url $RPC --sender <deployer> \
///       --account <keystore> --broadcast
contract OpenAirdrop is Script {
    function run() external {
        openAirdrop(vm.envAddress("HOOK"), vm.envAddress("VAULT"), vm.envUint("RESERVE"));
    }

    /// @dev Parameterised so the guards are testable without process-wide env state — `vm.setEnv` is
    ///   global and forge runs a contract's tests in parallel, so env-driven tests race each other.
    function openAirdrop(address hookAddr, address vaultAddr, uint256 reserve) public {
        checkOpenAirdrop(hookAddr, vaultAddr, reserve, msg.sender);

        console2.log("hook   :", hookAddr);
        console2.log("vault  :", vaultAddr);
        console2.log("reserve:", reserve);

        vm.startBroadcast();
        PrismMigration(vaultAddr).setToken(hookAddr);
        vm.stopBroadcast();

        require(PrismMigration(vaultAddr).token() == hookAddr, "setToken did not take effect");
        console2.log("");
        console2.log("AIRDROP IS OPEN. The reserve is now distributable and `claim` is permissionless.");
        console2.log("Nothing further needs the deploy key. Next: deploy the batcher and run the push.");
    }

    /// @notice Every precondition for opening the airdrop, with no side effects.
    /// @dev Separate from the broadcast for the same reason `Renounce.s.sol` splits its checks: the guards
    ///   compare against `sender`, while `vm.startBroadcast()` signs as the CONFIGURED sender. In
    ///   production `--sender` makes those one address; in a test they cannot both be satisfied, because
    ///   pranking so `msg.sender` matches makes `startBroadcast` refuse outright. Taking the sender as an
    ///   argument makes every refusal directly testable, which is where the value is — the one-line
    ///   `setToken` that follows is not the part that can go wrong.
    function checkOpenAirdrop(address hookAddr, address vaultAddr, uint256 reserve, address sender)
        public view
    {
        require(hookAddr.code.length > 0, "HOOK has no code");
        require(vaultAddr.code.length > 0, "VAULT has no code");
        require(reserve > 0, "RESERVE not set - there is no airdrop to open");

        PrismMigration vault = PrismMigration(vaultAddr);
        IHookRead hook = IHookRead(hookAddr);

        // The hook names this vault. Checking both directions makes a swapped pair of addresses
        // impossible to wire, rather than merely unlikely: a vault pointed at the wrong hook would pay
        // out a token nobody holds, and `tokenFinal` latches on the first claim, so it is unrecoverable.
        require(hook.MIGRATION_VAULT() == vaultAddr, "this hook does not name that vault");

        // Only the vault's own deployer can wire it, and passing the wrong `--sender` here wastes a
        // transaction rather than doing damage — but say so by name instead of letting `NotDeployer()`
        // surface with no context.
        require(vault.deployer() == sender, "sender is not the vault's deployer");

        // Refuse to re-wire. `setToken` is deliberately correctable until the first claim, which is a
        // safety property, not an invitation: re-pointing a live airdrop mid-distribution would leave
        // some holders paid in one token and the rest in another.
        require(vault.token() == address(0), "airdrop already open - token is wired");

        // The reserve must actually be here. The hook mints it at construction, so a mismatch means
        // either the wrong vault or a partial deploy, and wiring on top of that would strand the lot.
        //
        // Deliberately `==`, and deliberately not `>=`. PRISM is an ordinary ERC-20, so a third party can
        // raise this balance by one wei and nothing can lower it before `setToken` -- which does mean a
        // stranger can make this exact check fail. That is worth living with, because RESERVE is read from
        // the chain rather than remembered: `launch.mjs` reads `balanceOf(vault)` immediately before this
        // step, and LAUNCH.md §10b tells a by-hand operator to do the same, so the griefer's wei is simply
        // included and the run proceeds. Relaxing to `>=` would buy immunity to a self-healing nuisance by
        // giving up the only check that a mistyped RESERVE is caught at all.
        require(hook.balanceOf(vaultAddr) == reserve, "vault does not hold the expected reserve");

        // Open the airdrop only over a live pool. This is the whole point of the split: if the pool were
        // never seeded there would be nothing to trade against, and putting 89% of supply in motion first
        // is the sequencing this script exists to prevent.
        require(hook.seeded(), "pool is not seeded - seed before opening the airdrop");
    }
}
