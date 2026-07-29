// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IH {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function syncNFTs(uint256) external;
}

contract PStub { function approve(address,address,uint160,uint48) external {} }
contract PMStub { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }
contract POSMStub {
    receive() external payable {}
    function modifyLiquidities(bytes calldata, uint256) external {}
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

/// Does an ordinary inflow close an existing under-mirroring gap, or freeze it?
///
/// This is the property that decides whether the `mintRoom` clamp is a fix or a regression, so it is
/// pinned independently of any comment. `MAX_REALIGN = 128` guarantees a gap for anybody who receives
/// more than 128 whole tokens in one transfer, and `syncNFTs` is caller-only — so if inflows stop healing
/// it, a holder who never learns about `syncNFTs` is underpaid on every fee round, permanently.
///
/// The realistic shape is a routed buy: value reaches the holder from another *user* address (a router),
/// which is the `_realignPair` path. A transfer straight from an excluded address takes `_realignSolo`
/// instead, which is not affected — so testing only the excluded-sender path would have missed this.
contract GapHealing is Test {
    address constant V2 = address(0x2040);
    address constant OWNER = address(0xB0B);
    address constant ROUTER = address(0x9011);
    address constant HOLDER = address(0x4011);
    IH hook;

    function setUp() public {
        PMStub pm = new PMStub(); POSMStub posm = new POSMStub(); PStub p2 = new PStub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), V2);
        hook = IH(V2);
        vm.store(V2, bytes32(uint256(0)), bytes32(uint256(1))); // seeded

        // A holder buys 300 whole tokens. MAX_REALIGN caps the mint at 128, leaving a 172-share gap.
        vm.prank(V2); hook.transfer(HOLDER, 300 ether);
        // Fund a router that is fully mirrored, so it behaves like a real intermediary.
        vm.prank(V2); hook.transfer(ROUTER, 60 ether);
        for (uint256 i; i < 3; ++i) { vm.prank(ROUTER); hook.syncNFTs(0); }
    }

    function test_DoesAnOrdinaryRoutedBuyHealTheGap() public {
        uint256 entitled0 = hook.balanceOf(HOLDER) / 1 ether;
        uint256 shares0   = hook.nftBalanceOf(HOLDER);
        console2.log("start: entitlement / shares / gap:", entitled0, shares0, entitled0 - shares0);
        assertGt(entitled0 - shares0, 0, "MAX_REALIGN left a gap, as it does for any large receive");

        // Ten ordinary 1-token buys arriving via the router (the _realignPair path).
        for (uint256 i; i < 10; ++i) { vm.prank(ROUTER); hook.transfer(HOLDER, 1 ether); }

        uint256 entitled1 = hook.balanceOf(HOLDER) / 1 ether;
        uint256 shares1   = hook.nftBalanceOf(HOLDER);
        uint256 gap1      = entitled1 - shares1;
        console2.log("after 10 routed buys: entitlement / shares / gap:", entitled1, shares1, gap1);
        console2.log("gap at start:", entitled0 - shares0);
        console2.log("shares gained for 10 whole tokens received:", shares1 - shares0);

        // THE REGRESSION GUARD. Inflows must close the pre-existing gap, not merely keep pace with the
        // new tokens. A clamp of `mintBudget - transferable` froze it and was reverted; if this assertion
        // fails, that regression is back and holders who never call `syncNFTs` are being underpaid.
        assertLt(gap1, entitled0 - shares0, "an ordinary inflow must SHRINK the pre-existing gap");
        assertEq(shares1 - shares0, 20, "10 whole tokens in: 10 moved from the router + 10 gap-healing mints");

        // And it must never over-mirror while doing so.
        assertLe(shares1, entitled1, "never over-mirrored");
    }

    /// What the gap costs in fees, and that ordinary activity reduces it.
    ///
    /// Note what this does NOT claim: a holder who receives a large amount and then never transacts again
    /// stays under-mirrored until it calls `syncNFTs`. That is `MAX_REALIGN`'s documented tradeoff and no
    /// clamp changes it — the cap exists because an unbounded mint loop would exceed the per-transaction
    /// gas limit and strand the largest claims entirely. What the healing channel guarantees is that the
    /// gap SHRINKS with ordinary use rather than being frozen for life.
    function test_OrdinaryActivityReducesTheFeePenalty() public {
        address aware = address(0x5011);
        vm.prank(V2); hook.transfer(aware, 300 ether);
        for (uint256 i; i < 3; ++i) { vm.prank(aware); hook.syncNFTs(0); }

        uint256 penaltyBefore = 5000 - (10_000 * hook.nftBalanceOf(HOLDER)
                                        / (hook.nftBalanceOf(aware) + hook.nftBalanceOf(HOLDER)));
        console2.log("unaware holder underpaid, bps, before any activity:", penaltyBefore);

        // Ordinary inflows: each one heals part of the gap.
        for (uint256 i; i < 40; ++i) { vm.prank(ROUTER); hook.transfer(HOLDER, 1 ether); }

        uint256 penaltyAfter = 5000 - (10_000 * hook.nftBalanceOf(HOLDER)
                                       / (hook.nftBalanceOf(aware) + hook.nftBalanceOf(HOLDER)));
        console2.log("after 40 ordinary buys, underpaid, bps           :", penaltyAfter);
        console2.log("holder shares now / entitlement                 :",
                     hook.nftBalanceOf(HOLDER), hook.balanceOf(HOLDER) / 1 ether);

        assertLt(penaltyAfter, penaltyBefore, "ordinary activity must reduce the fee penalty, not freeze it");
        assertLe(hook.nftBalanceOf(HOLDER), hook.balanceOf(HOLDER) / 1 ether, "never over-mirrored");
    }
}
