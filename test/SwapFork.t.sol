// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}      from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency}     from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks}       from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams}   from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IHookSeed {
    function seed(uint160, int24, int24, uint128) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function pokeFees() external;
    function claim(uint256) external;
    function ownedTokensOf(address) external view returns (uint256[] memory);
    function accFeesPerShareETH() external view returns (uint256);
    function accFeesPerSharePRISM() external view returns (uint256);
    function pendingETH(address) external view returns (uint256);
    function pendingPRISM(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// Minimal V4 swapper: exact-in ETH -> PRISM (zeroForOne) via unlock/swap/settle/take.
contract Swapper {
    using BalanceDeltaLibrary for BalanceDelta;
    IPoolManager public pm;
    constructor(address _pm) { pm = IPoolManager(_pm); }
    receive() external payable {}

    function buy(PoolKey memory key, uint256 ethIn, address recipient) external returns (uint256) {
        return abi.decode(pm.unlock(abi.encode(uint8(1), key, ethIn, recipient)), (uint256));
    }
    // Sell `prismIn` PRISM (this contract must already hold it) for ETH -> generates a PRISM fee.
    function sell(PoolKey memory key, uint256 prismIn, address recipient) external returns (uint256) {
        return abi.decode(pm.unlock(abi.encode(uint8(2), key, prismIn, recipient)), (uint256));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "only pm");
        (uint8 mode, PoolKey memory key, uint256 amtIn, address recipient) =
            abi.decode(data, (uint8, PoolKey, uint256, address));
        if (mode == 1) { // BUY: ETH -> PRISM (zeroForOne)
            BalanceDelta delta = pm.swap(
                key, SwapParams({zeroForOne: true, amountSpecified: -int256(amtIn), sqrtPriceLimitX96: 4295128740}), "");
            uint256 out = uint256(uint128(delta.amount1()));
            pm.settle{value: amtIn}();
            pm.take(key.currency1, recipient, out);
            return abi.encode(out);
        } else {          // SELL: PRISM -> ETH (oneForZero)
            BalanceDelta delta = pm.swap(
                key, SwapParams({zeroForOne: false, amountSpecified: -int256(amtIn),
                    sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341}), "");
            uint256 out = uint256(uint128(delta.amount0()));
            pm.sync(key.currency1);
            IHookSeed(Currency.unwrap(key.currency1)).transfer(address(pm), amtIn);
            pm.settle();
            pm.take(key.currency0, recipient, out);
            return abi.encode(out);
        }
    }
}

/// Runs a mint→poke→claim atomically (through the swapper) in one tx to test the anti-JIT vs. a
/// REAL swap-driven mint.
contract JITBuyer {
    function attack(Swapper sw, PoolKey memory key, IHookSeed hook, uint256 ethIn)
        external returns (uint256 pendingAfter)
    {
        sw.buy(key, ethIn, address(this));       // buy PRISM -> mints fresh shares to me (this tx)
        hook.pokeFees();                          // book the swap's fees (pool now relocked)
        uint256[] memory ids = hook.ownedTokensOf(address(this));
        if (ids.length > 0) hook.claim(ids[0]);   // try to realize on a fresh share -> quarantined
        pendingAfter = hook.pendingETH(address(this)) + hook.pendingPRISM(address(this));
    }
}

contract SwapFork is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2       = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER = address(0xB0B);
    address constant HOOK  = address(0x2040);
    uint256 constant FORK_BLOCK = 25604624;

    IHookSeed hook;
    Swapper swapper;
    address constant HOLDER = address(0xB333); // buys in setUp (a prior tx) -> not JIT-quarantined

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(HOOK),
            fee: 10000, tickSpacing: 200, hooks: IHooks(HOOK)
        });
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        deployCodeTo("PrismHookV2.sol:PrismHookV2", abi.encode(POOL_MANAGER, OWNER, POSM, PERMIT2, address(0), uint256(0)), HOOK);
        hook = IHookSeed(HOOK);
        vm.prank(OWNER);
        hook.seed(3648751508805509367250261525102, -887200, 76600, 80e18); // ~3680 PRISM of depth
        swapper = new Swapper(POOL_MANAGER);
        vm.deal(address(swapper), 100 ether);

        // HOLDER buys here (setUp = a separate tx), so its shares aren't same-tx quarantined
        // when claimed inside a test.
        swapper.buy(_key(), 0.1 ether, HOLDER);
        // Consume the F3 forfeit-first-collection (armed by seed) so later pokes distribute.
        hook.pokeFees();
    }

    /// A real ETH->PRISM swap: buyer receives PRISM, DN404 mints them fee-share NFTs, and a
    /// subsequent poke books the real 1% pool fee into the accumulator.
    function test_RealSwapMintsSharesAndAccruesFees() public {
        address buyer = address(0xB111);
        uint256 out = swapper.buy(_key(), 0.1 ether, buyer);
        assertGt(out, 1 ether, "buyer received multiple whole PRISM");
        assertEq(hook.balanceOf(buyer), out, "PRISM credited");
        // Mirrored up to MAX_REALIGN (128) per transfer; a buy larger than that under-mirrors by
        // design and the remainder is caught up via syncNFTs.
        uint256 expectedShares = out / 1 ether > 128 ? 128 : out / 1 ether;
        assertEq(hook.nftBalanceOf(buyer), expectedShares, "whole tokens mirrored to fee shares");
        assertGt(hook.nftBalanceOf(buyer), 0, "fee shares actually minted");
        console2.log("PRISM out:", out / 1e15, "milli; shares:", hook.nftBalanceOf(buyer));

        // Book fees from the swap (1% pool fee accrued to the hook's LP position).
        hook.pokeFees();
        assertTrue(
            hook.accFeesPerShareETH() > 0 || hook.accFeesPerSharePRISM() > 0,
            "real swap fees accrued into the accumulator"
        );
        console2.log("accETH:", hook.accFeesPerShareETH(), "accPRISM:", hook.accFeesPerSharePRISM());
    }

    /// Anti-JIT vs a REAL swap: buy (mint fresh shares) -> poke -> claim, atomically. The fresh
    /// shares must realize ZERO (quarantine), even though real fees were just booked.
    function test_RealSwapAtomicJITYieldsZero() public {
        // HOLDER (from setUp) already gives standing fees to chase.
        JITBuyer atk = new JITBuyer();
        uint256 pending = atk.attack(swapper, _key(), hook, 0.1 ether);
        assertEq(pending, 0, "atomic JIT via a real swap captured zero");
    }

    /// PRISM-side fee path against real swaps: a sell generates a PRISM fee; poke accrues it; a
    /// holder claims it; and the hook stays solvent in PRISM (balance >= pending obligations).
    function test_RealSellAccruesPrismFeesAndStaysSolvent() public {
        assertGt(hook.balanceOf(HOLDER), 5 ether, "holder (from setUp) has PRISM to sell");

        // A DIFFERENT seller sells PRISM back through the swapper -> 1% fee taken in PRISM.
        // (We move HOLDER's tokens via the swapper; HOLDER keeps enough shares to claim on.)
        vm.prank(HOLDER);
        hook.transfer(address(swapper), 5 ether);
        swapper.sell(_key(), 5 ether, HOLDER);

        hook.pokeFees();
        assertGt(hook.accFeesPerSharePRISM(), 0, "PRISM fees accrued from the sell");

        // HOLDER's remaining shares (minted in setUp, a prior tx) claim their PRISM fees.
        uint256[] memory ids = hook.ownedTokensOf(HOLDER);
        assertGt(ids.length, 0, "holder still holds shares");
        hook.claim(ids[0]);

        assertGt(hook.pendingPRISM(HOLDER), 0, "holder actually earned PRISM fees");
        // Solvency: the hook holds at least what it owes in pending PRISM.
        assertGe(hook.balanceOf(HOOK), hook.pendingPRISM(HOLDER), "hook solvent on pending PRISM");
        console2.log("holder pending PRISM (milli):", hook.pendingPRISM(HOLDER) / 1e15);
    }

    /// Community fee split against real swaps: of the PRISM fee, ~20% goes to the burn sink and
    /// ~80% to holders; ETH fees are untouched (100% to holders).
    function test_RealPrismFeeSplit80_20() public {
        address BURN = 0x000000000000000000000000000000000000dEaD;
        uint256 SCALE = 1e12; // ACC_SCALE

        // Generate a PRISM fee via a sell.
        vm.prank(HOLDER);
        hook.transfer(address(swapper), 8 ether);
        swapper.sell(_key(), 8 ether, HOLDER);

        uint256 burnBefore = hook.balanceOf(BURN);
        uint256 accBefore  = hook.accFeesPerSharePRISM();
        uint256 shares     = hook.totalShares();

        hook.pokeFees();

        uint256 burned      = hook.balanceOf(BURN) - burnBefore;
        uint256 accDelta    = hook.accFeesPerSharePRISM() - accBefore;
        uint256 toHolders   = accDelta * shares / SCALE; // PRISM credited to the accumulator
        assertGt(burned, 0, "some PRISM was burned");
        assertGt(toHolders, 0, "some PRISM went to holders");

        // burned : toHolders should be ~ 20 : 80  (i.e. burned*4 ~ toHolders), within rounding.
        // Assert 3.6*burned <= toHolders <= 4.4*burned (10% tolerance band around 4x).
        assertLe(burned * 36, toHolders * 10, "burn share not above ~22%");
        assertGe(burned * 44, toHolders * 10, "burn share not below ~18%");
        console2.log("PRISM burned:", burned, "to holders:", toHolders);
    }
}
