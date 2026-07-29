// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Finds a CREATE2 salt so the resulting hook address carries the exact Uniswap V4
///   hook-permission flag bits in its low 14 bits. Pure computation — no state, no broadcast.
library HookMiner {
    uint160 constant FLAG_MASK = 0x3FFF; // low 14 bits = the hook-permission bitmap

    /// @param deployer   the CREATE2 deployer (the canonical factory).
    /// @param flags      the required low-14-bit flag pattern (PrismHookV2 = 0x2040).
    /// @param creationCode  `type(PrismHookV2).creationCode`.
    /// @param args       abi-encoded constructor args.
    /// @param saltBase   offsets the search so the winning salt is not publicly predictable. The
    ///   canonical CREATE2 factory does not mix `msg.sender` into the salt, so a search that always
    ///   started at 0 would hand any observer the exact salt and let them squat the predicted address
    ///   to grief the deploy. Deriving the base from the deployer plus a bumpable nonce means a
    ///   squatted attempt can simply be re-mined somewhere unpredictable.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory args,
        bytes32 saltBase
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes32 initHash = keccak256(abi.encodePacked(creationCode, args));
        for (uint256 i = 0; i < 1_000_000; i++) {
            salt = saltBase ^ bytes32(i);
            hookAddress = address(uint160(uint256(
                keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(hookAddress) & FLAG_MASK == flags) return (hookAddress, salt);
        }
        revert("HookMiner: no salt found");
    }
}
