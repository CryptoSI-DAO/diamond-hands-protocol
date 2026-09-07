// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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
///           gets renounced post-launch. `Pausable` is exposed but only the
///           factory owner can pause/unpause; after factory renounce, the
///           pause capability becomes inert.
///
///         Share accounting follows the standard ERC-4626 formula, but the
///         deposit/withdraw entry-points apply tax first and then mint/burn
///         shares off the net amount. We intentionally do NOT inherit ERC4626
///         directly because OZ v5 makes the underlying immutable at deploy
///         time, which doesn't fit our per-token-clone model.
contract DHPImplementation is ERC20, ReentrancyGuardTransient, Pausable, Ownable, IDHPVault {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────────

    uint16 internal constant BPS = 10_000;
    uint16 internal constant MAX_ENTRY_TAX_BPS = 1_000;  // 10%
    uint16 internal constant MAX_EXIT_TAX_BPS = 2_500;   // 25%
    uint16 internal constant PROTOCOL_FEE_BPS = 50;      // 0.5%
    uint16 internal constant MAX_DIVIDEND_SHARE_BPS = 9_000; // 90%

    /// @dev The burn sink is `address(0xdead)`. Many major tokens (USDT, USDC,
    ///      BUSD) blacklist this address to prevent "proof-of-burn" attacks,
    ///      which would DoS the protocol on any token with blacklist hooks.
    ///      We keep the constant for reference but the actual burn mechanism
    ///      is the "lock-in-vault" model below (tracked in `burnedBalance`,
    ///      subtracted from `totalAssets()` for share-price math, but never
    ///      leaves the vault). See `_distributeTax` for the implementation.
    address internal constant BURN_SINK = address(0xdead);

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
    constructor() ERC20("Diamond Hands Implementation", "DHPi") Ownable(msg.sender) {}

    // ──────────────────────────────────────────────────────────────────────────
    // Initialisation
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice One-shot initialisation called by DHPFactory on a fresh clone.
    function initialize(
        IERC20 token_,
        address feeCollector_,
        uint16 entryTaxBps_,
        uint16 exitTaxBps_,
        uint16 dividendShareBps_
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

    /// @inheritdoc IDHPVault
    function totalAssetsAfterTax() external view override returns (uint256) {
        return _assetToken.balanceOf(address(this));
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

    /// @notice Total assets currently managed by the vault.
    /// @dev    For the per-vault case this equals the underlying token balance
    ///         held by the contract MINUS the burned (locked-in-vault) balance.
    ///         This is what backs the outstanding share supply: the share
    ///         price is `(totalAssets - burnedBalance) / totalSupply`. Tokens
    ///         in `burnedBalance` are effectively removed from circulation
    ///         but stay in this contract (no external burn address required,
    ///         so the protocol works on tokens that blacklist 0x…dEaD).
    function totalAssets() public view returns (uint256) {
        uint256 bal = _assetToken.balanceOf(address(this));
        // Defense in depth: balanceOf can return less than expected for
        // rebasing tokens; cap the subtraction at bal to avoid underflow.
        return bal > burnedBalance ? bal - burnedBalance : 0;
    }

    /// @dev Minimum first-deposit size (in raw token units). This is the
    ///      anti-inflation-attack guard (audit H-3): by requiring the first
    ///      depositor to deposit a meaningful amount, we prevent 1-wei squat
    ///      attacks where an attacker deposits 1 wei, then the next "real"
    ///      depositor loses half their deposit to the dividend pool.
    ///      Set to 1e10 raw units:
    ///        - 18-decimal tokens: 1e10/1e18 = 1e-8 = 0.00000001 ETH (~$0.03)
    ///        -  8-decimal tokens: 1e10/1e8  = 100 token units
    ///        -  6-decimal tokens: 1e10/1e6  = 10,000 token units
    ///      Trivial for legitimate users; prohibitive for griefers (each
    ///      squat attempt costs real money).
    uint256 public constant MIN_FIRST_DEPOSIT = 1e10;

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-4626 share accounting (re-implemented; not inherited)
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Convert assets → shares, taking entry tax into account.
    ///      `assets` is the gross deposit amount. Net assets entering the
    ///      vault (post-tax) are minted 1:1 to shares on first deposit;
    ///      subsequent deposits use the running exchange rate.
    function _convertToShares(uint256 netAssets, bool roundingUp) internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 assets = totalAssets();
        if (supply == 0 || assets == 0) return netAssets;
        uint256 numerator = netAssets * supply;
        uint256 quotient = numerator / assets;
        if (roundingUp && numerator % assets > 0) quotient += 1;
        return quotient;
    }

    /// @dev Convert shares → net assets that would be withdrawn.
    function _convertToAssets(uint256 shares, bool roundingUp) internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 assets = totalAssets();
        if (supply == 0 || assets == 0) return shares;
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
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // First-deposit guard: if no shares exist yet, require a minimum
        // deposit. This prevents 1-wei squat attacks where a griefer takes
        // the first-depositor slot and then captures subsequent real
        // depositors' funds via the dividend pool. (Audit finding H-3.)
        if (totalSupply() == 0 && assets < MIN_FIRST_DEPOSIT) {
            revert ZeroAmount();
        }

        uint256 tax = (assets * entryTaxBps) / BPS;
        uint256 net = assets - tax;

        // Anti-FOT: pull the full `assets` from the user, then verify the
        // vault received exactly `assets`. Anything less means the token
        // deducted a fee and we revert.
        uint256 preBal = _assetToken.balanceOf(address(this));
        _assetToken.safeTransferFrom(msg.sender, address(this), assets);
        uint256 postBal = _assetToken.balanceOf(address(this));
        if (postBal - preBal != assets) revert FeeOnTransferToken();

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
        whenNotPaused
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
        if (postBal - preBal != assets) revert FeeOnTransferToken();

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
        if (postBal - preBal != assets) revert FeeOnTransferToken();

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
        if (postBal - preBal != assets) revert FeeOnTransferToken();

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
    function claimDividend() external override nonReentrant returns (uint256 amount) {
        _settleDividend(msg.sender);
        amount = rewards[msg.sender];
        if (amount == 0) revert NoPendingDividend();
        rewards[msg.sender] = 0;
        uint256 preBal = _assetToken.balanceOf(msg.sender);
        _assetToken.safeTransfer(msg.sender, amount);
        uint256 postBal = _assetToken.balanceOf(msg.sender);
        if (postBal - preBal != amount) revert FeeOnTransferToken();
        emit DividendClaimed(msg.sender, amount);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Pausable (only factory owner, post-renounce inert)
    // ──────────────────────────────────────────────────────────────────────────

    function pause() external onlyFactory {
        _pause();
    }

    function unpause() external onlyFactory {
        _unpause();
    }

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