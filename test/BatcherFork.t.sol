// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PrismMigration} from "../src/PrismMigration.sol";
import {PrismAirdropBatcher, IPrismMigrationB} from "../src/PrismAirdropBatcher.sol";

interface IHookB {
    function seed(uint160, int24, int24, uint128) external returns (uint256);
    function renounceOwnership() external;
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

library HookMinerB {
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

/// The batcher, exercised on a mainnet fork against the real hook: an 8-holder snapshot pushed out
/// by a stranger (not the deployer), retried, and interrupted by the gas floor.
contract BatcherFork is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2      = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER        = address(0xB0B);
    address constant STRANGER     = address(0x5721A9); // nobody special: proves permissionlessness
    uint160 constant FLAGS        = 0x2040;
    uint256 constant FORK_BLOCK   = 25604624;
    uint256 constant N            = 8;

    PrismMigration migration;
    PrismAirdropBatcher batcher;
    IHookB hook;

    address[] accounts;
    uint256[] amounts;
    bytes32[] leaves;
    bytes32[][] proofs;

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }
    function _pair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x <= y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        // A spread mirroring the real snapshot: a couple of big holders, some small, mostly dust.
        uint256[N] memory amt;
        amt[0] = 18 ether;
        amt[1] = 7 ether;
        amt[2] = 3 ether;
        amt[3] = 1 ether;
        amt[4] = 0.5 ether;
        amt[5] = 0.01 ether;
        amt[6] = 0.000474798226967531 ether;
        amt[7] = 1 wei;
        uint256 reserve;
        for (uint256 i; i < N; i++) {
            accounts.push(address(uint160(0xAA0000 + i)));
            amounts.push(amt[i]);
            leaves.push(_leaf(accounts[i], amt[i]));
            reserve += amt[i];
        }

        // Balanced 8-leaf tree: level1 = pairs, level2 = pairs of those, root = pair of level2.
        bytes32[4] memory l1;
        for (uint256 i; i < 4; i++) l1[i] = _pair(leaves[2 * i], leaves[2 * i + 1]);
        bytes32[2] memory l2;
        for (uint256 i; i < 2; i++) l2[i] = _pair(l1[2 * i], l1[2 * i + 1]);
        bytes32 root = _pair(l2[0], l2[1]);

        // Proof for leaf i: sibling leaf, then sibling l1, then sibling l2.
        for (uint256 i; i < N; i++) {
            bytes32[] memory p = new bytes32[](3);
            p[0] = leaves[i ^ 1];
            p[1] = l1[(i / 2) ^ 1];
            p[2] = l2[(i / 4) ^ 1];
            proofs.push(p);
        }

        migration = new PrismMigration(root, address(this));

        bytes memory creationCode = vm.getCode("PrismHookV2.sol:PrismHookV2");
        bytes memory args = abi.encode(POOL_MANAGER, OWNER, POSM, PERMIT2, address(migration), reserve);
        (address predicted, bytes32 salt) = HookMinerB.find(CREATE2_FACTORY, FLAGS, creationCode, args);
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode, args));
        require(ok, "deploy failed");
        hook = IHookB(predicted);

        migration.setToken(predicted);
        vm.prank(OWNER);
        hook.seed(3648751508805509367250261525102, -887200, 76600, 80e18);
        vm.prank(OWNER);
        hook.renounceOwnership();

        batcher = new PrismAirdropBatcher(IPrismMigrationB(address(migration)));
    }

    /// The whole point: a random address delivers everyone's allocation in one call.
    function test_StrangerPushesWholeListInOneCall() public {
        assertEq(batcher.pendingCount(accounts), N, "all pending before");

        vm.prank(STRANGER);
        (uint256 delivered, uint256 alreadyClaimed, uint256 failed, uint256 stoppedAt) =
            batcher.push(accounts, amounts, proofs, 0, 300_000);

        assertEq(delivered, N, "everyone delivered");
        assertEq(alreadyClaimed, 0, "nothing was already settled");
        assertEq(failed, 0, "nothing failed");
        assertEq(stoppedAt, N, "ran to the end");
        assertEq(batcher.pendingCount(accounts), 0, "none pending after");

        for (uint256 i; i < N; i++) {
            assertEq(hook.balanceOf(accounts[i]), amounts[i], "holder got exactly their allocation");
            assertEq(hook.nftBalanceOf(accounts[i]), amounts[i] / 1 ether, "fee-shares minted");
        }
        // Non-custodial: the batcher never touches PRISM.
        assertEq(hook.balanceOf(address(batcher)), 0, "batcher holds nothing");
    }

    /// Re-running an already-settled batch must be a cheap no-op, not a revert. This is what makes
    /// overlapping chunks and blind retries safe.
    function test_RerunIsIdempotent() public {
        vm.prank(STRANGER);
        batcher.push(accounts, amounts, proofs, 0, 300_000);

        vm.prank(STRANGER);
        (uint256 delivered, uint256 alreadyClaimed, uint256 failed, uint256 stoppedAt) =
            batcher.push(accounts, amounts, proofs, 0, 300_000);

        assertEq(delivered, 0, "nothing left to deliver");
        assertEq(alreadyClaimed, N, "all rows recognised as settled");
        assertEq(failed, 0, "settled rows are not failures");
        assertEq(stoppedAt, N, "still reports completion");
    }

    /// A permanently-invalid row must be counted and skipped, never stranding the rows behind it —
    /// and it must NOT be reported as `alreadyClaimed`, which is what previously hid unpaid holders.
    function test_BadRowDoesNotPoisonTheBatch() public {
        uint256[] memory bad = amounts;
        bad[3] = amounts[3] + 1; // wrong amount -> different leaf -> proof fails deterministically

        vm.prank(STRANGER);
        (uint256 delivered, uint256 alreadyClaimed, uint256 failed,) =
            batcher.push(accounts, bad, proofs, 0, 300_000);

        assertEq(delivered, N - 1, "the seven valid rows delivered");
        assertEq(failed, 1, "the corrupt row is reported as FAILED, not skipped-as-settled");
        assertEq(alreadyClaimed, 0, "and is never conflated with an already-paid row");
        assertEq(hook.balanceOf(accounts[3]), 0, "corrupt row delivered nothing");
        assertEq(hook.balanceOf(accounts[4]), amounts[4], "rows after it still landed");
    }

    /// The gas floor must stop the loop early and hand back a usable resume index.
    function test_GasFloorStopsEarlyAndResumes() public {
        // A floor just under the gas limit of the call forces a break partway through.
        vm.prank(STRANGER);
        (uint256 d1,,, uint256 stoppedAt) =
            batcher.push{gas: 3_000_000}(accounts, amounts, proofs, 0, 2_000_000);

        assertGt(stoppedAt, 0, "made some progress");
        assertLt(stoppedAt, N, "stopped before the end");
        assertEq(d1, stoppedAt, "delivered exactly what it walked past");

        // Resume from where it stopped and finish the job.
        vm.prank(STRANGER);
        (uint256 d2,,, uint256 end) = batcher.push(accounts, amounts, proofs, stoppedAt, 300_000);

        assertEq(end, N, "second pass reached the end");
        assertEq(d1 + d2, N, "everyone delivered across the two passes");
        assertEq(batcher.pendingCount(accounts), 0, "list fully settled");
    }

    /// Regression: an out-of-gas row must never be reported as walked-past.
    ///
    /// Previously the `catch` counted OOG in the same bucket as "already paid" and let `++i` advance,
    /// so `push` could return `stoppedAt == accounts.length` — "list complete" — while a holder held
    /// nothing, with no revert and nothing to distinguish it from a settled row. A caller following
    /// the documented resume protocol lost that holder permanently and silently.
    function test_OutOfGasRowStopsAndIsNeverReportedAsSettled() public {
        // Starve the call: enough gas to clear the floor and enter row 0, not enough to finish it.
        // Row 0 is the 18-PRISM holder, so its mints cost far more than the floor.
        vm.prank(STRANGER);
        (uint256 delivered, uint256 alreadyClaimed, uint256 failed, uint256 stoppedAt) =
            batcher.push{gas: 700_000}(accounts, amounts, proofs, 0, 300_000);

        assertEq(delivered, 0, "nothing was delivered");
        assertEq(alreadyClaimed, 0, "and nothing may be reported as already settled");
        assertEq(failed, 1, "the starved row is reported as a failure");
        assertEq(stoppedAt, 0, "resume index points AT the unpaid row, not past it");
        assertFalse(hook.balanceOf(accounts[0]) == amounts[0], "row 0 really was not paid");

        // The documented resume protocol now converges instead of losing the holder.
        vm.prank(STRANGER);
        (,, uint256 failed2, uint256 end) =
            batcher.push(accounts, amounts, proofs, stoppedAt, 300_000);
        assertEq(failed2, 0, "resume completed cleanly");
        assertEq(end, N, "and reached the end");
        assertEq(batcher.pendingCount(accounts), 0, "every holder paid");
    }

    /// Regression: a row that fails DETERMINISTICALLY for a reason other than a bad proof must be
    /// skipped, not stopped on — otherwise one unpayable row strands every row behind it forever.
    ///
    /// The case that matters is a vault short of reserve: solady's `InsufficientBalance` becomes
    /// `TransferFailed()`, which is the SAME selector a starved (out-of-gas) transfer produces. The
    /// batcher therefore cannot discriminate on the selector and uses gas consumed instead.
    function test_ShortReserveRowIsSkippedNotStalled() public {
        // Drain the vault so only the smaller rows can be paid. Rows are ordered largest-first, so
        // row 0 (18 PRISM) will fail on reserve while the tail is still affordable.
        uint256 drain = hook.balanceOf(address(migration)) - 9 ether;
        vm.prank(address(migration));
        hook.transfer(address(0xDEAD00), drain);

        vm.prank(STRANGER);
        (uint256 delivered, , uint256 failed, uint256 stoppedAt) =
            batcher.push(accounts, amounts, proofs, 0, 300_000);

        assertGt(failed, 0, "the unaffordable row(s) are reported as failures");
        assertGt(delivered, 0, "but the affordable rows behind them were still paid");
        assertEq(stoppedAt, N, "and the batch walked the whole range instead of stalling");
        // The specific guarantee: a later, affordable holder got paid despite an earlier failure.
        assertEq(hook.balanceOf(accounts[N - 1]), amounts[N - 1], "tail holder paid");
    }

    /// Guard rails.
    function test_RejectsMismatchedInputAndUnwiredToken() public {
        uint256[] memory shortAmounts = new uint256[](N - 1);
        vm.expectRevert(PrismAirdropBatcher.LengthMismatch.selector);
        batcher.push(accounts, shortAmounts, proofs, 0, 300_000);

        vm.expectRevert(PrismAirdropBatcher.BadRange.selector);
        batcher.push(accounts, amounts, proofs, N + 1, 300_000);

        // A vault with no token wired yet should fail fast rather than skip every row.
        PrismMigration fresh = new PrismMigration(bytes32(uint256(1)), address(this));
        PrismAirdropBatcher b2 = new PrismAirdropBatcher(IPrismMigrationB(address(fresh)));
        vm.expectRevert(PrismAirdropBatcher.TokenNotWired.selector);
        b2.push(accounts, amounts, proofs, 0, 300_000);
    }

    /// Report the real cost of pushing this list, for runner chunk sizing.
    function test_ReportBatchGas() public {
        uint256 g0 = gasleft();
        vm.prank(STRANGER);
        batcher.push(accounts, amounts, proofs, 0, 300_000);
        uint256 used = g0 - gasleft();
        console2.log("gas to push all 8 holders (29.51 PRISM, 29 NFTs):", used);
        console2.log("  average per holder:", used / N);
    }
}
