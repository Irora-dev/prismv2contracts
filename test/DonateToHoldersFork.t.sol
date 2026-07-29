// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test, console2} from "forge-std/Test.sol";
import {Swapper} from "./SwapFork.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IHookD {
    function seed(uint160,int24,int24,uint128) external returns (uint256);
    function renounceOwnership() external;
    function pokeFees() external;
    function accFeesPerShareETH() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// Can a third party hand ETH to PRISM HOLDERS without becoming an LP and taking a fee share?
///
/// Verifies that a third party can provide liquidity as an ordinary LP and
/// pass the fees it earns back to holders. The mechanism is v4's permissionless
/// `PoolManager.donate()`, which credits in-range liquidity pro-rata — so with the hook's position as
/// the only liquidity, a donation lands entirely on it and flows out through `pokeFees` to fee-share
/// holders. If this ever stops holding, that plan silently stops working, hence a regression test.
///
/// Caveat worth knowing: only donate while the price is ABOVE the launch floor. If the hook's position
/// is out of range and a donor's own position is in range, the donation credits the donor instead.
contract DonateToHoldersFork is Test {
    address constant PM   = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant P2   = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER= address(0xB0B);
    address constant HOOK = address(0x2040);
    IHookD hook; Swapper sw; Donor donor;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), 25604624);
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(PM, OWNER, POSM, P2, address(0), uint256(0)), HOOK);
        hook = IHookD(HOOK);
        vm.prank(OWNER); hook.seed(3648751508805509367250261525102, -887200, 76600, 80e18);
        vm.prank(OWNER); hook.renounceOwnership();
        sw = new Swapper(PM); vm.deal(address(sw), 50 ether);
        donor = new Donor(PM); vm.deal(address(donor), 20 ether);
    }
    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(HOOK),
                        fee: 10_000, tickSpacing: 200, hooks: IHooks(HOOK)});
    }
    function test_DonateReachesHolders() public {
        // create shareholders so the fee accumulator can move
        sw.buy(_key(), 2 ether, address(0xA11CE));
        hook.pokeFees();
        uint256 accBefore = hook.accFeesPerShareETH();
        uint256 sharesBefore = hook.totalShares();

        donor.donateEth(_key(), 5 ether);   // third party gifts 5 ETH to the pool
        hook.pokeFees();

        uint256 accAfter = hook.accFeesPerShareETH();
        console2.log("totalShares            :", sharesBefore);
        console2.log("accFeesPerShareETH pre :", accBefore);
        console2.log("accFeesPerShareETH post:", accAfter);
        console2.log("donor kept any LP position? balanceOf(donor) PRISM:", hook.balanceOf(address(donor)));
        assertGt(accAfter, accBefore, "a plain donation reached PRISM holders");
        // and it arrives whole: 5 ETH over `sharesBefore` shares, scaled by ACC_SCALE (1e12)
        assertApproxEqRel((accAfter - accBefore) * sharesBefore / 1e12, 5 ether, 0.001e18,
            "the full donation was distributed, not a fraction");
        assertEq(hook.balanceOf(address(donor)), 0, "donor took no position and no fee share");
    }
}

contract Donor {
    IPoolManager pm;
    constructor(address _pm){ pm=IPoolManager(_pm); }
    receive() external payable {}
    function donateEth(PoolKey memory key, uint256 amt) external {
        pm.unlock(abi.encode(key, amt));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amt) = abi.decode(data,(PoolKey,uint256));
        pm.donate(key, amt, 0, "");
        pm.settle{value: amt}();
        return "";
    }
}
