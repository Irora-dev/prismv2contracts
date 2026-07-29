// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PrismMigration} from "../src/PrismMigration.sol";

/// Configurable ERC20 mock: mode 0 = normal, 1 = return false, 2 = revert.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    uint8 public mode;
    function setMode(uint8 m) external { mode = m; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) external returns (bool) {
        if (mode == 2) revert("boom");
        if (mode == 1) return false;
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
}

/// Accepts any call and returns nothing — a proxy/Safe/periphery contract stands in for this.
contract BareFallback {
    fallback() external payable {}
}

/// Reports a balance (so it can be wired) but its `transfer` returns no data.
contract SilentTransfer {
    mapping(address => uint256) public balanceOf;
    function setBal(address a, uint256 v) external { balanceOf[a] = v; }
    function transfer(address, uint256) external {}   // note: no return value
}

/// Unit audit of the migration hardening (L2 checked transfer, L3 correctable-then-locked token,
/// no-code guard) without a fork.
contract MigrationUnit is Test {
    PrismMigration mig;
    MockToken tok;
    MockToken tokWrong;

    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B2);
    uint256 constant AMT_A = 100e18;
    uint256 constant AMT_B = 50e18;
    bytes32 leafA;
    bytes32 leafB;

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }
    function _pair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x <= y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }
    function _proofA() internal view returns (bytes32[] memory p) { p = new bytes32[](1); p[0] = leafB; }

    function setUp() public {
        leafA = _leaf(ALICE, AMT_A);
        leafB = _leaf(BOB, AMT_B);
        mig = new PrismMigration(_pair(leafA, leafB), address(this)); // deployer = this test
        tok = new MockToken();
        tokWrong = new MockToken();
        tok.mint(address(mig), 1000e18);
    }

    /// L3: setToken is correctable until the first claim, then permanently locked.
    function test_SetTokenCorrectableThenLocked() public {
        tokWrong.mint(address(mig), 1);  // funded, so it clears the reserve check but is still wrong
        mig.setToken(address(tokWrong)); // oops
        mig.setToken(address(tok));      // corrected — allowed pre-claim
        assertEq(mig.token(), address(tok));
        assertFalse(mig.tokenFinal());

        mig.claim(ALICE, AMT_A, _proofA());
        assertTrue(mig.tokenFinal(), "first claim locks the token");
        assertEq(tok.balanceOf(ALICE), AMT_A);

        vm.expectRevert(); // TokenLocked
        mig.setToken(address(tok));
    }

    /// Regression: a contract with a permissive fallback must not be wirable as the token.
    ///
    /// Previously `setToken` checked only `code.length`, and `claim` read empty returndata as success.
    /// So a proxy/Safe/periphery contract could be wired and every claim would "succeed" delivering
    /// nothing: `claimed` and `tokenFinal` would latch, `pendingCount` would report the airdrop
    /// complete, and `setToken` would be locked forever with the whole reserve stranded.
    function test_BareFallbackTokenIsRejected() public {
        BareFallback bare = new BareFallback();
        vm.expectRevert(); // NotFunded — balanceOf returns nothing, so the decode reverts
        mig.setToken(address(bare));
        assertEq(mig.token(), address(0), "never wired");
        assertFalse(mig.tokenFinal(), "correction window still open");
    }

    /// And even if a token passes the wiring check, a transfer that returns no data is not success.
    function test_ClaimRejectsEmptyReturnDataTransfer() public {
        SilentTransfer silent = new SilentTransfer();
        silent.setBal(address(mig), 1000e18);   // clears the reserve check
        mig.setToken(address(silent));
        vm.expectRevert(PrismMigration.TransferFailed.selector);
        mig.claim(ALICE, AMT_A, _proofA());
        assertFalse(mig.claimed(ALICE), "no phantom claim recorded");
        assertFalse(mig.tokenFinal(), "and the correction window survives");
    }

    /// L3/no-code: cannot wire a no-code token, and non-deployer cannot set it.
    function test_SetTokenGuards() public {
        vm.expectRevert(); // ZeroToken (address(0) has no code)
        mig.setToken(address(0));
        vm.expectRevert(); // ZeroToken (EOA / no code)
        mig.setToken(address(0xDEAD));

        vm.prank(BOB);
        vm.expectRevert(); // NotDeployer
        mig.setToken(address(tok));
    }

    /// claim before the token is wired reverts cleanly (no state written).
    function test_ClaimBeforeTokenReverts() public {
        vm.expectRevert(); // TokenNotSet
        mig.claim(ALICE, AMT_A, _proofA());
        assertFalse(mig.tokenFinal());
        assertFalse(mig.claimed(ALICE));
    }

    /// L2: a failed transfer (false return) must revert and NOT mark the account claimed.
    function test_FailedTransferDoesNotBrick() public {
        mig.setToken(address(tok));
        tok.setMode(1); // transfer returns false
        vm.expectRevert(); // TransferFailed
        mig.claim(ALICE, AMT_A, _proofA());
        assertFalse(mig.claimed(ALICE), "not marked claimed -> retryable");

        tok.setMode(0); // healthy again
        mig.claim(ALICE, AMT_A, _proofA());
        assertTrue(mig.claimed(ALICE));
        assertEq(tok.balanceOf(ALICE), AMT_A);
    }

    /// L2: a reverting transfer also reverts the claim (retryable).
    function test_RevertingTransferDoesNotBrick() public {
        mig.setToken(address(tok));
        tok.setMode(2); // transfer reverts
        vm.expectRevert();
        mig.claim(ALICE, AMT_A, _proofA());
        assertFalse(mig.claimed(ALICE));
    }

    /// Double-claim and invalid proof both revert.
    function test_DoubleClaimAndBadProof() public {
        mig.setToken(address(tok));
        mig.claim(ALICE, AMT_A, _proofA());

        vm.expectRevert(); // AlreadyClaimed
        mig.claim(ALICE, AMT_A, _proofA());

        // A non-snapshot account with Alice's proof fails verification.
        bytes32[] memory p = _proofA();
        vm.expectRevert(); // InvalidProof
        mig.claim(address(0xC0FFEE), AMT_A, p);
    }
}
