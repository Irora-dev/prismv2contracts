// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PrismMigration} from "../src/PrismMigration.sol";

interface IHookM {
    function seed(uint160, int24, int24, uint128) external returns (uint256);
    function renounceOwnership() external;
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function MIGRATION_VAULT() external view returns (address);
}

library HookMiner2 {
    uint160 constant FLAG_MASK = 0x3FFF;
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
        revert("no salt");
    }
}

/// Full snapshot-airdrop flow on a mainnet fork: deploy the migration vault, CREATE2-deploy the
/// hook (which mints the reserve to the excluded vault), wire the token, seed, renounce, then a
/// holder claims and receives their v2 PRISM + fee-share NFTs.
contract MigrationFork is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2       = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER = address(0xB0B);
    uint160 constant FLAGS = 0x2040;
    uint256 constant FORK_BLOCK = 25604624;

    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B2);
    uint256 constant AMT_A = 100 ether;
    uint256 constant AMT_B = 50 ether;

    PrismMigration migration;
    IHookM hook;
    bytes32 leafA;
    bytes32 leafB;

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }
    function _hashPair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x <= y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        // 1) Build a 2-leaf snapshot tree and deploy the migration vault with its root.
        leafA = _leaf(ALICE, AMT_A);
        leafB = _leaf(BOB, AMT_B);
        bytes32 root = _hashPair(leafA, leafB);
        migration = new PrismMigration(root, address(this));

        // 2) Mine + CREATE2-deploy the hook, minting AMT_A+AMT_B to the (excluded) vault.
        bytes memory creationCode = vm.getCode("PrismHookV2.sol:PrismHookV2");
        bytes memory args = abi.encode(POOL_MANAGER, OWNER, POSM, PERMIT2, address(migration), AMT_A + AMT_B);
        (address predicted, bytes32 salt) = HookMiner2.find(CREATE2_FACTORY, FLAGS, creationCode, args);
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode, args));
        require(ok, "deploy failed");
        hook = IHookM(predicted);

        // 3) Wire the token, seed the pool with the hook's (non-reserved) balance, renounce.
        migration.setToken(predicted);
        vm.prank(OWNER);
        hook.seed(3648751508805509367250261525102, -887200, 76600, 80e18);
        vm.prank(OWNER);
        hook.renounceOwnership();
    }

    function test_ReserveHeldByExcludedVault() public view {
        assertEq(hook.MIGRATION_VAULT(), address(migration), "vault wired into the token");
        assertEq(hook.balanceOf(address(migration)), AMT_A + AMT_B, "reserve minted to the vault");
        // Critical: the reserve mints NO fee-shares (vault is excluded) -> no dilution of holders.
        assertEq(hook.nftBalanceOf(address(migration)), 0, "vault holds ZERO fee-shares");
    }

    function test_HolderClaimsAndGetsFeeShares() public {
        uint256 sharesBefore = hook.totalShares();

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;                                  // Alice's proof is Bob's leaf
        migration.claim(ALICE, AMT_A, proof);

        assertEq(hook.balanceOf(ALICE), AMT_A, "Alice received her v2 PRISM");
        assertEq(hook.nftBalanceOf(ALICE), AMT_A / 1 ether, "and her fee-share NFTs minted");
        assertEq(hook.totalShares(), sharesBefore + AMT_A / 1 ether, "shares grew by exactly her backing");
        assertEq(hook.balanceOf(address(migration)), AMT_B, "vault down to the remaining reserve");
        assertTrue(migration.claimed(ALICE), "marked claimed");

        // Double-claim reverts.
        vm.expectRevert();
        migration.claim(ALICE, AMT_A, proof);
    }

    function test_InvalidProofAndWrongAmountRevert() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        // Wrong amount -> different leaf -> proof fails.
        vm.expectRevert();
        migration.claim(ALICE, AMT_A + 1, proof);
        // Non-snapshot account -> fails.
        vm.expectRevert();
        migration.claim(address(0xDEAD), AMT_A, proof);
    }
}
