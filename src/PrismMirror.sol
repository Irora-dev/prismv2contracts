// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPrismHookNFT {
    function nftOwnerOf(uint256 tokenId) external view returns (address);
    function nftBalanceOf(address owner) external view returns (uint256);
    function nftTokenURI(uint256 tokenId) external view returns (string memory);
    function nftGetApproved(uint256 tokenId) external view returns (address);
    function nftIsApprovedForAll(address owner, address operator) external view returns (bool);
    function totalShares() external view returns (uint256); // [V2] live NFT count

    function handleNFTTransfer(address from, address to, uint256 tokenId, address caller) external;
    function handleNFTApprove(address spender, uint256 tokenId, address caller) external;
    function handleNFTSetApprovalForAll(address operator, bool approved, address caller) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
}

/// @notice one v4 pool. five thousand facets.
/// @author 0xsolazy (https://github.com/0xsolazy/)
/// @custom:website Prism (https://prism.0xsolazy.eth.limo/)
/// @custom:x Prism (https://x.com/prism_lp/)
contract PrismMirror {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Caller is not the hook.
    error OnlyHook();

    /// @dev Recipient did not accept the safeTransfer.
    error NonERC721Receiver();

    /// @dev [V2] ERC-721 balance query for the zero address.
    error ZeroAddressQuery();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Standard ERC-721 Transfer.
    event Transfer       (address indexed from,  address indexed to,       uint256 indexed tokenId);

    /// @dev Standard ERC-721 single-token Approval.
    event Approval       (address indexed owner, address indexed approved, uint256 indexed tokenId);

    /// @dev Standard ERC-721 operator Approval.
    event ApprovalForAll (address indexed owner, address indexed operator, bool approved);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          METADATA                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    string  public constant name   = "Prism-LP";
    string  public constant symbol = "PRISM-LP";

    /// @dev The hook contract that owns all state.
    address public immutable hook;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         MODIFIERS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    constructor(address _hook) {
        hook = _hook;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ERC721                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Returns the owner of `tokenId`. Reverts on the hook side if unminted.
    function ownerOf(uint256 tokenId) external view returns (address) {
        return IPrismHookNFT(hook).nftOwnerOf(tokenId);
    }

    /// @dev Returns the number of Prism NFTs owned by `owner`. [V2] reverts on the zero
    ///   address, per ERC-721.
    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddressQuery();
        return IPrismHookNFT(hook).nftBalanceOf(owner);
    }

    /// @dev [V2] Live count of Prism NFTs in existence (ERC-721 enumeration-lite).
    function totalSupply() external view returns (uint256) {
        return IPrismHookNFT(hook).totalShares();
    }

    /// @dev Returns the on-chain SVG metadata URI for `tokenId`.
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        return IPrismHookNFT(hook).nftTokenURI(tokenId);
    }

    /// @dev Returns the address approved to spend `tokenId`, or address(0).
    function getApproved(uint256 tokenId) external view returns (address) {
        return IPrismHookNFT(hook).nftGetApproved(tokenId);
    }

    /// @dev Returns whether `operator` is approved for all of `owner`'s NFTs.
    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return IPrismHookNFT(hook).nftIsApprovedForAll(owner, operator);
    }

    /// @dev ERC-165 introspection: ERC-165, ERC-721, ERC-721-Metadata.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x80ac58cd || id == 0x5b5e139f;
    }

    /// @dev Approves `to` for `tokenId`. Forwarded to the hook, which performs all checks.
    function approve(address to, uint256 tokenId) external {
        IPrismHookNFT(hook).handleNFTApprove(to, tokenId, msg.sender);
    }

    /// @dev Sets operator approval for `msg.sender`'s entire collection.
    function setApprovalForAll(address operator, bool approved) external {
        IPrismHookNFT(hook).handleNFTSetApprovalForAll(operator, approved, msg.sender);
    }

    /// @dev Transfers `tokenId` from `from` to `to`.
    /// Also moves 1 PRISM ERC-20 on the hook to keep balances synced.
    function transferFrom(address from, address to, uint256 tokenId) public {
        IPrismHookNFT(hook).handleNFTTransfer(from, to, tokenId, msg.sender);
    }

    /// @dev `transferFrom` + ERC-721 receiver check.
    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    /// @dev `transferFrom` + ERC-721 receiver check with custom data.
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 ret) {
                if (ret != IERC721Receiver.onERC721Received.selector) revert NonERC721Receiver();
            } catch {
                revert NonERC721Receiver();
            }
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    HOOK → MIRROR EVENTS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Hook-only: emit ERC-721 Transfer from this contract's address.
    function emitTransfer(address from, address to, uint256 tokenId) external onlyHook {
        emit Transfer(from, to, tokenId);
    }

    /// @dev Hook-only: emit single-token Approval.
    function emitApproval(address owner, address approved, uint256 tokenId) external onlyHook {
        emit Approval(owner, approved, tokenId);
    }

    /// @dev Hook-only: emit ApprovalForAll.
    function emitApprovalForAll(address owner, address operator, bool approved) external onlyHook {
        emit ApprovalForAll(owner, operator, approved);
    }
}
