// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IHookDeploy {
    function seed(uint160, int24, int24, uint128) external returns (uint256);
    function seeded() external view returns (bool);
    function owner() external view returns (address);
    function mirror() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function renounceOwnership() external;
}

/// Mines a CREATE2 salt so the deployed address carries the exact V4 hook-permission flag bits.
library HookMiner {
    uint160 constant FLAG_MASK = 0x3FFF; // low 14 bits = the hook-permission bitmap
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory args)
        internal pure returns (address addr, bytes32 salt)
    {
        bytes32 initHash = keccak256(abi.encodePacked(creationCode, args));
        for (uint256 i = 0; i < 300_000; i++) {
            salt = bytes32(i);
            addr = address(uint160(uint256(
                keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(addr) & FLAG_MASK == flags) return (addr, salt);
        }
        revert("HookMiner: no salt found");
    }
}

/// Demonstrates and validates the full v2 deployment procedure against real mainnet infra:
/// mine a flag-valid address -> CREATE2-deploy the hook -> seed the pool -> renounce ownership.
contract DeployFork is Test {
    // Real mainnet infra.
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2       = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // CREATE2_FACTORY (0x4e59…4956C, the canonical deterministic-deployment proxy) is inherited
    // from forge-std Test.

    address constant OWNER = address(0xB0B);
    uint160 constant FLAGS = 0x2040; // beforeInitialize (1<<13) | afterSwap (1<<6)
    uint256 constant FORK_BLOCK = 25604624;

    function test_FullDeploySeedRenounce() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        // 1) Mine a salt so the hook address has exactly the right permission flags.
        bytes memory creationCode = vm.getCode("PrismHookV2.sol:PrismHookV2");
        bytes memory args = abi.encode(POOL_MANAGER, OWNER, POSM, PERMIT2, address(0), uint256(0));
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_FACTORY, FLAGS, creationCode, args);
        assertEq(uint160(predicted) & 0x3FFF, FLAGS, "mined address carries the hook flags");
        console2.log("mined hook address:", predicted);

        // 2) CREATE2-deploy the hook through the canonical factory.
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode, args));
        require(ok, "create2 deploy failed");
        assertGt(predicted.code.length, 0, "hook deployed at the mined address");
        IHookDeploy hook = IHookDeploy(predicted);
        assertEq(hook.balanceOf(predicted), 5000 ether, "supply minted to hook");
        assertEq(hook.owner(), OWNER, "owner set");

        // 3) Seed the pool (single-sided PRISM), one-shot.
        vm.prank(OWNER);
        uint256 tokenId = hook.seed(3648751508805509367250261525102, -887200, 76600, 80e18);
        assertTrue(hook.seeded(), "seeded");
        assertGt(tokenId, 0, "position minted");

        // 4) Renounce ownership -> fully immutable, no admin.
        vm.prank(OWNER);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(0), "ownership renounced -> no admin");

        console2.log("deploy OK; position tokenId:", tokenId);
    }
}
