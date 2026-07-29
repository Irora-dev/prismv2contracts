// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IPrism {
    function pokeFees() external;
    function accFeesPerShareETH() external view returns (uint256);
    function accFeesPerSharePRISM() external view returns (uint256);
    function totalShares() external view returns (uint256);
}

/// Demonstrates the enabling primitive behind the fee-timing / JIT finding:
/// fees sit UNCOLLECTED in the LP position between pokes, and ANY address can trigger
/// collection at a moment of its choosing via the permissionless `pokeFees()`. Combined
/// with the fact that share mints happen while the pool is locked (so they cannot poke),
/// this lets an actor mint shares, then poke, and capture already-accrued fees.
contract FeeTimingFork is Test {
    address constant PRISM = 0xbd3AB5859f244CC9F51Ee0Ca755c5cf663D80040;
    uint256 constant FORK_BLOCK = 25604624;

    function test_PermissionlessPokeCollectsStandingFees() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        IPrism p = IPrism(PRISM);

        uint256 ethAccBefore   = p.accFeesPerShareETH();
        uint256 prismAccBefore = p.accFeesPerSharePRISM();

        // A random, unprivileged EOA pokes.
        address rando = address(0xD00D);
        vm.prank(rando);
        p.pokeFees();

        uint256 ethAccAfter   = p.accFeesPerShareETH();
        uint256 prismAccAfter = p.accFeesPerSharePRISM();

        console2.log("shares            :", p.totalShares());
        console2.log("eth acc  delta    :", ethAccAfter - ethAccBefore);
        console2.log("prism acc delta   :", prismAccAfter - prismAccBefore);

        // If either accumulator moved, fees were standing uncollected and a permissionless
        // caller just decided when to book them -> collection timing is attacker-controllable.
        assertTrue(
            ethAccAfter > ethAccBefore || prismAccAfter > prismAccBefore,
            "fees were standing uncollected; poke timing is controllable"
        );
    }
}
