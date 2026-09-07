# DHP and ERC-4626 — Compatibility Notes (v1.2.2)

Diamond Hands vaults follow the spirit of [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) but deliberately **do not inherit OZ's `ERC4626`** (v5 makes the underlying asset immutable in the constructor, which doesn't fit the per-token clone model). Integrators should treat DHP vaults as *4626-like* and mind every divergence below.

## Divergences

| # | Surface | ERC-4626 expectation | DHP v1.2.2 behaviour |
|---|---|---|---|
| 1 | `asset()` | returns `address` of underlying | Returns `IERC20` (the contract object). Read the underlying with `IERC20Metadata(address(vault.asset()))`. |
| 2 | `totalAssets()` | raw token balance held | Returns `balanceOf(vault) − burnedBalance` — the amount that actually backs shares. Burned (lock-in-vault) tokens are excluded. Reverts loudly if the balance drops below `burnedBalance` (rebasing-token guard). |
| 3 | `totalAssetsAfterTax()` | — | **Removed in v1.2.2.** It returned the raw balance *including* burned tokens and contradicted `totalAssets()`. Use `totalAssets()`. |
| 4 | `maxDeposit` / `maxMint` / `maxWithdraw` / `maxRedeem` | required by the EIP | **Not implemented.** Frontends should implement their own caps client-side. |
| 5 | `mint()` on an empty vault | works; mints shares for assets | **Reverts** (`ZeroAmount`). A fresh vault must be seeded via `deposit()` (which enforces the per-vault `minFirstDeposit` anti-squat guard). `mint()` is only usable once `totalSupply() > 0`. |
| 6 | `preview*` functions | mirror the mint/deposit/withdraw/redeem outcomes exactly | They do mirror outcomes, **but all previews are net-of-tax by design** (the EIP's plain 4626 vaults have no tax concept). `previewDeposit(x)` returns shares *after* the entry tax; `previewRedeem(s)` returns assets *after* the exit tax. |
| 7 | `deposit()` shares math | assets → shares at exchange rate | Same, but conversion runs on **post-tax** net assets, and the first depositor receives 1:1 net shares. |
| 8 | Withdrawal flows | burn shares → send assets | CEI order: dividends settle → shares burn → assets transfer (balance-checked) → tax distributed/accrued. |
| 9 | Fee-on-transfer tokens | revert / misaccount | Strict mode (default) reverts via balance-delta checks (`FeeOnTransferToken`). Per-vault `acceptFeesFromTransfer: true` opts into hook tokens — with the known tradeoff that share pricing still assumes full-value delivery (documented in SELF_AUDIT_V1.2.2.md I-NEW-4). |
| 10 | `DegenerateVaultState` | — | New in v1.2.2: share pricing reverts loudly if `totalSupply() > 0` but `totalAssets() == 0`, instead of the old 1:1 fallback that could let redemptions eat locked burn tokens. |

## Integrator checklist

1. Read the underlying via `address(vault.asset())`.
2. Use `totalAssets()` (never the removed `totalAssetsAfterTax()`).
3. Don't call `mint()` on a zero-supply vault — use `deposit()`.
4. Expect tax in every preview; display "shares you receive are net of the X% entry tax".
5. Track fee inflows via each vault's `TaxCollected` event (the collector has no per-deposit event by design).
6. Handle `DegenerateVaultState`, `BelowMinimumFirstDeposit`, `InsufficientClaimAmount` custom errors in UIs.
