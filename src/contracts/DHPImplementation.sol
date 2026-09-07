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
///         Per-vault economic model:
///         - Entry tax `entryTaxBps` on deposit. Split into:
///             • `dividendShareBps` of the tax → pro-rata dividend pool
///             • 0.5% protocol fee → `feeCollector`
///             • Remainder → `0x…dEaD` (burned forever)
///         - Exit tax `exitTaxBps` on withdraw — same split.
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
    uint16 internal constant PROTOCOL_FEE_BPS = 50;      // 0.5%
    uint16 internal constant MAX_DIVIDEND_SHARE_BPS = 9_000; // 90%

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

    error OnlyFactory();
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
    // Modifiers
    // ──────────────────────────────────────────────────────────────────────────

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

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
        uint16 entryTaxBps_,
        uint16 exitTaxBps_,
        uint16 dividendShareBps_,
        uint256 minFirstDeposit_,
        bool acceptFeesFromTransfer_
    ) external {
        if (_vaultInitialised) revert AlreadyInitialised();
        if (address(token_) == address(0) || feeCollector_ == address(0)) revert ZeroAddress();
        if (entryTaxBps_ > MAX_ENTRY_TAX_BPS) revert InvalidBpsConfiguration();
        if (exitTaxBps_ > MAX_EXIT_TAX_BPS) revert InvalidBpsConfiguration();
        if (dividendShareBps_ + PROTOCOL_FEE_BPS > BPS) revert InvalidBpsConfiguration();

        _vaultInitialised = true;
        factory = msg.sender;
        feeCollector = feeCollector_;
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
        require(
            bal >= burnedBalance,
            "DHP: token balance below burn accumulator (rebase or accounting issue)"
        );
        return bal - burnedBalance;
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
        // then accrue the dividend index (using pre-mint supply), then mint shares
        // based on the post-tax exchange rate.
        _distributeTax(tax);
        _accrueDividend(tax);

        shares = _convertToShares(net, /*roundingUp=*/ false);
        if (shares == 0) revert ZeroAmount();
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IDHPVault
    function mint(uint256 shares, address receiver)
        public
        override
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
        _distributeTax(tax);
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
        _distributeTax(tax);
        _accrueDividend(tax);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @inheritdoc IDHPVault
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
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
        _distributeTax(tax);
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
        }
    }

    /// @dev Send the dividend portion, the burn portion, and the protocol fee
    ///      to their respective sinks.
    ///      - dividend portion: stays in the vault, backs the dividend pool
    ///      - protocol portion: sent to `feeCollector` (DAO-controlled)
    ///      - burn portion: tracked in `burnedBalance` (lock-in-vault model).
    ///        The tokens themselves do NOT leave the contract — they remain
    ///        in the contract's balance but are subtracted from `totalAssets()`
    ///        so they cannot be withdrawn by anyone. This makes the burn
    ///        deflationary without depending on an external burn address,
    ///        which would be blacklisted by USDT/USDC/BUSD-style tokens.
    function _distributeTax(uint256 taxAmount) internal {
        uint256 dividendPortion = (taxAmount * dividendShareBps) / BPS;
        uint256 protocolPortion = (taxAmount * PROTOCOL_FEE_BPS) / BPS;
        uint256 burnPortion = taxAmount - dividendPortion - protocolPortion;

        if (protocolPortion > 0) {
            _assetToken.safeTransfer(feeCollector, protocolPortion);
        }
        if (burnPortion > 0) {
            // Lock-in-vault burn: tokens stay in the contract but are
            // subtracted from totalAssets() so they're effectively burned.
            burnedBalance += burnPortion;
            emit TokensBurned(burnPortion);
        }
        // dividendPortion STAYS in the vault — it backs the dividend pool.
        emit TaxCollected(0, taxAmount, dividendPortion, burnPortion, protocolPortion);
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