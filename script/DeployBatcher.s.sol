// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PrismAirdropBatcher, IPrismMigrationB} from "../src/PrismAirdropBatcher.sol";

/// @notice Deploy the airdrop batcher. Optional and entirely separate from the token deploy — the
///   batcher only calls the vault's permissionless `claim`, so it can be deployed by anyone, at any
///   time, as many times as you like. It holds no funds and has no owner.
///
///   MIGRATION=<vault address> forge script script/DeployBatcher.s.sol --rpc-url $RPC_URL \
///     --account <keystore> --broadcast --verify
contract DeployBatcher is Script {
    function run() external {
        address migration = vm.envAddress("MIGRATION");
        require(migration.code.length > 0, "MIGRATION has no code");

        vm.startBroadcast();
        PrismAirdropBatcher batcher = new PrismAirdropBatcher(IPrismMigrationB(migration));
        vm.stopBroadcast();

        require(address(batcher.migration()) == migration, "wiring mismatch");

        console2.log("PrismAirdropBatcher :", address(batcher));
        console2.log("wired to vault      :", migration);
        console2.log("Next: node merkle/push-airdrop.mjs --batcher", address(batcher));
    }
}
