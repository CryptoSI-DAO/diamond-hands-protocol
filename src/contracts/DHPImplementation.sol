// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDHPVault} from "../interfaces/IDHPVault.sol";

/// @title  DHPImplementation
/// @notice Implementation contract for a single Diamond Hands Vault clone.
/// @dev    Deployed ONCE on Base (and replicated on testnet/mainnet clones);
///         each user-facing vault is an EIP-1167 minimal proxy over this
///         contract, initialised with one specific underlying ERC-20.
///
///         Per-vault economic model (v1.4.0, #29 fixed canon):
///         - Taxes are FIXED: 5% entry / 10% exit — creators cannot
///           configure them (the factory hardwires the canon).
///         - Every tax splits six ways (#29 weights, fixed in code):
///             • 80% → pro-rata dividend pool (dividendShareBps = 8_000)
///             • 10% → burned (lock-in-vault, tracked in burnedBalance)
///             •  4% → DAO, via `feeCollector`
///             •  2% → vault creator (immutable, set at creation)
///             •  2% → creation platform (immutable, set at creation)
///             •  2% → usage platform (per-tx param; 0x0 → DAO fallback)
///         - Exit tax `exitTaxBps` on withdraw — same six-way split.
///         - Partner payouts that fail (blacklist/reverting receiver) are
///           booked to `stuckRevenue` — a named-recipient liability,
///           excluded from share pricing, claimable permissionlessly via
///           `claimStuck()`. No admin path can redirect or sweep them.
///         - Dividends accrue via Synthetix StakingRewards math:
///             `rewardPerTokenStored` ticks up by
///               `(dividendAmount * 1e18) / totalSupply`
///             on every tax event. Users claim via `claimDividend()` which
///             pays pending in the underlying token (not shares).
///         - Anti-FOT: deposits/withdrawals verify that the actual `balanceOf`
///           delta equals the expected pre-tax amount. Tokens with
///           fee-on-transfer, rebasing, or transfer hooks cannot pass.
///         - No admin functions on the vault. The factory is `Ownable` and
///           gets renounced post-launch.
///
///         Reentrancy note (v1.2.2): the underlying (asset) token and the
///         share token (this ERC-20) are DIFFERENT contracts. A malicious
///         asset token re-entering during `_distributeTax` or transfer hooks
///         holds no shares and no settled rewards, so every re-entry path is
///         inert. This separation is what makes per-function `nonReentrant`
///         sufficient — do not "simplify" the two-token split away.
///         (v1.4.0, audit H-NEW-1) Additionally, EVERY state-mutating entry
///         point carries `nonReentrant` — including `claimStuck`, whose
///         payout window was PoC-proven reentrable through a malicious
///         partner wallet's transfer hook before the fix.
///
///         Share accounting follows the standard ERC-4626 formula, but the
///         deposit/withdraw entry-points apply tax first and then mint/burn
///         shares off the net amount. We intentionally do NOT inherit ERC4626
///         directly because OZ v5 makes the underlying immutable at deploy
///         time, which doesn't fit our per-token-clone model. Divergences
///         from the ERC-4626 surface are enumerated in
///         `ERC4626_COMPATIBILITY.md`.
contract DHPImplementation is ERC20, ReentrancyGuardTransient, Ownable, IDHPVault {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────────

    uint16 internal constant BPS = 10_000;
    uint16 internal constant MAX_ENTRY_TAX_BPS = 1_000;  // 10%
    uint16 internal constant MAX_EXIT_TAX_BPS = 2_500;   // 25%

    // ── #29 partner-split weights (bps OF TAX). FIXED at launch (Carl) —
    //    same ratio on entry and exit. Sum + DIVIDEND = 10_000 exactly. ──
    uint16 internal constant WEIGHT_BURN_BPS = 1_000;            // 10% of tax → burned (lock-in-vault)
    uint16 internal constant WEIGHT_DAO_BPS = 400;               //  4% of tax → feeCollector (DAO)
    uint16 internal constant WEIGHT_CREATOR_BPS = 200;           //  2% of tax → vault creator
    uint16 internal constant WEIGHT_CREATION_PLATFORM_BPS = 200; //  2% of tax → creation platform
    uint16 internal constant WEIGHT_USAGE_PLATFORM_BPS = 200;    //  2% of tax → usage platform

    /// @dev (v1.4.0, audit M-NEW-1) TRUE bound on the dividend share under the
    ///      #29 fixed split: dividend + burn(1000) + DAO(400) + 3×200 partner
    ///      weights ≤ 10_000 ⇒ dividend ≤ 8_000. The old `MAX_DIVIDEND_SHARE_BPS
    ///      = 9_000` and the `dividendShare + PROTOCOL_FEE_BPS` check both
    ///      predate the partner weights and admitted a config that would
    ///      underflow `_distributeTax` (vault bricks on first deposit).
    uint16 internal constant MAX_DIVIDEND_SHARE_BPS = 8_000; // 80% of tax

    /// @dev The burn mechanism is the "lock-in-vault" model (tracked in
    ///      `burnedBalance`, subtracted from `totalAssets()` for share-price
    ///      math, but never leaves the vault). See `_distributeTax` for the
    ///      implementation. (The original `0x…dEaD` BURN_SINK constant was
    ///      removed in v1.2.2 — git history preserves it.)
    /// @dev Precision scale for `rewardPerTokenStored`.
    uint256 internal constant PRECISION = 1e18;
    // ──────────────────────────────────────────────────────────────────────────
    // Events (declared in IDHPVault; redeclared here so internal emit sites compile)
    // ──────────────────────────────────────────────────────────────────────────

    // Note: events are also declared in IDHPVault.sol. Solidity forbids declaring
    // the same event in both the interface and the implementing contract, so we
    // rely on the interface to provide them; internal call sites work because
    // the contract inherits the interface and inherits the events with it.

    /// @dev ERC-4626-compatible events re-declared here because the interface
    //      events above don't reach into this contract's name resolution
    //      chain. Solidity complains about dual declarations only when they
    //      match identically; we use distinct (less specific) signatures here.
    event Deposit(address sender, address owner, uint256 assets, uint256 shares);
    event Withdraw(address sender, address receiver, address owner, uint256 assets, uint256 shares);

    // ──────────────────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IDHPVault
    address public override factory;

    /// @inheritdoc IDHPVault
    address public override feeCollector;

    /// @inheritdoc IDHPVault
    uint16 public override entryTaxBps;

    /// @inheritdoc IDHPVault
    uint16 public override exitTaxBps;

    /// @inheritdoc IDHPVault
    uint16 public override dividendShareBps;

    /// @inheritdoc IDHPVault
    uint256 public override rewardPerTokenStored;

    /// @inheritdoc IDHPVault
    uint256 public override totalDividendsDistributed;

    /// @inheritdoc IDHPVault
    mapping(address account => uint256) public override rewardPerTokenPaid;

    /// @inheritdoc IDHPVault
    mapping(address account => uint256) public override rewards;

    /// @dev Per-vault accumulator for tokens that should be "burned" but
    ///      stay in the contract (lock-in-vault model). Subtracted from
    ///      `totalAssets()` for share-price math, so these tokens are
    ///      effectively removed from circulating supply without needing
    ///      to send them to an external burn address (which would DoS the
    ///      protocol on tokens like USDT/USDC that blacklist 0x…dEaD).
    uint256 public burnedBalance;

    /// @dev Global ledger of dividend IOUs accrued to holders but not yet
    ///      paid out (issue #26). Sum of all `rewards[account]` entries,
    ///      maintained incrementally: += dividend portion at every
    ///      `_accrueDividend()`, -= amount at every successful
    ///      `claimDividend()`. These tokens are still in the vault's ERC-20
    ///      balance but are contractually owed to specific holders — so they
    ///      must NOT back anyone's shares. Excluding them from
    ///      `totalAssets()` guarantees `balance >= burnedBalance +
    ///      totalUnclaimed` by construction, which makes every claim
    ///      always-payable and closes the death-spiral freeze window where
    ///      burn ratchets could previously outrun the balance while IOUs
    ///      sat inside backing.
    uint256 public totalUnclaimed;

    /// @dev The underlying token this vault wraps. Set in `initialize()`.
    IERC20 internal _assetToken;

    /// @dev Initialised flag — guards against re-initialisation of a clone.
    bool private _vaultInitialised;

    /// @dev Per-clone ERC-20 metadata. Read by the `name()` / `symbol()`
    ///      overrides below. Stored in this contract (not the OZ base)
    ///      because OZ v5 makes the equivalent fields `private`.
    string private _vaultName;
    string private _vaultSymbol;

    // ──────────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────────

    error AlreadyInitialised();
    error InvalidBpsConfiguration();
    error FeeOnTransferToken();
    error ZeroAddress();
    error ZeroAmount();
    error NoPendingDividend();
    error BelowMinimumFirstDeposit(uint256 required, uint256 provided);
    error InsufficientClaimAmount(uint256 requested, uint256 available);
    /// @dev (v1.2.2, audit L-NEW-1) Raised when share pricing is requested
    ///      while the vault holds shares but zero net assets. Previously this
    ///      state silently priced shares 1:1 against the raw balance (which is
    ///      exactly `burnedBalance` there), enabling redemptions out of the
    ///      locked burn tokens.
    error DegenerateVaultState();

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor (implementation-only, no functional state)
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev The implementation's own constructor never sees real token state
    ///      — it is only used as init-code for clones. Clones bypass the
    ///      constructor via delegatecall; their configuration is set in
    ///      `initialize()` below.
    constructor() ERC20("Diamond Hands Implementation", "DHPi") Ownable(msg.sender) {
        // (v1.2.2, audit I-NEW-2) Pre-mark the implementation as initialised
        // so `initialize()` can never run on it directly (which would let a
        // third party set itself as factory and strand tokens sent here by
        // mistake). Clones are unaffected: their storage slot starts fresh.
        _vaultInitialised = true;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Initialisation
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice One-shot initialisation called by DHPFactory on a fresh clone.
    /// @param minFirstDeposit_  Per-vault minimum first deposit in raw token
    ///                          units. Prevents 1-wei squat attacks on vaults
    ///                          for tokens with high decimals (see M-NEW-2).
    /// @param acceptFeesFromTransfer_ If true, accept tokens with FOT/hook
    ///                          behaviour. (v1.2.1, M-CARRIED-1.)
    function initialize(
        IERC20 token_,
        address feeCollector_,
        address vaultCreator_,
        address creationPlatform_,
        uint16 entryTaxBps_,
        uint16 exitTaxBps_,
        uint16 dividendShareBps_,
        uint256 minFirstDeposit_,
        bool acceptFeesFromTransfer_
    ) external {
        if (_vaultInitialised) revert AlreadyInitialised();
        if (address(token_) == address(0) || feeCollector_ == address(0)) revert ZeroAddress();
        if (vaultCreator_ == address(0) || creationPlatform_ == address(0)) revert ZeroAddress();
        if (entryTaxBps_ > MAX_ENTRY_TAX_BPS) revert InvalidBpsConfiguration();
        if (exitTaxBps_ > MAX_EXIT_TAX_BPS) revert InvalidBpsConfiguration();
        // (v1.4.0, audit M-NEW-1) Validate the FULL #29 weight sum, not the
        // pre-#29 "dividend + 0.5% fee" invariant. A legacy 9_000-dividend
        // config would make `taxAmount - assigned` underflow in
        // `_distributeTax`, bricking every deposit/withdraw on the clone.
        if (dividendShareBps_ + WEIGHT_BURN_BPS + WEIGHT_DAO_BPS +
            WEIGHT_CREATOR_BPS + WEIGHT_CREATION_PLATFORM_BPS + WEIGHT_USAGE_PLATFORM_BPS > BPS) {
            revert InvalidBpsConfiguration();
        }

        _vaultInitialised = true;
        factory = msg.sender;
        feeCollector = feeCollector_;
        vaultCreator = vaultCreator_;
        creationPlatform = creationPlatform_;
        entryTaxBps = entryTaxBps_;
        exitTaxBps = exitTaxBps_;
        dividendShareBps = dividendShareBps_;
        _assetToken = token_;
        minFirstDeposit = minFirstDeposit_;
        acceptFeesFromTransfer = acceptFeesFromTransfer_;

        // Build vault-specific ERC-20 metadata (name + symbol).
        string memory underlyingSym = IERC20Metadata(address(token_)).symbol();
        _vaultName = string.concat("Diamond Hands ", underlyingSym);
        _vaultSymbol = string.concat("dh", underlyingSym);

        emit VaultInitialised(address(token_), entryTaxBps_, exitTaxBps_, dividendShareBps_);
    }

    /// @inheritdoc IDHPVault
    function asset() public view override returns (IERC20) {
        return _assetToken;
    }

    /// @notice Vault name = "Diamond Hands {UNDERLYING_SYMBOL}".
    /// @dev    Override of OZ v5 ERC20.name(). The base `_name` storage is
    ///         unreachable (private), so we mirror it here.
    function name() public view virtual override returns (string memory) {
        return _vaultName;
    }

    /// @notice Vault symbol = "dh{UNDERLYING_SYMBOL}".
    function symbol() public view virtual override returns (string memory) {
        return _vaultSymbol;
    }

    /// @notice Total assets currently managed by the vault, net of burned tokens.
    /// @dev    For the per-vault case this equals the underlying token balance
    ///         held by the contract MINUS the burned (locked-in-vault) balance.
    ///         This is what backs the outstanding share supply: the share
    ///         price is `(totalAssets) / totalSupply`. Tokens in
    ///         `burnedBalance` are effectively removed from circulation
    ///         but stay in this contract (no external burn address required,
    ///         so the protocol works on tokens that blacklist 0x…dEaD).
    /// @dev    For rebasing tokens (stETH, AMPL, etc.), `balanceOf` can drop
    ///         below `burnedBalance` on a negative rebase. In that case this
    ///         function REVERTS loudly rather than silently returning 0. Silent
    ///         0 would silently make all shares appear worthless and let
    ///         griefers steal value. Loud revert is the safer failure mode —
    ///         off-chain indexers see the failure and can alert the team.
    /// @dev    (v1.2.2) The old `totalAssetsAfterTax()` view — which returned
    ///         the raw balance INCLUDING burned tokens — was removed: it
    ///         contradicted `totalAssets()` and trapped integrators into
    ///         publishing inflated numbers. (Audit L-NEW-3.)
    function totalAssets() public view returns (uint256) {
        uint256 bal = _assetToken.balanceOf(address(this));
        // (issue #26) Unclaimed dividend IOUs are owed to specific holders and
        // must not back anyone's shares. Requiring bal >= burnedBalance +
        // totalUnclaimed makes every claim payable by construction and stops
        // the burn accumulator from ever outrunning unencumbered backing —
        // previously a sustained death spiral (mass exits, nobody claiming)
        // could freeze the vault here (loud revert, but a freeze all the same).
        // (#29) Stuck partner revenue is likewise a named-recipient
        // liability: excluded from backing so it cannot inflate share
        // pricing, and its settlement (claimStuck) moves neither price nor
        // backing — bal and the liability leave together, 1:1.
        require(
            bal >= burnedBalance + totalUnclaimed + totalStuckRevenue,
            "DHP: token balance below burn + unclaimed liabilities"
        );
        return bal - burnedBalance - totalUnclaimed - totalStuckRevenue;
    }

    /// @dev Per-vault minimum first-deposit size (in raw token units). Set in
    ///      `initialize()`. Default is 1e10 raw (~0.00000001 ETH for 18-decimal,
    ///      ~100 token units for 8-decimal, ~10,000 token units for 6-decimal).
    ///      Made per-vault so the factory owner can configure it appropriately
    ///      for the token's decimals. (Audit finding M-NEW-2: a single constant
    ///      is vulnerable for 18-decimal tokens where 1e10 raw = $0.00004.)
    uint256 public minFirstDeposit;

    /// @dev If true, the vault accepts tokens with `safeTransfer`/`safeTransferFrom`
    ///      hooks that deduct a small fee (FOT) or perform other balance mutations
    ///      (rebasing, gas-burn, etc.). When false (the default), the vault reverts
    ///      on any transfer that doesn't deliver the full requested amount. (v1.2.1
    ///      fix for audit M-CARRIED-1: previously, the anti-FOT check rejected
    ///      tokens with legitimate hooks like rebasing or marketing-fee tokens.
    ///      Factory owners can now opt in to a permissive mode per vault.)
    bool public acceptFeesFromTransfer;

    // ── #29 partner wallets (immutable after initialize) ─────────────────
    // The 5% entry / 10% exit taxes are FIXED for every vault (Carl: no
    // creator configuration). These two addresses are set once at vault
    // creation by the creating frontend and receive their fixed share of
    // every in/out tax forever.

    /// @notice Wallet that created this vault (via the factory). Receives
    ///         2% of every tax on entry and exit.
    address public vaultCreator;

    /// @notice Frontend/platform that hosted the vault's creation tx.
    ///         Receives 2% of every tax on entry and exit. May equal
    ///         `vaultCreator`.
    address public creationPlatform;

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-4626 share accounting (re-implemented; not inherited)
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Convert assets → shares, taking entry tax into account.
    ///      `assets` is the gross deposit amount. Net assets entering the
    ///      vault (post-tax) are minted 1:1 to shares on first deposit;
    ///      subsequent deposits use the running exchange rate.
    /// @dev  (v1.2.2, audit L-NEW-1) The 1:1 fallback now applies ONLY when
    ///      `supply == 0` (truly empty vault). The old `assets == 0` half of
    ///      the guard also fired when supply > 0 but the balance had been
    ///      eaten down to the burned accumulator — a degenerate state in
    ///      which 1:1 pricing would let redemptions eat the locked (burned)
    ///      tokens and then permanently revert `totalAssets()` for everyone.
    ///      That state now reverts loudly instead.
    function _convertToShares(uint256 netAssets, bool roundingUp) internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 assets = totalAssets();
        if (supply == 0) return netAssets;
        if (assets == 0) revert DegenerateVaultState();
        uint256 numerator = netAssets * supply;
        uint256 quotient = numerator / assets;
        if (roundingUp && numerator % assets > 0) quotient += 1;
        return quotient;
    }

    /// @dev Convert shares → net assets that would be withdrawn.
    function _convertToAssets(uint256 shares, bool roundingUp) internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 assets = totalAssets();
        if (supply == 0) return shares;
        if (assets == 0) revert DegenerateVaultState();
        uint256 numerator = shares * assets;
        uint256 quotient = numerator / supply;
        if (roundingUp && numerator % supply > 0) quotient += 1;
        return quotient;
    }

    /// @inheritdoc IDHPVault
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 tax = (assets * entryTaxBps) / BPS;
        uint256 net = assets - tax;
        return _convertToShares(net, /*roundingUp=*/ false);
    }

    /// @inheritdoc IDHPVault
    function previewMint(uint256 shares) public view override returns (uint256) {
        // Gross assets needed to mint `shares` after-tax = shares + tax portion.
        // Solve: shares = (assets - tax_assets) * supply / totalAssets
        //       tax = assets * entryTaxBps / BPS
        // → shares * totalAssets = (assets * (BPS - entryTaxBps) / BPS) * supply
        // → assets = shares * totalAssets * BPS / (supply * (BPS - entryTaxBps))
        uint256 supply = totalSupply();
        if (supply == 0) return shares; // 1:1 on first deposit
        uint256 taxMultiplier = BPS - entryTaxBps;
        return Math.mulDiv(shares * totalAssets(), BPS, supply * taxMultiplier, Math.Rounding.Ceil);
    }

    /// @inheritdoc IDHPVault
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        // shares burned to deliver `assets` to the user post-tax.
        // assets_net = (shares_burned / totalSupply) * totalAssets * (BPS - exitTaxBps)/BPS
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        uint256 keepMultiplier = BPS - exitTaxBps;
        return Math.mulDiv(assets * supply, BPS, totalAssets() * keepMultiplier, Math.Rounding.Ceil);
    }

    /// @inheritdoc IDHPVault
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 netAssets = _convertToAssets(shares, /*roundingUp=*/ false);
        uint256 taxOnNet = (netAssets * exitTaxBps) / BPS;
        return netAssets - taxOnNet;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Deposit / Mint
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IDHPVault
    function deposit(uint256 assets, address receiver)
        public
        override
        returns (uint256 shares)
    {
        // #29: plain ERC-4626 entry — no usage platform in calldata, so the
        // usage-platform share routes to the DAO (headless calls must work).
        // Guard lives on depositWithPlatform; this thin delegator must NOT
        // be nonReentrant (nested guard entry would revert).
        return depositWithPlatform(assets, receiver, address(0));
    }

    /// @notice #29: deposit with the usage-platform attribution param.
    function depositWithPlatform(uint256 assets, address receiver, address usagePlatform_)
        public
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // First-deposit guard: if no shares exist yet, require a minimum
        // deposit. This prevents 1-wei squat attacks where a griefer takes
        // the first-depositor slot and then captures subsequent real
        // depositors' funds via the dividend pool. (Audit finding H-3.)
        // The minimum is per-vault (set in initialize()) and should be set
        // relative to the token's decimals. For 18-decimal tokens, 1e15
        // raw = $0.0004 which is still a meaningful cost. For 6-decimal
        // tokens, the factory owner should set it to 1e6 raw = 1.0 token.
        if (totalSupply() == 0 && assets < minFirstDeposit) {
            revert BelowMinimumFirstDeposit(minFirstDeposit, assets);
        }

        uint256 tax = (assets * entryTaxBps) / BPS;
        uint256 net = assets - tax;

        // (v1.2.2 addendum A1 — M-NEW-2, found by fuzz test DHPFuzzWalk) The
        // share conversion MUST read the PRE-DEPOSIT state so that
        // `deposit()` and `previewDeposit()` agree, exactly as in OZ's
        // ERC-4626 (which literally calls `previewDeposit()` before pulling
        // the assets). Converting after the pull+distribute made the
        // exchange-rate denominator include the deposit itself, silently
        // under-crediting large deposits relative to the previewed amount.
        shares = _convertToShares(net, /*roundingUp=*/ false);
        if (shares == 0) revert ZeroAmount();

        // Anti-FOT: pull the full `assets` from the user, then verify the
        // vault received exactly `assets` (unless `acceptFeesFromTransfer`
        // is set, in which case FOT/hook tokens are accepted). The check
        // uses balanceOf to catch any token behaviour that reduces the
        // amount received, including FOT, rebasing, or gas-burn hooks.
        uint256 preBal = _assetToken.balanceOf(address(this));
        _assetToken.safeTransferFrom(msg.sender, address(this), assets);
        uint256 postBal = _assetToken.balanceOf(address(this));
        if (!acceptFeesFromTransfer && postBal - preBal != assets) revert FeeOnTransferToken();

        // Dividend accounting: send fee+burn out first so totalAssets is correct,
        // then accrue the dividend index (using pre-mint supply), then mint
        // the shares computed above on the pre-deposit exchange rate.
        _distributeTax(tax, usagePlatform_);
        _accrueDividend(tax);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IDHPVault
    function mint(uint256 shares, address receiver)
        public
        override
        returns (uint256 assets)
    {
        // #29: plain entry — usage-platform share routes to the DAO.
        // Guard lives on mintWithPlatform (see deposit note).
        return mintWithPlatform(shares, receiver, address(0));
    }

    /// @notice #29: mint with the usage-platform attribution param.
    function mintWithPlatform(uint256 shares, address receiver, address usagePlatform_)
        public
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // First-deposit guard (same anti-squat protection as deposit()).
        // For mint(), require that totalAssets() is already at least the
        // minimum. (If totalSupply > 0, some other user has already
        // deposited, so the inflation attack isn't possible.)
        if (totalSupply() == 0) {
            // First-ever call to mint() must come after a deposit() that
            // established the minimum. We don't support a "pure mint" first
            // because that would require knowing the deposit size, which
            // previewMint can't determine when supply is 0.
            revert ZeroAmount();
        }

        assets = previewMint(shares);
        uint256 tax = (assets * entryTaxBps) / BPS;

        uint256 preBal = _assetToken.balanceOf(address(this));
        _assetToken.safeTransferFrom(msg.sender, address(this), assets);
        uint256 postBal = _assetToken.balanceOf(address(this));
        if (!acceptFeesFromTransfer && postBal - preBal != assets) revert FeeOnTransferToken();

        // Mirror deposit() order: distribute tax → accrue dividend → mint.
        // Distributing tax first means the user pays the post-distribute
        // exchange rate (correct), instead of over-minting at the
        // pre-distribute rate (the old bug).
        _distributeTax(tax, usagePlatform_);
        _accrueDividend(tax);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Withdraw / Redeem
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IDHPVault
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        returns (uint256 shares)
    {
        // #29: plain exit — usage-platform share routes to the DAO.
        // Guard lives on withdrawWithPlatform (see deposit note).
        return withdrawWithPlatform(assets, receiver, owner_, address(0));
    }

    /// @notice #29: withdraw with the usage-platform attribution param.
    function withdrawWithPlatform(uint256 assets, address receiver, address owner_, address usagePlatform_)
        public
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0) || owner_ == address(0)) revert ZeroAddress();

        // Settle owner's pending dividends before burning their shares.
        _settleDividend(owner_);

        shares = previewWithdraw(assets);

        // Compute the gross tax. Withdraw semantics: user wants `assets` net
        // in hand; the tax is paid on top by burning extra shares from `owner_`.
        // Solve: shares_to_burn = shares (above), of which `assets` is the net.
        // The total vault-side value burned = shares_to_burn * totalAssets() / supply.
        // The gross on which tax is charged = (shares * totalAssets() / supply) - assets.
        uint256 grossBurnedValue = Math.mulDiv(shares, totalAssets(), totalSupply(), Math.Rounding.Ceil);
        uint256 tax = grossBurnedValue - assets;

        // Allowance check.
        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }

        _burn(owner_, shares);

        // Send the net to the user. Anti-FOT: confirm the user received `assets`.
        // Done BEFORE _distributeTax so the safeTransfer can't be reordered against
        // the dividend math (CEI pattern: transfer value out, then update book).
        uint256 preBal = _assetToken.balanceOf(receiver);
        _assetToken.safeTransfer(receiver, assets);
        uint256 postBal = _assetToken.balanceOf(receiver);
        if (!acceptFeesFromTransfer && postBal - preBal != assets) revert FeeOnTransferToken();

        // Dividend accrual + tax distribution happen AFTER the burn + transfer so
        // totalAssets() reflects the post-exit vault state (fee + burn sent out,
        // dividend portion still backing remaining shareholders).
        _distributeTax(tax, usagePlatform_);
        _accrueDividend(tax);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @inheritdoc IDHPVault
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        returns (uint256 assets)
    {
        // #29: plain exit — usage-platform share routes to the DAO.
        // Guard lives on redeemWithPlatform (see deposit note).
        return redeemWithPlatform(shares, receiver, owner_, address(0));
    }

    /// @notice #29: redeem with the usage-platform attribution param.
    function redeemWithPlatform(uint256 shares, address receiver, address owner_, address usagePlatform_)
        public
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0) || owner_ == address(0)) revert ZeroAddress();

        _settleDividend(owner_);

        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }

        uint256 grossValue = _convertToAssets(shares, /*roundingUp=*/ true);
        uint256 tax = (grossValue * exitTaxBps) / BPS;
        assets = grossValue - tax;

        _burn(owner_, shares);

        // Send the net to the user. Anti-FOT: confirm the user received `assets`.
        uint256 preBal = _assetToken.balanceOf(receiver);
        _assetToken.safeTransfer(receiver, assets);
        uint256 postBal = _assetToken.balanceOf(receiver);
        if (!acceptFeesFromTransfer && postBal - preBal != assets) revert FeeOnTransferToken();

        // Tax distribution + dividend accrual happen AFTER the burn + transfer.
        _distributeTax(tax, usagePlatform_);
        _accrueDividend(tax);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Dividend math (Synthetix StakingRewards pattern)
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Settle a user's pending dividends into their `rewards` balance.
    ///      Called automatically before any share-changing operation.
    function _settleDividend(address account) internal {
        uint256 paid = rewardPerTokenPaid[account];
        uint256 current = rewardPerTokenStored;
        uint256 bal = balanceOf(account);
        if (bal > 0) {
            uint256 accrued = Math.mulDiv(bal, current - paid, PRECISION);
            rewards[account] += accrued;
        }
        rewardPerTokenPaid[account] = current;
    }

    /// @dev Bump `rewardPerTokenStored` by `taxAmount * 1e18 / totalSupply`.
    ///      Called immediately after every deposit/withdraw that took tax.
    ///      (v1.2.2, audit I-NEW-5) The division floors, so up to
    ///      `supply - 1` wei of each tax event's dividend portion is
    ///      index-dust that stays backing shares — standard Synthetix
    ///      StakingRewards behaviour, immaterial by design.
    function _accrueDividend(uint256 taxAmount) internal {
        uint256 dividendPortion = (taxAmount * dividendShareBps) / BPS;
        uint256 supply = totalSupply();
        if (supply > 0 && dividendPortion > 0) {
            rewardPerTokenStored += Math.mulDiv(dividendPortion, PRECISION, supply);
            totalDividendsDistributed += dividendPortion;
            // (issue #26) Reserve the FULL dividend portion. Per-holder IOUs
            // accrue lazily via the index and are floored, so the exact sum of
            // `rewards[...]` is ≤ dividendPortion; reserving the whole amount
            // is the conservative direction — index dust (I-NEW-5) now sits
            // in the claim reserve instead of backing shares.
            totalUnclaimed += dividendPortion;
        }
    }

    /// @dev Send every tax dollar to its sinks (#29 fixed split): dividends
    ///      stay in the vault, burn locks in-vault, DAO rides the collector,
    ///      three partner shares pay out (usage share follows `usagePlatform_`,
    ///      zero → DAO fallback).
    function _distributeTax(uint256 taxAmount, address usagePlatform_) internal {
        // ── #29 fixed partner split (Carl: taxes are FIXED) ──────────────────
        // dividends 80% · burn 10% · DAO 4% · creator 2% · creation-pl 2% ·
        // usage-pl 2%. Dust from floor-divisions lands on the burn portion.
        uint256 dividendPortion = (taxAmount * dividendShareBps) / BPS;
        uint256 burnPortion = (taxAmount * WEIGHT_BURN_BPS) / BPS;
        uint256 daoPortion = (taxAmount * WEIGHT_DAO_BPS) / BPS;
        uint256 creatorPortion = (taxAmount * WEIGHT_CREATOR_BPS) / BPS;
        uint256 creationPlatformPortion = (taxAmount * WEIGHT_CREATION_PLATFORM_BPS) / BPS;
        uint256 usagePortion = (taxAmount * WEIGHT_USAGE_PLATFORM_BPS) / BPS;

        uint256 assigned = dividendPortion + burnPortion + daoPortion +
            creatorPortion + creationPlatformPortion + usagePortion;
        burnPortion += taxAmount - assigned;

        if (burnPortion > 0) {
            // Lock-in-vault burn: tokens stay in the contract but are
            // subtracted from totalAssets() so they're effectively burned.
            burnedBalance += burnPortion;
            emit TokensBurned(burnPortion);
        }
        // dividendPortion STAYS in the vault — it backs the dividend pool.

        // DAO share (4%) rides the audited feeCollector rail — safeTransfer
        // is correct here because the collector is protocol-owned.
        if (daoPortion > 0) {
            _assetToken.safeTransfer(feeCollector, daoPortion);
        }

        // Partner shares (2% each). Blacklist-proof pattern (v1.2.2 audit
        // M-EXT-1): raw call, never reverts the user's tx, never donates —
        // a failing recipient's share is booked to `stuckRevenue` — claimable
        // by the entitled partner permissionlessly via `claimStuck()`; no
        // admin path exists (factory renounce does NOT strand these funds).
        _payPartner(0, vaultCreator, creatorPortion);
        _payPartner(1, creationPlatform, creationPlatformPortion);
        if (usagePlatform_ == address(0)) {
            // #29 headless fallback: usage share follows the DAO rail.
            if (usagePortion > 0) {
                _assetToken.safeTransfer(feeCollector, usagePortion);
                emit PartnerFeeRouted(3, feeCollector, usagePortion);
            }
        } else {
            _payPartner(2, usagePlatform_, usagePortion);
        }

        emit TaxCollected(
            0, taxAmount, dividendPortion, burnPortion,
            daoPortion, creatorPortion, creationPlatformPortion, usagePortion
        );
    }

    /// @dev #29: pay one external partner their tax share. Direct raw call —
    ///      a reverting/blacklisted/out-of-gas recipient must NOT revert the
    ///      depositor's transaction (DoS) and must NOT silently donate the
    ///      funds. On failure the amount is booked to `stuckRevenue[partner]`
    ///      and remains payable to the entitled partner ONLY via the
    ///      permissionless `claimStuck()` (v1.2.2 audit M-EXT-1 pattern;
    ///      owner sweeps deleted in v1.4.0 after Carl's security review).
    function _payPartner(uint8 role, address partner, uint256 amount) internal {
        if (amount == 0 || partner == address(0)) return;
        uint256 preBal = _assetToken.balanceOf(address(this));
        (bool ok, ) = address(_assetToken).call(abi.encodeCall(IERC20.transfer, (partner, amount)));
        uint256 postBal = _assetToken.balanceOf(address(this));
        // Paid = call succeeded AND vault balance fell by EXACTLY the amount
        // (a hook that mints the vault tokens mid-transfer must not count).
        if (ok && postBal < preBal && preBal - postBal == amount) {
            emit PartnerFeeRouted(role, partner, amount);
        } else {
            stuckRevenue[partner] += amount;
            totalStuckRevenue += amount;
            emit PartnerFeeRouted(role, address(0), amount); // partner=0x0 → stuck
        }
    }

    /// @notice #29: tokens booked as stuck when a partner transfer failed
    ///         (blacklist, reverting receiver, gas-limited hook). These are
    ///         LIABILITIES owed to a specific recipient — excluded from
    ///         `totalAssets()` so they never back anyone's shares — and
    ///         payable to the entitled partner ONLY via the permissionless
    ///         `claimStuck()`. There is deliberately no owner/admin sweep:
    ///         nobody can redirect a partner's earned revenue.
    mapping(address partner => uint256 amount) public stuckRevenue;

    /// @notice #29: sum of all booked stuck revenue. mirrors
    ///         Σ `stuckRevenue` so `totalAssets()` can exclude liabilities
    ///         in O(1) without iterating the partner mapping.
    uint256 public totalStuckRevenue;

    /// @notice #29: permissionless rescue — pays `partner`'s stuck revenue
    ///         to the partner themselves. Anyone may trigger settlement
    ///         (early settlement is harmless; the destination is hardwired
    ///         and cannot be redirected). Reverts with the underlying
    ///         token's error while the partner is still blacklisted or
    ///         refusing — retry once they can receive.
    function claimStuck(address partner) external nonReentrant {
        // (v1.4.0, audit H-NEW-1) The nonReentrant guard is load-bearing: the
        // payout transfer can re-enter THIS contract through the recipient's
        // transfer hook, and without the guard a malicious partner wallet
        // re-entered redeem() while the ledger decrements below were still
        // pending — double extraction and honest-depositor impairment
        // (PoC-proven in SELF_AUDIT_V1.4.0.md). Same guard family as every
        // other state-mutating entry point on this vault.
        uint256 amount = stuckRevenue[partner];
        if (amount == 0) revert ZeroAmount();
        stuckRevenue[partner] = 0;
        totalStuckRevenue -= amount;
        _assetToken.safeTransfer(partner, amount);
        emit StuckRevenueClaimed(partner, amount);
    }

    /// @inheritdoc IDHPVault
    /// @dev v1.2.1: accepts a minAmountOut slippage parameter to protect
    ///      against sandwich attacks. The dividend index is set BEFORE
    ///      every share-changing operation, but a user could still be
    ///      front-run by another claimer who changes the rpTs, so the
    ///      minAmountOut acts as a backstop. (Audit M-CARRIED-2.)
    function claimDividend(uint256 minAmountOut) public override nonReentrant returns (uint256 amount) {
        _settleDividend(msg.sender);
        amount = rewards[msg.sender];
        if (amount == 0) revert NoPendingDividend();
        if (amount < minAmountOut) revert InsufficientClaimAmount(minAmountOut, amount);
        rewards[msg.sender] = 0;
        // (issue #26) Release this claim's reservation. The subtraction is
        // checked: totalUnclaimed always ≥ sum of outstanding IOUs because
        // `_accrueDividend` reserves the full (unfloored) dividend portion.
        totalUnclaimed -= amount;
        uint256 preBal = _assetToken.balanceOf(msg.sender);
        _assetToken.safeTransfer(msg.sender, amount);
        uint256 postBal = _assetToken.balanceOf(msg.sender);
        if (!acceptFeesFromTransfer && postBal - preBal != amount) revert FeeOnTransferToken();
        emit DividendClaimed(msg.sender, amount);
    }

    /// @inheritdoc IDHPVault
    /// @dev Backwards-compatible overload that uses no slippage protection.
    ///      (For v1.2.1+ users, prefer claimDividend(minAmountOut).)
    ///      Note: this overload just calls the new one with 0. We don't
    ///      need the nonReentrant modifier on this one because the inner
    ///      call has it.
    function claimDividend() external override returns (uint256 amount) {
        return claimDividend(0);
    }

    /// @notice Total tokens burned (lock-in-vault accumulator). The amount of
    ///         underlying tokens that have been "burned" through the tax
    ///         mechanism but remain in the contract (subtracted from
    ///         totalAssets()). This is a public view that does NOT require
    ///         summing all TokensBurned events. (Audit finding M-NEW-1.)
    function totalBurned() external view returns (uint256) {
        return burnedBalance;
    }

    /// @notice Available dividend pool = the amount of underlying tokens
    ///         currently backing unpaid dividends. Used by external
    ///         integrations and for sanity checks.
    function availableDividendPool() external view returns (uint256) {
        // This may revert if the underlying token has rebased negatively.
        // (See audit finding C-NEW-1: we revert loudly on underflow.)
        return totalAssets();
    }

    // ──────────────────────────────────────────────────────────────────────────
    // (v1.2.2) pause()/unpause() REMOVED — audit I-NEW-1, carried L-CARRIED-1.
    // They were dead code since v1.0: gated `onlyFactory`, but the factory
    // never had a function that called them, so no vault could ever be
    // paused. The vault has no admin surface; if a pause story is wanted in
    // the future it belongs in the factory (`pauseVault(token)`) with all the
    // governance tradeoffs that implies.
    // ──────────────────────────────────────────────────────────────────────────

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-20 overrides — update dividend accounting on every transfer
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Hook into ERC-20 transfers to settle dividends for both parties.
    function _update(address from, address to, uint256 value)
        internal
        override
    {
        // Settle the dividend index for both sender and receiver. This is the
        // standard StakingRewards pattern: every balance mutation updates the
        // snapshot so the pro-rata math stays correct.
        if (from != address(0)) _settleDividend(from);
        if (to != address(0)) _settleDividend(to);
        super._update(from, to, value);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Reentrancy guard disables all view methods from writing — nothing here.
    // ──────────────────────────────────────────────────────────────────────────
}