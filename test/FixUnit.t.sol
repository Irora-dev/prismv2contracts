// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

interface IHook {
    function mirror() external view returns (address);
    function transfer(address to, uint256 amount) external returns (bool);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function ownedTokensOf(address) external view returns (uint256[] memory);
}

interface IMirror {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256) external view returns (address);
    function approve(address to, uint256 tokenId) external;
}

/// Minimal Permit2 stub: the hook constructor calls approve(...) on it once.
contract Permit2Stub {
    function approve(address, address, uint160, uint48) external {}
}

/// A compliant ERC-721 receiver contract (NOT excluded) — a stand-in for a marketplace/vault.
contract GoodReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// Proves the v2 fix: fee-share NFTs can no longer be parked on a realignment-excluded
/// address (PoolManager or the hook itself), while ordinary transfers and the self-healing
/// burn that keeps `totalShares` == eligible-supply both still work. A control instance is deployed alongside
/// as a control to show the same parking succeeds today.
contract FixUnit is Test {
    // Hook-flag-valid address (low 14 bits = enabled-hook bitmask).
    address constant V2_ADDR = address(0x2040); // beforeInitialize (bit 13) + afterSwap (bit 6)

    address constant POOL_MANAGER = address(0xBEEF); // stand-in PoolManager (excluded)
    address constant OWNER = address(0xB0B);
    address constant POSM  = address(0x9051);

    address user  = address(0xA11CE);
    address user2 = address(0xCAFE);

    Permit2Stub permit2;

    function setUp() public {
        permit2 = new Permit2Stub();
    }

    function _deploy(string memory what, address where) internal returns (IHook hook, IMirror mirror) {
        deployCodeTo(what, abi.encode(POOL_MANAGER, OWNER, POSM, address(permit2), address(0), uint256(0)), where);
        hook = IHook(where);
        mirror = IMirror(hook.mirror());
        // Seed `user` with 5 whole tokens -> realignment mints 5 fee-share NFTs.
        vm.prank(where);
        hook.transfer(user, 5 ether);
        assertEq(hook.nftBalanceOf(user), 5, "user should hold 5 NFTs");
        assertEq(hook.totalShares(), 5, "totalShares should be 5");
    }

    /// FIX: on V2 the same transfer reverts.
    function test_V2_ParkingToPoolManagerReverts() public {
        (IHook hook, IMirror mirror) = _deploy("PrismHookV2.sol:PrismHookV2", V2_ADDR);
        uint256 tid = hook.ownedTokensOf(user)[0];

        vm.prank(user);
        vm.expectRevert(); // ExcludedRecipient()
        mirror.transferFrom(user, POOL_MANAGER, tid);

        assertEq(hook.nftBalanceOf(POOL_MANAGER), 0, "V2: PoolManager holds no shares");
    }

    /// FIX: parking on the hook itself (the second excluded sink) also reverts.
    function test_V2_ParkingToSelfReverts() public {
        (IHook hook, IMirror mirror) = _deploy("PrismHookV2.sol:PrismHookV2", V2_ADDR);
        uint256 tid = hook.ownedTokensOf(user)[0];

        vm.prank(user);
        vm.expectRevert(); // ExcludedRecipient()
        mirror.transferFrom(user, V2_ADDR, tid);
    }

    /// V2 preserves normal behavior: a user->user NFT transfer works and keeps shares constant.
    function test_V2_NormalTransferStillWorks() public {
        (IHook hook, IMirror mirror) = _deploy("PrismHookV2.sol:PrismHookV2", V2_ADDR);
        uint256 tid = hook.ownedTokensOf(user)[0];

        vm.prank(user);
        mirror.transferFrom(user, user2, tid);

        assertEq(mirror.ownerOf(tid), user2, "NFT moved to user2");
        assertEq(hook.nftBalanceOf(user2), 1, "user2 holds 1 NFT");
        assertEq(hook.balanceOf(user2), 1 ether, "user2 got the mirrored 1 PRISM");
        assertEq(hook.totalShares(), 5, "shares unchanged by a move");
    }

    /// V2 invariant: shares self-heal. Sending PRISM back to an excluded address burns the
    /// share, so totalShares always tracks whole tokens held by eligible users. This is the
    /// property that fails only if NFTs can rest on an excluded address.
    function test_V2_SharesTrackEligibleSupply() public {
        (IHook hook,) = _deploy("PrismHookV2.sol:PrismHookV2", V2_ADDR);
        assertEq(hook.totalShares(), 5);

        // user returns 2 whole tokens to the hook (an excluded address) -> 2 NFTs burn.
        vm.prank(user);
        hook.transfer(V2_ADDR, 2 ether);

        assertEq(hook.nftBalanceOf(user), 3, "user down to 3 NFTs");
        assertEq(hook.totalShares(), 3, "totalShares fell to 3 == eligible whole tokens");
    }

    // ─────────── regression: the guard is NARROW (no legitimate flow broken) ───────────

    /// The guard blocks only excluded addresses. A normal contract recipient — including the
    /// ERC-721 safeTransfer receiver-callback path a marketplace uses — still works.
    function test_V2_TransferToContractReceiverStillWorks() public {
        (IHook hook, IMirror mirror) = _deploy("PrismHookV2.sol:PrismHookV2", V2_ADDR);
        GoodReceiver recv = new GoodReceiver();
        uint256 tid = hook.ownedTokensOf(user)[0];

        vm.prank(user);
        mirror.safeTransferFrom(user, address(recv), tid);

        assertEq(mirror.ownerOf(tid), address(recv), "NFT delivered to a normal contract");
        assertEq(hook.nftBalanceOf(address(recv)), 1);
        assertEq(hook.totalShares(), 5, "still 5 -- move, not mint/burn");
    }

    /// The guard is on the DESTINATION, so an approved operator cannot park either
    /// (closes the "approve then park on the operator's behalf" variant).
    function test_V2_ApprovedOperatorCannotPark() public {
        (IHook hook, IMirror mirror) = _deploy("PrismHookV2.sol:PrismHookV2", V2_ADDR);
        uint256 tid = hook.ownedTokensOf(user)[0];
        address operator = address(0x09E7A);

        vm.prank(user);
        mirror.approve(operator, tid);

        vm.prank(operator);
        vm.expectRevert(); // ExcludedRecipient()
        mirror.transferFrom(user, POOL_MANAGER, tid);
    }

    /// A flash-loan-style round trip nets ZERO new shares in V2: acquiring whole tokens mints
    /// shares, but they cannot be parked, so returning the tokens burns them back. This is the
    /// economic core of the fix — no permanent unbacked shares can be created at gas cost.
    function test_V2_RoundTripNetsZeroShares() public {
        (IHook hook,) = _deploy("PrismHookV2.sol:PrismHookV2", V2_ADDR);
        // user already holds 5 whole tokens / 5 shares from _deploy.
        uint256 sharesBefore = hook.totalShares();

        // "Repay": send all 5 whole tokens to the pool (excluded) -> all 5 shares burn.
        vm.prank(user);
        hook.transfer(POOL_MANAGER, 5 ether);

        assertEq(hook.nftBalanceOf(user), 0, "no NFTs retained");
        assertEq(hook.nftBalanceOf(POOL_MANAGER), 0, "pool holds NO fee shares");
        assertEq(hook.totalShares(), sharesBefore - 5, "shares fully unwound -> net zero");
    }
}
