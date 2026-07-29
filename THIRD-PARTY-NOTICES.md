# Third-party notices

This repository vendors its dependencies under `lib/` as real files rather than git submodules, so a
`git clone` builds with no extra steps. That means it **redistributes** third-party code, and each
package's own license travels with it. The license texts below are verbatim copies fetched from the
upstream repositories; nothing here modifies or reinterprets them.

| Package | Path | License | Text |
|---|---|---|---|
| Foundry `forge-std` | `lib/forge-std` | MIT / Apache-2.0 | `lib/forge-std/LICENSE-MIT`, `LICENSE-APACHE` |
| Solady | `lib/solady` | MIT | `lib/solady/LICENSE.txt` |
| Uniswap v4-periphery | `lib/v4-periphery` | MIT | `lib/v4-periphery/LICENSE` |
| Uniswap Permit2 | `lib/v4-periphery/lib/permit2` | MIT | `lib/v4-periphery/lib/permit2/LICENSE` |
| Uniswap v4-core | `lib/v4-periphery/lib/v4-core` | **BUSL-1.1** and MIT, per file | `lib/v4-periphery/lib/v4-core/licenses/BUSL_LICENSE`, `MIT_LICENSE` |

## The BUSL-1.1 files, specifically

Uniswap v4-core is dual-licensed per file. Most of the vendored subset is MIT, but **three files are
Business Source License 1.1**, which is a source-available license and *not* an open-source license until
its Change Date:

```
lib/v4-periphery/lib/v4-core/src/libraries/CurrencyReserves.sol
lib/v4-periphery/lib/v4-core/src/libraries/Lock.sol
lib/v4-periphery/lib/v4-core/src/libraries/NonzeroDeltaCount.sol
```

Read `licenses/BUSL_LICENSE` before doing anything with them beyond building and deploying this project.
Its parameters, as published by the licensor:

- **Licensor:** Universal Navigation Inc.
- **Licensed Work:** Uniswap V4 Core
- **Change Date:** the earlier of 2027-06-15 or a date specified at a URL named in the license
- **Change License:** MIT
- **Additional Use Grant:** as stated in the license text — read it rather than relying on this summary

BUSL-1.1 requires the license to be displayed on each copy of the licensed work, which is why these files
are included rather than referenced. It also restricts production use outside the Additional Use Grant, so
if you are reusing this repository for something other than deploying this token, check that grant against
your intended use.

## The verification the SPDX tags support

Every vendored `.sol` file carries its own `SPDX-License-Identifier`, so the licensing is machine-checkable
rather than a matter of trust. As vendored:

```
lib/solady/src                        6 files   MIT
lib/v4-periphery/src                 12 files   MIT
lib/v4-periphery/lib/permit2          2 files   MIT
lib/v4-periphery/lib/v4-core/src     19 files   MIT
                                      3 files   BUSL-1.1
```

Re-derive it yourself with:

```bash
grep -rhoE 'SPDX-License-Identifier:.*' lib/ | sort | uniq -c
```

## This project's own code

`src/`, `script/`, `test/`, `merkle/` and the documentation are MIT, per the root `LICENSE`. That covers
this project's code only — it does not and cannot relicense anything under `lib/`.
