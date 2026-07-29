// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PrismMigration} from "../src/PrismMigration.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

/// Cross-checks that the JS Merkle generator (merkle/generate.mjs, via the OpenZeppelin
/// merkle-tree lib) produces roots/proofs the ON-CHAIN PrismMigration verifier accepts — leaf and
/// sorted-pair hashing must match exactly. The values below are the output of:
///   node merkle/generate.mjs merkle/snapshot.example.json
/// so if the encodings ever diverge, this test fails.
contract MerkleCompat is Test {
    // From the JS tool on merkle/snapshot.example.json:
    bytes32 constant ROOT   = 0xea40fc4f572985b1fa3b8745bc98d8e046ac2c31854a35c25001aa7ed8ca32ad;
    address constant HOLDER = 0x1111111111111111111111111111111111111111;
    uint256 constant AMOUNT = 100000000000000000000;

    function _proof() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = 0xc3a617fe5b3089a48f68913324d528f6a0e4ac960cd0972e11ea54910958aba9;
        p[1] = 0xced246fbd1e64d9d2370a9d2f85d88b1b4d4a4ba4eb23d081e4c69402c8f64f3;
    }

    function test_JsGeneratedProofVerifiesOnChain() public {
        PrismMigration mig = new PrismMigration(ROOT, address(this));
        MockToken tok = new MockToken();
        tok.mint(address(mig), 1000 ether);
        mig.setToken(address(tok));

        mig.claim(HOLDER, AMOUNT, _proof());      // JS proof must verify against the on-chain root
        assertEq(tok.balanceOf(HOLDER), AMOUNT, "claim paid via JS-generated proof");
        assertTrue(mig.claimed(HOLDER));
    }

    function test_WrongAmountWithJsProofFails() public {
        PrismMigration mig = new PrismMigration(ROOT, address(this));
        MockToken tok = new MockToken();
        tok.mint(address(mig), 1000 ether);
        mig.setToken(address(tok));

        vm.expectRevert(); // InvalidProof — amount not in the leaf
        mig.claim(HOLDER, AMOUNT + 1, _proof());
    }
}
