// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockPOSM, MockPoolManager, Permit2Stub} from "./InvariantPrism.t.sol";

interface IHook {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function pokeFees() external;
    function pendingPRISM(address) external view returns (uint256);
    function pendingETH(address) external view returns (uint256);
    function syncNFTs(uint256) external;
}

/// Rebuilds InvariantPrism's exact setUp and drives the PRISM fee leg as hard as it can be driven,
/// to measure (a) how much slack `invariant_prismSolvency` actually has, and (b) how long the mock's
/// PRISM reservoir survives before the leg silently goes dead behind pokeFees' try/catch.
contract PrismSolvencyProbe is Test {
    address constant V2_ADDR   = address(0x2040);
    address constant OWNER     = address(0xB0B);
    address constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SUPPLY    = 5000 ether;

    IHook hook;
    MockPOSM posm;
    address[4] actors = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];

    function setUp() public {
        MockPoolManager pm = new MockPoolManager();
        posm = new MockPOSM();
        Permit2Stub permit2 = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(permit2), address(0), uint256(0)), V2_ADDR);
        hook = IHook(V2_ADDR);
        vm.store(V2_ADDR, bytes32(uint256(0)), bytes32(uint256(1))); // seeded = true
        vm.deal(address(posm), 1_000_000 ether);

        vm.prank(V2_ADDR); hook.transfer(actors[0], 400 ether);
        vm.prank(V2_ADDR); hook.transfer(actors[1], 50 ether);
        vm.prank(V2_ADDR); hook.transfer(actors[2], 7 ether);
        vm.prank(V2_ADDR); hook.transfer(actors[3], 3 ether);
        vm.prank(V2_ADDR); hook.transfer(address(posm), 200 ether);
        posm.setPrism(V2_ADDR);
        // Maximise the promise base: every actor fully mirrored.
        for (uint256 i; i < 4; ++i) {
            for (uint256 k; k < 4; ++k) { vm.prank(actors[i]); hook.syncNFTs(0); }
        }
        hook.pokeFees(); // burn off forfeitNextCollection armed at seed
    }

    function _sumPendingPRISM() internal view returns (uint256 s) {
        for (uint256 i; i < 4; ++i) s += hook.pendingPRISM(actors[i]);
    }

    function test_PrismSolvencyInvariantIsUnfalsifiableInThisHarness() public {
        console2.log("hook PRISM balance at setUp (ether):", hook.balanceOf(V2_ADDR) / 1e18);
        console2.log("MockPOSM PRISM reservoir    (ether):", hook.balanceOf(address(posm)) / 1e18);
        console2.log("totalShares                        :", hook.totalShares());

        // The handler's poke bounds feePrism to [0, 2 ether]. Drive the maximum every time.
        posm.setFeePrism(2 ether);
        posm.setFeeEth(0);
        uint256 pokesThatPaid;
        uint256 minSlack = type(uint256).max;
        for (uint256 i; i < 400; ++i) {
            uint256 resBefore = hook.balanceOf(address(posm));
            hook.pokeFees();
            if (hook.balanceOf(address(posm)) < resBefore) pokesThatPaid++;
            uint256 bal = hook.balanceOf(V2_ADDR);
            uint256 owed = _sumPendingPRISM();
            uint256 slack = bal > owed ? bal - owed : 0;
            if (slack < minSlack) minSlack = slack;
        }

        console2.log("--- 400 max-size pokes (handler's upper bound is 2 ether each) ---");
        console2.log("pokes that actually paid PRISM     :", pokesThatPaid);
        console2.log("pokes that silently no-op'd (catch):", 400 - pokesThatPaid);
        console2.log("PRISM burned to 0x..dEaD    (ether):", hook.balanceOf(BURN_SINK) / 1e18);
        console2.log("max sum(pendingPRISM)   (milliether):", _sumPendingPRISM() / 1e15);
        console2.log("hook PRISM balance now      (ether):", hook.balanceOf(V2_ADDR) / 1e18);
        console2.log("MINIMUM slack in the assertion (eth):", minSlack / 1e18);

        // The invariant is `balanceOf(hook) >= sum(pendingPRISM)`. Show it can never come close.
        assertGt(minSlack, 3000 ether,
            "invariant_prismSolvency never gets within 3000 PRISM of failing -> unfalsifiable here");
        // And the reservoir bounds the promise base absolutely.
        assertLt(_sumPendingPRISM(), 200 ether, "sum(pendingPRISM) is capped by the 200-ether mock reservoir");
    }
}
