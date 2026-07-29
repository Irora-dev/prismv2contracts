// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PrismMigration} from "../src/PrismMigration.sol";

interface IHookG {
    function seed(uint160, int24, int24, uint128) external returns (uint256);
    function renounceOwnership() external;
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
}

library HookMinerG {
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory args)
        internal pure returns (address addr, bytes32 salt)
    {
        bytes32 initHash = keccak256(abi.encodePacked(creationCode, args));
        for (uint256 i = 0; i < 300_000; i++) {
            salt = bytes32(i);
            addr = address(uint160(uint256(
                keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(addr) & 0x3FFF == flags) return (addr, salt);
        }
        revert("no salt");
    }
}

/// What does it actually cost to PUSH the airdrop out — i.e. the launcher submits every holder's
/// proof for them, so nobody has to claim? `PrismMigration.claim` is permissionless and always
/// delivers to `account`, so this needs no contract change. The cost driver is the DN404 mirror:
/// every whole PRISM delivered mints one fee-share NFT, so gas scales with the AMOUNT, not just
/// the number of recipients.
contract PushAirdropGas is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2      = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER        = address(0xB0B);
    uint160 constant FLAGS        = 0x2040;
    uint256 constant FORK_BLOCK   = 25604624;

    // A spread of realistic sizes from the published snapshot: the largest holder, a mid holder,
    // a small one, and a dust holder that owns less than one whole token (so mints no NFT).
    uint256 constant N = 4;

    PrismMigration migration;
    IHookG hook;
    address[N] holders;
    uint256[N] amounts;
    bytes32[N] leaves;

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }
    function _pair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x <= y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        holders[0] = address(0xA001); amounts[0] = 287.239345896629340786 ether; // largest holder
        holders[1] = address(0xA002); amounts[1] = 22.507010472550890405 ether;  // the LP wallet we added
        holders[2] = address(0xA003); amounts[2] = 1.5 ether;                    // small holder
        holders[3] = address(0xA004); amounts[3] = 0.000474798226967531 ether;   // dust, sub-1 token

        uint256 reserve;
        for (uint256 i; i < N; i++) {
            leaves[i] = _leaf(holders[i], amounts[i]);
            reserve += amounts[i];
        }
        // 4-leaf tree: root = pair(pair(l0,l1), pair(l2,l3))
        bytes32 root = _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
        migration = new PrismMigration(root, address(this));

        bytes memory creationCode = vm.getCode("PrismHookV2.sol:PrismHookV2");
        bytes memory args = abi.encode(POOL_MANAGER, OWNER, POSM, PERMIT2, address(migration), reserve);
        (address predicted, bytes32 salt) = HookMinerG.find(CREATE2_FACTORY, FLAGS, creationCode, args);
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode, args));
        require(ok, "deploy failed");
        hook = IHookG(predicted);

        migration.setToken(predicted);
        vm.prank(OWNER);
        hook.seed(3648751508805509367250261525102, -887200, 76600, 80e18);
        vm.prank(OWNER);
        hook.renounceOwnership();
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        if (i == 0)      { p[0] = leaves[1]; p[1] = _pair(leaves[2], leaves[3]); }
        else if (i == 1) { p[0] = leaves[0]; p[1] = _pair(leaves[2], leaves[3]); }
        else if (i == 2) { p[0] = leaves[3]; p[1] = _pair(leaves[0], leaves[1]); }
        else             { p[0] = leaves[2]; p[1] = _pair(leaves[0], leaves[1]); }
    }

    /// Push each holder's allocation to them (launcher pays) and report gas per whole token.
    function test_PushAirdropGasPerHolder() public {
        console2.log("=== push-distribution gas, by allocation size ===");
        uint256 total;
        for (uint256 i; i < N; i++) {
            uint256 g0 = gasleft();
            migration.claim(holders[i], amounts[i], _proof(i));
            uint256 used = g0 - gasleft();
            total += used;
            uint256 nfts = hook.nftBalanceOf(holders[i]);
            console2.log("  holder index          :", i);
            console2.log("    PRISM delivered (wei):", amounts[i]);
            console2.log("    fee-share NFTs minted:", nfts);
            console2.log("    gas used             :", used);
            if (nfts > 0) console2.log("    gas per NFT          :", used / nfts);
            assertEq(hook.balanceOf(holders[i]), amounts[i], "delivered");
        }
        console2.log("  total gas for these 4    :", total);
    }
}
