/**
 * Addresses that must never appear as a leaf in the airdrop tree.
 *
 * `PrismMigration.claim` is permissionless and always delivers to `account`, so a row naming one of
 * these is claimable by anyone and lands PRISM on an address that cannot hold fee-shares, diverting
 * that slice of every future fee round permanently. Infrastructure that merely routes or custodies PRISM is not an
 * end holder.
 *
 * Shared by `generate.mjs` (which REFUSES to build a tree containing one) and `prepare-basis.mjs`
 * (which drops them from a raw chain snapshot, with a printed manifest of what it dropped).
 */
export const FORBIDDEN = new Map([
  ["0x000000000004444c5dc75cb358380d2e3de08a90", "Uniswap V4 PoolManager"],
  ["0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e", "Uniswap V4 PositionManager"],
  ["0x000000000022d473030f116ddee9f6b43ac78ba3", "canonical Permit2"],
  ["0x000000000000000000000000000000000000dead", "burn sink"],
  ["0x0000000000000000000000000000000000000000", "zero address"],
  ["0xbd3ab5859f244cc9f51ee0ca755c5cf663d80040", "legacy PRISM deployment"],
  ["0x1fdbf67169e64e588df05f3bb430f60f28b84484", "Uniswap V3 USDC/PRISM 1% pool"],
  ["0x69b99bd1b7987d3efd9c3ed53ddca0cc3a5b7be8", "Uniswap V3 USDC/PRISM 0.3% pool"],
  ["0xefd99d28372d25cefac336a0f1ad8c898fc4de3d", "Uniswap V3 WETH/PRISM 0.3% pool"],
  ["0x74c91c032f583e38c8a85790b78515911f290dc8", "Uniswap V3 WETH/PRISM 1% pool"],
  // Uniswap V2. This list enumerated V3 and V4 and forgot that the legacy token also had a V2 pair, so
  // this address reached the SHIPPED tree as a leaf holding 20975963357469 wei — see the note below.
  // Verified on mainnet: UniswapV2Factory.getPair(legacy PRISM, WETH) returns exactly this address, and
  // it answers symbol() with "UNI-V2".
  ["0x280e1ad2952357a6089fe929af051078d176588b", "Uniswap V2 PRISM/WETH pair"],
]);

/**
 * KNOWN DEFECT IN THE SHIPPED TREE — deliberately not corrected.
 *
 * `airdrop/basis.json` row 988 is the Uniswap V2 pair above, at 20975963357469 wei
 * (0.000020975963357469 PRISM). It predates this entry, so `generate.mjs`'s guard never fired on it.
 * Claiming that row sends this PRISM to a V2 pair whose token0/token1 are the legacy PRISM and WETH; a
 * UniswapV2Pair can only ever move those two, and has no rescue, so the tokens are unreachable
 * forever. `claim` is permissionless and `push-airdrop.mjs` does not filter this list, so the default
 * push will destroy them.
 *
 * Left as-is on purpose. The loss is 4.2e-9 of supply, about a tenth of a cent at the launch
 * valuation, and because it is far below one whole token it mints ZERO fee-share NFTs — so it dilutes
 * no holder and does not reactivate the parking bug this list exists to prevent. Removing the row means
 * a new Merkle root, and
 * with it new proofs, a new canary, a new MIGRATION_AMOUNT and the loss of every fork-verified number
 * behind the current launch. Re-deriving the most consequential constant in the deploy to recover a
 * fraction of a cent is the worse trade. Skipping the row in the push saves nothing either: unclaimed
 * PRISM is locked in the vault forever, so the tokens are equally gone.
 *
 * Because the row is already in the shipped basis, `generate.mjs` must still be able to rebuild the
 * shipped root from it — that reproducibility is the whole point of committing the basis. So the address
 * is grandfathered THERE (with a warning) and only there. `prepare-basis.mjs` drops it like any other
 * forbidden address, so no future snapshot can carry it forward.
 */
/// Keyed on address AND exact amount. Address alone was not enough: the whole argument for tolerating
/// this row is that 20975963357469 wei is below one whole token, so it mints no fee-shares and dilutes
/// nobody. Raise the amount and that argument evaporates — 25 PRISM at the same address would mint 25
/// fee-shares to a UniswapV2Pair, which is the parking bug this list exists to prevent. An address-keyed
/// exception would have waved that through with a warning whose text asserted the opposite.
export const GRANDFATHERED = new Map([
  [
    "0x280e1ad2952357a6089fe929af051078d176588b",
    { amount: 20975963357469n, why: "already a leaf in the shipped tree (root 0x2cd60218…d33e12f)" },
  ],
]);
