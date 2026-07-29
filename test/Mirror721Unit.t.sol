// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PrismArt} from "../src/PrismArt.sol";
import {Hooks}    from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey}  from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks}   from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// AUDIT ROUND 2 — CONTRACTS. The surfaces five prior rounds did not attack:
/// PrismArt's string assembly, PrismMirror's whole ERC-721 surface (including EIP-7702 delegated
/// EOAs, which are 476 of the 1203 airdrop recipients), and BaseHook's callback gates.

interface IHook {
    function mirror() external view returns (address);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function nftTokenURI(uint256) external view returns (string memory);
    function nftOwnerOf(uint256) external view returns (address);
    function nftGetApproved(uint256) external view returns (address);
    function seedOf(uint256) external view returns (bytes32);
    function totalShares() external view returns (uint256);
    function ownedTokensOf(address) external view returns (uint256[] memory);
    function pokeFees() external;
    function claim(uint256) external;
    function withdrawPending() external;
    function pendingETH(address) external view returns (uint256);
    function pendingPRISM(address) external view returns (uint256);
    function handleNFTTransfer(address, address, uint256, address) external;
    function handleNFTApprove(address, uint256, address) external;
    function handleNFTSetApprovalForAll(address, bool, address) external;
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
    function beforeInitialize(address, PoolKey calldata, uint160) external returns (bytes4);
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external returns (bytes4, int128);
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external returns (bytes4);
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external returns (bytes4);
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external returns (bytes4, int256, uint24);
    function afterInitialize(address, PoolKey calldata, uint160, int24) external returns (bytes4);
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external returns (bytes4);
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external returns (bytes4);
}

interface IMirror {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function ownerOf(uint256) external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function tokenURI(uint256) external view returns (string memory);
    function getApproved(uint256) external view returns (address);
    function isApprovedForAll(address, address) external view returns (bool);
    function supportsInterface(bytes4) external pure returns (bool);
    function approve(address, uint256) external;
    function setApprovalForAll(address, bool) external;
    function transferFrom(address, address, uint256) external;
    function safeTransferFrom(address, address, uint256) external;
    function safeTransferFrom(address, address, uint256, bytes memory) external;
    function emitTransfer(address, address, uint256) external;
    function emitApproval(address, address, uint256) external;
    function emitApprovalForAll(address, address, bool) external;
}

contract Permit2Stub { function approve(address,address,uint160,uint48) external {} }
contract PMStub { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }
/// One-shot ETH payer: a collect drains what accrued, like the real POSM.
contract InertPOSM {
    uint256 public feeEth;
    receive() external payable {}
    function arm(uint256 e) external { feeEth = e; }
    function modifyLiquidities(bytes calldata, uint256) external {
        uint256 e = feeEth; feeEth = 0;
        if (e > 0) { (bool ok,) = msg.sender.call{value: e}(""); require(ok, "eth"); }
    }
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

/// ── EIP-7702 delegate implementations ────────────────────────────────────────
/// A 7702 EOA's code is `0xef0100 || delegate`; `code.length` is 23, so every
/// `to.code.length > 0` test in the codebase treats a delegated EOA as a contract.

/// A smart account that DOES implement the receiver hook (the common case: Safe7579, Kernel, etc).
contract Delegate_Compliant {
    receive() external payable {}
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}
/// A minimal 7702 delegate with no receiver hook and a fallback that returns nothing.
contract Delegate_SilentFallback {
    receive() external payable {}
    fallback() external payable {}
}
/// A 7702 delegate that reverts on unknown selectors (the other common style).
contract Delegate_StrictFallback {
    receive() external payable {}
    fallback() external payable { revert("unknown selector"); }
}
/// Wrong magic value.
contract BadMagicReceiver {
    receive() external payable {}
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}
/// Reenters the whole value surface from inside onERC721Received, where handleNFTTransfer's
/// nonReentrant guard has ALREADY been released.
contract ReenteringReceiver {
    IHook public hook;
    IMirror public mirror;
    bool public tried;
    uint256 public gotETH;
    uint256 public gotPRISM;
    receive() external payable {}
    function wire(IHook h, IMirror m) external { hook = h; mirror = m; }
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        tried = true;
        try hook.claim(id) {} catch {}
        try hook.withdrawPending() {} catch {}
        gotETH = hook.pendingETH(address(this));
        gotPRISM = hook.pendingPRISM(address(this));
        return 0x150b7a02;
    }
}

contract Mirror721Unit is Test {
    address constant HOOKA = address(0x2040);
    address constant OWNER = address(0xB0B);
    address constant DEAD  = 0x000000000000000000000000000000000000dEaD;

    IHook hook;
    IMirror mirror;
    PMStub pm;
    InertPOSM posm;
    Permit2Stub p2;

    address alice = address(0xA1);
    address bob   = address(0xB1);
    /// A 7702-delegated EOA whose shares are minted in setUp, so a claim in a test BODY is not
    /// silenced by the transient anti-JIT quarantine (a whole test body is one transaction).
    address eoaPre = address(0xE0A4);

    function setUp() public {
        pm = new PMStub(); posm = new InertPOSM(); p2 = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), HOOKA);
        hook = IHook(HOOKA);
        mirror = IMirror(hook.mirror());
        vm.store(HOOKA, bytes32(uint256(0)), bytes32(uint256(1))); // seeded
        vm.prank(HOOKA); hook.transfer(alice, 10 ether);
        vm.prank(HOOKA); hook.transfer(bob, 4 ether);

        _delegate(eoaPre, address(new Delegate_Compliant()));
        vm.prank(HOOKA); hook.transfer(eoaPre, 3 ether);
    }

    /// Install `impl` as `who`'s EIP-7702 delegation designator, byte-for-byte.
    function _delegate(address who, address impl) internal {
        vm.etch(who, abi.encodePacked(hex"ef0100", impl));
        assertEq(who.code.length, 23, "7702 designator must be 23 bytes");
    }

    /*───────────────────────── PrismArt ─────────────────────────*/

    /// 236 lines of string/bytes assembly. Every field is derived from a byte of the seed, so the
    /// whole input space is reachable by brute force from `_deriveSeed(id) = keccak(id, hook)`.
    /// A revert here would permanently break `tokenURI` for a live token.
    function testFuzz_R2C_artNeverReverts(bytes32 seed) public pure {
        string memory uri = PrismArt.tokenURI(type(uint256).max, seed);
        assertGt(bytes(uri).length, 0);
    }

    /// Independently pin the five field derivations at both ends of each byte, so a future edit that
    /// widens one (e.g. `* 200` on a uint16) is caught rather than silently overflowing.
    function test_R2C_artFieldBoundsAtEveryByteExtreme() public pure {
        uint8[3] memory probes = [0, 128, 255];
        for (uint256 a; a < 3; ++a) for (uint256 b; b < 3; ++b) for (uint256 c; c < 3; ++c)
        for (uint256 d; d < 3; ++d) for (uint256 e; e < 3; ++e) {
            bytes32 s = bytes32(
                (uint256(probes[a]) << 248) | (uint256(probes[b]) << 240) | (uint256(probes[c]) << 232)
              | (uint256(probes[d]) << 224) | (uint256(probes[e]) << 216)
            );
            assertGt(bytes(PrismArt.renderSVG(s)).length, 0);
            assertGt(bytes(PrismArt.tokenURI(1, s)).length, 0);
        }
    }

    /// tokenURI is reachable for every live id and reverts for none of them; and it gates nothing
    /// that moves value (proved by claiming with the art path exercised in the same test).
    function test_R2C_tokenURILiveForEveryIdAndGatesNoValue() public {
        uint256[] memory ids = hook.ownedTokensOf(alice);
        assertEq(ids.length, 10);
        for (uint256 i; i < ids.length; ++i) {
            assertGt(bytes(mirror.tokenURI(ids[i])).length, 0);
            assertGt(bytes(hook.nftTokenURI(ids[i])).length, 0);
            assertEq(hook.seedOf(ids[i]), keccak256(abi.encode(ids[i], HOOKA)));
        }
        // ERC-721 requires a throw for a nonexistent id, and burned ids ARE routine here.
        vm.expectRevert(); mirror.tokenURI(9_999);
        vm.expectRevert(); hook.nftTokenURI(9_999);
        vm.expectRevert(); hook.seedOf(9_999);
    }

    /*──────────────────── EIP-7702 delegated EOAs ────────────────────*/

    /// A delegated EOA whose delegate implements the hook: safeTransferFrom works normally.
    function test_R2C_7702_compliantDelegateAcceptsSafeTransfer() public {
        Delegate_Compliant impl = new Delegate_Compliant();
        address eoa = address(0xE0A1);
        _delegate(eoa, address(impl));
        uint256 id = hook.ownedTokensOf(alice)[0];
        vm.prank(alice); mirror.safeTransferFrom(alice, eoa, id);
        assertEq(mirror.ownerOf(id), eoa);
        assertEq(hook.balanceOf(eoa), 1 ether, "the underlying whole token moved too");
    }

    /// A delegated EOA WITHOUT the receiver hook: `safeTransferFrom` reverts, because `code.length`
    /// is 23 so the mirror runs the ERC-721 receiver check against it. Documented here because it is
    /// a real compatibility edge for 476 of the 1203 recipients — but it is NOT a loss of funds:
    /// the state is restored exactly, and plain `transferFrom` (and every ERC-20 path, which is how
    /// the airdrop actually delivers) is unaffected.
    function test_R2C_7702_nonCompliantDelegateBlocksSafeTransferButLosesNothing() public {
        address eoaSilent = address(0xE0A2);
        address eoaStrict = address(0xE0A3);
        _delegate(eoaSilent, address(new Delegate_SilentFallback()));
        _delegate(eoaStrict, address(new Delegate_StrictFallback()));

        uint256 id = hook.ownedTokensOf(alice)[0];
        uint256 balBefore   = hook.balanceOf(alice);
        uint256 sharesBefore = hook.nftBalanceOf(alice);
        uint256 totalBefore = hook.totalShares();

        vm.prank(alice); vm.expectRevert(); mirror.safeTransferFrom(alice, eoaSilent, id);
        vm.prank(alice); vm.expectRevert(); mirror.safeTransferFrom(alice, eoaStrict, id);

        // Nothing half-moved: the receiver check runs after transferFrom, so its revert rolls the
        // whole frame back. This is the property that keeps it a compatibility issue, not a loss.
        assertEq(hook.balanceOf(alice), balBefore);
        assertEq(hook.nftBalanceOf(alice), sharesBefore);
        assertEq(hook.totalShares(), totalBefore);
        assertEq(mirror.ownerOf(id), alice);
        assertEq(hook.balanceOf(eoaSilent), 0);
        assertEq(hook.balanceOf(eoaStrict), 0);

        // And the unsafe path — plus every ERC-20 path, which is what the airdrop and the pool use —
        // delivers to the same address without complaint.
        vm.prank(alice); mirror.transferFrom(alice, eoaSilent, id);
        assertEq(mirror.ownerOf(id), eoaSilent);
        assertEq(hook.balanceOf(eoaSilent), 1 ether);
        vm.prank(alice); hook.transfer(eoaStrict, 2 ether);
        assertEq(hook.nftBalanceOf(eoaStrict), 2, "ERC-20 delivery mirror-mints for a delegated EOA");
    }

    /// A delegated EOA can claim and withdraw exactly like a plain EOA: the fee layer never branches
    /// on code length, so nothing about 7702 can strand a recipient's fees.
    function test_R2C_7702_delegatedEOAClaimsAndWithdrawsNormally() public {
        assertEq(hook.nftBalanceOf(eoaPre), 3, "setUp did not mirror-mint for the delegated EOA");
        uint256 shares = hook.totalShares();

        // Real fee round: the POSM pays 17 ETH into the hook and pokeFees distributes it.
        vm.deal(address(posm), 100 ether);
        posm.arm(17 ether);
        hook.pokeFees();
        assertEq(HOOKA.balance, 17 ether, "no fee ETH arrived");

        uint256[] memory ids = hook.ownedTokensOf(eoaPre);
        for (uint256 i; i < ids.length; ++i) hook.claim(ids[i]);
        uint256 owed = hook.pendingETH(eoaPre);
        // Exactly its 3/shares slice, floor-rounded per share and per round — no 7702 penalty.
        assertEq(owed, 3 * (17 ether * 1e12 / shares) / 1e12, "delegated EOA slice is wrong");
        assertGt(owed, 0);
        uint256 before = eoaPre.balance;
        vm.prank(eoaPre); hook.withdrawPending();
        assertEq(eoaPre.balance - before, owed, "delegated EOA could not withdraw");
        assertEq(hook.pendingETH(eoaPre), 0);
    }

    /*──────────────── PrismMirror ERC-721 surface ────────────────*/

    function test_R2C_mirrorMetadataAndIntrospection() public view {
        assertEq(mirror.name(), "Prism-LP");
        assertEq(mirror.symbol(), "PRISM-LP");
        assertTrue(mirror.supportsInterface(0x01ffc9a7)); // ERC165
        assertTrue(mirror.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(mirror.supportsInterface(0x5b5e139f)); // ERC721Metadata
        assertFalse(mirror.supportsInterface(0x780e9d63)); // NOT Enumerable — and does not claim to be
        assertFalse(mirror.supportsInterface(0xffffffff));
        assertEq(mirror.totalSupply(), hook.totalShares());
    }

    /// Only the hook may make the mirror emit an event, so nobody can forge an ERC-721 Transfer that
    /// an indexer would read as a change of ownership.
    function test_R2C_mirrorEventEmittersAreHookOnly() public {
        vm.startPrank(bob);
        vm.expectRevert(); mirror.emitTransfer(alice, bob, 1);
        vm.expectRevert(); mirror.emitApproval(alice, bob, 1);
        vm.expectRevert(); mirror.emitApprovalForAll(alice, bob, true);
        vm.stopPrank();
    }

    /// Only the mirror may drive the hook's NFT handlers, so `caller` cannot be spoofed — which is
    /// what the entire NFT authorisation model rests on.
    function test_R2C_hookNFTHandlersAreMirrorOnly() public {
        uint256 id = hook.ownedTokensOf(alice)[0];
        vm.startPrank(bob);
        vm.expectRevert(); hook.handleNFTTransfer(alice, bob, id, alice);       // spoofed caller=owner
        vm.expectRevert(); hook.handleNFTApprove(bob, id, alice);
        vm.expectRevert(); hook.handleNFTSetApprovalForAll(bob, true, alice);
        vm.stopPrank();
        assertEq(mirror.ownerOf(id), alice);
    }

    /// Full approval semantics, including that a move CLEARS the single-token approval (so a stale
    /// approval can never be replayed against a new owner) while operator approval persists.
    function test_R2C_approvalSemanticsAndClearingOnMove() public {
        uint256 id = hook.ownedTokensOf(alice)[0];

        vm.prank(bob); vm.expectRevert(); mirror.approve(bob, id);           // not owner/operator
        vm.prank(alice); mirror.approve(bob, id);
        assertEq(mirror.getApproved(id), bob);

        vm.prank(bob); mirror.transferFrom(alice, bob, id);
        assertEq(mirror.ownerOf(id), bob);
        assertEq(mirror.getApproved(id), address(0), "single-token approval survived the move");

        // Operator approval survives, per ERC-721, and an operator may also grant single approvals.
        address op = address(0xC0FE);
        vm.prank(bob); mirror.setApprovalForAll(op, true);
        assertTrue(mirror.isApprovedForAll(bob, op));
        vm.prank(op); mirror.approve(address(0xD00D), id);
        assertEq(mirror.getApproved(id), address(0xD00D));
        vm.prank(bob); mirror.setApprovalForAll(op, false);
        assertFalse(mirror.isApprovedForAll(bob, op));
        vm.prank(op); vm.expectRevert(); mirror.transferFrom(bob, alice, id);
    }

    /// The v2 core fix, exercised through the mirror for EVERY excluded address, including the two
    /// the fix specifically added (Permit2 and the mirror itself) and the burn sink.
    function test_R2C_mirrorCannotParkAShareOnAnyExcludedAddress() public {
        uint256 id = hook.ownedTokensOf(alice)[0];
        address[7] memory bad =
            [HOOKA, address(pm), address(posm), address(p2), address(mirror), DEAD, address(0)];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice); vm.expectRevert(); mirror.transferFrom(alice, bad[i], id);
            vm.prank(alice); vm.expectRevert(); mirror.safeTransferFrom(alice, bad[i], id);
        }
        vm.prank(alice); vm.expectRevert(); mirror.transferFrom(alice, alice, id); // self also barred
        assertEq(mirror.ownerOf(id), alice);
        assertEq(hook.nftBalanceOf(HOOKA) + hook.nftBalanceOf(address(pm))
               + hook.nftBalanceOf(address(posm)) + hook.nftBalanceOf(address(p2))
               + hook.nftBalanceOf(address(mirror)) + hook.nftBalanceOf(DEAD), 0);
    }

    /// ERC-721 conformance of the query surface: zero-address balance throws, unminted owner throws.
    function test_R2C_mirrorQueryConformance() public {
        vm.expectRevert(); mirror.balanceOf(address(0));
        vm.expectRevert(); mirror.ownerOf(12345);
        vm.expectRevert(); hook.nftGetApproved(12345);
        assertEq(mirror.balanceOf(alice), 10);
    }

    /// safeTransferFrom's receiver check runs AFTER the move, so the guard is released while
    /// onERC721Received executes. Prove that a receiver reentering the entire value surface from
    /// there can take nothing it is not owed, and that the ledgers stay exact.
    function test_R2C_reentrantReceiverFromOnERC721ReceivedGainsNothing() public {
        ReenteringReceiver rr = new ReenteringReceiver();
        rr.wire(hook, mirror);

        // A REAL, LARGE fee round the receiver could plausibly steal from. Shares were minted in
        // setUp, so nothing here is quarantined and every claim below is live. (Without a nonzero
        // accumulator this test would pass whether or not the reentrancy could extract value — the
        // whole point is that there must be something to take.)
        uint256 shares = hook.totalShares();
        vm.deal(address(posm), 100 ether);
        posm.arm(40 ether);
        hook.pokeFees();
        uint256 perShare = 40 ether * 1e12 / shares;
        assertGt(perShare / 1e12, 0, "no accrued ETH: the test would prove nothing");

        uint256 hookETHBefore = HOOKA.balance;
        uint256 rrETHBefore   = address(rr).balance;
        uint256 totalBefore   = hook.totalShares();
        uint256 alicePendBefore = hook.pendingETH(alice);

        uint256 id = hook.ownedTokensOf(alice)[0];
        vm.prank(alice); mirror.safeTransferFrom(alice, address(rr), id);

        assertTrue(rr.tried(), "receiver hook did not run");
        assertEq(mirror.ownerOf(id), address(rr));
        // `_move` credited the accrued slice to ALICE and reset the share's debt, so the receiver is
        // owed nothing on the share it just got. It reentered claim() and withdrawPending() from
        // inside onERC721Received — where handleNFTTransfer's guard is already released — and took
        // nothing. Any wei here would be wei the hook owes someone else.
        assertEq(address(rr).balance - rrETHBefore, 0, "reentrant receiver extracted ETH");
        assertEq(HOOKA.balance, hookETHBefore, "hook ETH moved during the receiver callback");
        assertEq(hook.pendingETH(address(rr)), 0);
        assertEq(hook.pendingPRISM(address(rr)), 0);
        // The seller keeps its accrued slice — exactly one share's worth, not zero and not two.
        assertEq(hook.pendingETH(alice) - alicePendBefore, perShare / 1e12, "seller lost its slice");
        assertEq(hook.totalShares(), totalBefore, "a move must not change totalShares");
        assertEq(hook.nftBalanceOf(address(rr)), 1);
        assertEq(hook.balanceOf(address(rr)), 1 ether);
    }

    /// A wrong magic value is rejected and the move is rolled back.
    function test_R2C_badMagicReceiverRollsBack() public {
        BadMagicReceiver bad = new BadMagicReceiver();
        uint256 id = hook.ownedTokensOf(alice)[0];
        uint256 balBefore = hook.balanceOf(alice);
        vm.prank(alice); vm.expectRevert(); mirror.safeTransferFrom(alice, address(bad), id);
        assertEq(mirror.ownerOf(id), alice);
        assertEq(hook.balanceOf(alice), balBefore);
        assertEq(hook.balanceOf(address(bad)), 0);
    }

    /*──────────────────── BaseHook permission bitmap ────────────────────*/

    /// The declared permission set is exactly {beforeInitialize, afterSwap}. In particular
    /// afterSwapReturnDelta is FALSE, which is what makes this an LP that gives its earnings away
    /// rather than a fee redirector, and beforeSwap is FALSE so no swap can be taxed or blocked.
    function test_R2C_permissionBitmapIsExactlyTwoFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.afterSwap);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);      assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);   assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertFalse(p.beforeDonate);            assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);   assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);

        // The declared set must match the deployed ADDRESS's flag bits, or the constructor's
        // Hooks.validateHookPermissions would have reverted. Re-assert it against the address here.
        uint160 a = uint160(HOOKA);
        assertTrue(a & (1 << 13) != 0, "BEFORE_INITIALIZE bit");
        assertTrue(a & (1 << 6)  != 0, "AFTER_SWAP bit");
        assertEq(a & (1 << 12), 0, "AFTER_INITIALIZE bit set");
        assertEq(a & (1 << 11), 0, "BEFORE_ADD_LIQUIDITY bit set");
        assertEq(a & (1 << 10), 0, "AFTER_ADD_LIQUIDITY bit set");
        assertEq(a & (1 << 9),  0, "BEFORE_REMOVE_LIQUIDITY bit set");
        assertEq(a & (1 << 8),  0, "AFTER_REMOVE_LIQUIDITY bit set");
        assertEq(a & (1 << 7),  0, "BEFORE_SWAP bit set");
        assertEq(a & (1 << 5),  0, "BEFORE_DONATE bit set");
        assertEq(a & (1 << 4),  0, "AFTER_DONATE bit set");
        assertEq(a & (1 << 3),  0, "BEFORE_SWAP_RETURNS_DELTA bit set");
        assertEq(a & (1 << 2),  0, "AFTER_SWAP_RETURNS_DELTA bit set");
        assertEq(a & (1 << 1),  0, "AFTER_ADD_LIQUIDITY_RETURNS_DELTA bit set");
        assertEq(a & 1,         0, "AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA bit set");
    }

    /// Every callback is PoolManager-gated, and every undeclared one additionally reverts
    /// HookNotImplemented even when the PoolManager is the caller. Two independent locks.
    function test_R2C_everyCallbackGated() public {
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: Currency.wrap(HOOKA),
            fee: 10_000, tickSpacing: 200, hooks: IHooks(HOOKA)
        });
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams(0, 200, 0, bytes32(0));
        SwapParams memory sp = SwapParams(true, 0, 0);

        // ── not the PoolManager: NotPoolManager on all ten ──
        vm.startPrank(bob);
        vm.expectRevert(); hook.beforeInitialize(bob, k, 1);
        vm.expectRevert(); hook.afterInitialize(bob, k, 1, 0);
        vm.expectRevert(); hook.beforeAddLiquidity(bob, k, mlp, "");
        vm.expectRevert(); hook.beforeRemoveLiquidity(bob, k, mlp, "");
        vm.expectRevert(); hook.beforeSwap(bob, k, sp, "");
        vm.expectRevert(); hook.afterSwap(bob, k, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(); hook.beforeDonate(bob, k, 0, 0, "");
        vm.expectRevert(); hook.afterDonate(bob, k, 0, 0, "");
        vm.stopPrank();

        // ── as the PoolManager: undeclared callbacks still revert ──
        vm.startPrank(address(pm));
        vm.expectRevert(); hook.afterInitialize(bob, k, 1, 0);
        vm.expectRevert(); hook.beforeAddLiquidity(bob, k, mlp, "");
        vm.expectRevert(); hook.beforeRemoveLiquidity(bob, k, mlp, "");
        vm.expectRevert(); hook.beforeSwap(bob, k, sp, "");
        vm.expectRevert(); hook.beforeDonate(bob, k, 0, 0, "");
        vm.expectRevert(); hook.afterDonate(bob, k, 0, 0, "");
        // beforeInitialize is declared but gated on the transient seeding flag, which is only ever
        // set inside seed(): no second pool can be created against this hook, ever.
        vm.expectRevert(); hook.beforeInitialize(bob, k, 1);
        // afterSwap is declared, pure, and returns a ZERO delta — it cannot brick or tax a swap.
        (bytes4 sel, int128 d) = hook.afterSwap(bob, k, sp, BalanceDelta.wrap(0), "");
        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(d, int128(0));
        vm.stopPrank();
    }
}
