// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Merkle-based PRISM airdrop claim.
///
/// PrismHookV2 mints this contract the airdrop reserve at construction and lists it as an
/// excluded address, so the unclaimed reserve never mints fee-shares and never dilutes real
/// holders. Each holder in the snapshot claims their allocation once; the claimed PRISM lands in
/// their wallet (a normal, non-excluded address), which mirror-mints their fee-share NFTs.
///
/// Trust surface is intentionally tiny: the only privileged action is `setToken`, callable once
/// by the deployer to wire the token after the hook is deployed; after that the contract is fully
/// permissionless and immutable. There is no sweep — unclaimed tokens remain trustlessly locked in
/// this excluded vault. (Leaves use the OpenZeppelin StandardMerkleTree double-hash format.)
contract PrismMigration {
    error AlreadyClaimed();
    error InvalidProof();
    error TokenLocked();
    error TokenNotSet();
    error NotDeployer();
    error ZeroDeployer();
    error ZeroToken();
    error NotFunded();
    error TransferFailed();

    event Claimed(address indexed account, uint256 amount);
    event TokenSet(address token);

    bytes32 public immutable merkleRoot;
    address public immutable deployer;
    address public token;      // v2 PRISM (the hook); wired after the hook is deployed
    bool    public tokenFinal; // once the first claim lands, `token` is permanently locked

    mapping(address => bool) public claimed;

    /// @param _deployer The address permitted to call `setToken`. Passed explicitly rather than taken
    ///   from `msg.sender`, because this contract is deployed through the canonical CREATE2 factory and
    ///   the factory is the direct caller of `CREATE2` — so `msg.sender` here is the FACTORY, whose entire
    ///   69-byte runtime contains no CALL opcode of any kind. Deriving `deployer` from it would therefore
    ///   make `setToken` unreachable by anyone, forever — and any run that landed the hook would mint 89%
    ///   of the supply into a vault that could never be wired to a token and has no sweep. Deterministic
    ///   deployment and a usable `deployer` are only compatible if the deployer is an argument.
    ///
    ///   Passing a wrong address here is not a new trust assumption but it IS unrecoverable, so
    ///   `Deploy.s.sol` asserts `deployer()` on-chain after deploying. Note also that this argument is
    ///   part of the initcode, so the vault's CREATE2 address is bound to it: nobody can occupy that
    ///   address with a vault naming a different deployer.
    constructor(bytes32 _merkleRoot, address _deployer) {
        if (_deployer == address(0)) revert ZeroDeployer();
        merkleRoot = _merkleRoot;
        deployer   = _deployer;
    }

    /// @dev Wire the v2 PRISM token (the hook address). Deployer-only, and CORRECTABLE up until
    ///   the first claim (so a wrong address can't permanently brick the airdrop); it locks
    ///   forever the moment anyone claims. No new trust: the deployer already chooses the token.
    function setToken(address _token) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (tokenFinal)             revert TokenLocked();
        // Must be a DEPLOYED contract: a no-code address would make the low-level transfer in
        // `claim` succeed-with-nothing (a call to a codeless address returns (true,"")), bricking
        // a claimer. Also rejects address(0). The hook is already deployed when this is wired.
        if (_token.code.length == 0) revert ZeroToken();
        // A code-length check alone does NOT stop a contract with a permissive fallback (a proxy, a
        // Safe, a periphery contract). Wiring one would make every `claim` "succeed" while delivering
        // nothing: `claimed` and `tokenFinal` would latch, the airdrop would report itself complete,
        // and `setToken` would be locked forever with the reserve stranded. So require the candidate
        // to actually behave like the token holding this vault's reserve — the hook mints the reserve
        // here at its own construction, so a correct wiring always reports a nonzero balance, and a
        // bare fallback fails this (an empty returndata reverts the decode).
        if (IERC20Min(_token).balanceOf(address(this)) == 0) revert NotFunded();
        token = _token;
        emit TokenSet(_token);
    }

    /// @notice Claim `amount` v2 PRISM for `account` if `(account, amount)` is in the snapshot tree.
    ///   Permissionless: anyone may submit a valid proof; funds always go to `account`.
    function claim(address account, uint256 amount, bytes32[] calldata proof) external {
        if (token == address(0)) revert TokenNotSet();
        if (claimed[account]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!_verify(proof, leaf)) revert InvalidProof();
        // Latch only AFTER the proof verifies, so a bogus claim cannot end the `setToken` correction
        // window. Keep that order: latching before the proof check would leave the window's lifetime
        // depending on a revert to roll the latch back, which is fragile even where it holds.
        if (!tokenFinal) tokenFinal = true; // first VALID claim locks the token address
        claimed[account] = true;                 // effects before interaction (CEI)
        // Checked transfer: reverts on a false return or a failed call, so a claim can never
        // mark `claimed` without actually delivering the tokens. A standards-compliant ERC-20 returns
        // exactly one 32-byte bool; anything shorter (notably the empty returndata of a bare
        // fallback) is rejected rather than read as success.
        uint256 balBefore = IERC20Min(token).balanceOf(address(this));
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSignature("transfer(address,uint256)", account, amount));
        if (!ok || ret.length != 32 || !abi.decode(ret, (bool))) revert TransferFailed();
        // Do not take the token's word for it. A contract with a fallback that returns 32 bytes of
        // `1` for everything satisfies both the `setToken` balance gate and the checked return above
        // while delivering nothing — and because the first claim latches `tokenFinal`, that would
        // strand the entire reserve behind a token that can never be re-pointed. Verifying the vault's
        // balance actually fell by `amount` is behavioural rather than self-reported, so it catches the
        // realistic case: a proxy, Safe or periphery contract with a permissive fallback, wired here by
        // accident. (A constant-balance liar underflows here and reverts.)
        //
        // It does NOT catch a token built to lie: one that keeps its own counter, decrements it by
        // exactly `amount` and credits nobody satisfies this check, the `setToken` funding gate and the
        // decoded return alike. No on-chain check can distinguish that from a real transfer, so this is
        // a guard against error, not against a hostile `setToken`. What actually bounds that is who may
        // call it — `setToken` is deployer-only, and `Deploy.s.sol` wires the CREATE2-predicted hook
        // after asserting it minted the reserve here.
        if (IERC20Min(token).balanceOf(address(this)) != balBefore - amount) revert TransferFailed();
        emit Claimed(account, amount);
    }

    function _verify(bytes32[] calldata proof, bytes32 leaf) private view returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            computed = computed <= p
                ? keccak256(abi.encodePacked(computed, p))
                : keccak256(abi.encodePacked(p, computed));
        }
        return computed == merkleRoot;
    }
}
