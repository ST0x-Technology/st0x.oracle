// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IDIAOracleV2} from "../../interface/IDIAOracleV2.sol";
import {AggregatorV2V3Interface} from "../../interface/IAggregatorV2V3.sol";
import {LibCorporateActionsPause} from "../../lib/LibCorporateActionsPause.sol";
import {ICorporateActionsV1, ACTION_TYPE_INIT_V1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {IERC4626} from "@openzeppelin-contracts-5.6.1/interfaces/IERC4626.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";

/// @dev Error raised when a zero address is provided for the DIA feed.
error ZeroDIAOracle();

/// @dev Error raised when a zero address is provided for the vault.
error ZeroVault();

/// @dev Error raised when an empty symbol is provided. DIA keys feeds by
/// the bare symbol string (`"COIN"`, `"AMZN"`, ...) and an empty key is a
/// configuration error that would silently return zero.
error EmptySymbol();

/// @dev Error raised when a zero max age is provided. Zero would mean every
/// price read is instantly stale, which is never the desired configuration.
error ZeroMaxAge();

/// @dev Error raised when the priced vault's `asset()` (the tStock that
/// carries `ICorporateActionsV1`) is the zero address — a broken / non-ST0x
/// vault. The auto-pause is mandatory, and a zero corporate-actions vault
/// would silently disable it (serving prices straight across a NAV-rebalance
/// boundary), so it fails loud at init instead.
error ZeroCorporateActionsVault();

/// @dev Error raised when the corporate-action pause window is incoherent: a
/// non-zero `actionTypeMask` and at least one non-zero window are both
/// required, else the auto-pause never fires despite being "configured".
error InvalidPauseConfig();

/// @dev Error raised when `pauseTimeAfter < maxAge`. The post-action pause MUST
/// last at least as long as the DIA staleness window, otherwise a
/// stale-but-not-yet-`maxAge` pre-action DIA price can be served against the
/// already-rebalanced post-action vault ratio once the pause lifts — mispricing
/// collateral across a corporate-action boundary. See the contract NatSpec
/// ("Cross-epoch safety invariant") for the full argument.
/// @param pauseTimeAfter The configured post-action pause (seconds).
/// @param maxAge The configured DIA staleness window (seconds).
error PauseTimeAfterBelowMaxAge(uint256 pauseTimeAfter, uint256 maxAge);

/// @dev Error raised when the DIA feed has never been pushed (value or
/// timestamp == 0). Distinct from `DIAPriceStale` so integrators can
/// disambiguate "feed not yet active" from "feed active but late".
error DIAPriceNotSet();

/// @dev Error raised when the DIA reading is older than `maxAge` seconds.
/// @param timestamp The `block.timestamp` of the stale DIA push.
error DIAPriceStale(uint256 timestamp);

/// @dev Error raised on every read inside a corporate-action pause window.
/// @param effectiveTime The `effectiveTime` of the action whose window is
/// currently open. When a pending and a completed action's window overlap
/// `now`, the pending action's `effectiveTime` is reported — integrators see
/// the next event coming, not the last one done.
error OraclePausedCorporateAction(uint64 effectiveTime);

/// @dev Error raised when the vault has zero total supply (no shares minted).
/// Pricing one share of a zero-supply vault is undefined.
error ZeroVaultSupply();

/// @dev Error raised when the computed vault share price is zero. A zero
/// price is never a valid Chainlink-compatible answer.
error ZeroVaultSharePrice();

/// @dev Error raised when the vault holds zero assets at a checkpoint: a
/// zero ratio can never be a valid pricing anchor.
error ZeroVaultAssets();

/// @dev Error raised when the vault ratio has no valid anchor: either one was
/// never captured (vault empty or mid-pause at init and `checkpointRatio` not
/// yet called), or a corporate action has completed since the anchor was
/// taken. Serving stops (fails closed) until `checkpointRatio` re-anchors the
/// post-action ratio.
error VaultRatioNotAnchored();

/// @dev Error raised when the live vault ratio falls outside the drift band
/// around the anchored ratio. Signals an UNSCHEDULED NAV change — most
/// plausibly an erroneous direct transfer into the vault ("donation") — which
/// must be reviewed before prices are served again. See the contract NatSpec
/// ("Vault trust model") for the recovery paths.
/// @param currentRatio The live `totalAssets/totalSupply` ratio (Rain float).
/// @param anchorRatio The anchored ratio the band is centred on (Rain float).
error VaultRatioOutOfBand(Float currentRatio, Float anchorRatio);

/// @dev Error raised when the vault share price overflows int256.
/// @param price8 The unsigned 8-decimal share price that wouldn't fit.
error VaultSharePriceOverflow(uint256 price8);

/// @dev Error raised when a caller requests historical round data. DIA
/// exposes only the latest push, so there is no per-round history here.
/// Callers needing historical data should query DIA's off-chain feed
/// history or an indexer of DIA pushes directly.
/// @param roundId The unsupported round id that was requested.
error HistoricalRoundDataUnsupported(uint80 roundId);

/// @title DIAVaultOracleConfig
/// @notice Configuration for `DIAVaultOracle.initialize`.
/// @param diaOracle The DIA Data Association V2 oracle contract holding the
/// underlying asset price.
/// @param symbol The DIA feed key (bare symbol, e.g. `"COIN"`). DIA keys
/// feeds by the bare symbol, not the pair string.
/// @param vault The ERC-4626 vault address whose shares we're pricing.
/// `vault.totalAssets() / vault.totalSupply()` is the share-to-asset ratio
/// applied on top of the DIA price. For a wtStock-style wrapper this
/// captures the post-corporate-action NAV bump. NOTE the wtStock wrapper's
/// `totalAssets()` is raw `balanceOf` (donation-movable BY DESIGN — NAV bumps
/// arrive as transfers); the ratio drift band below is what gates it. See the
/// contract NatSpec ("Vault trust model").
/// @param maxAge Maximum acceptable DIA push age in seconds.
/// `block.timestamp - timestamp >= maxAge` reverts `DIAPriceStale` (the edge
/// instant fails closed — a push exactly `maxAge` old is stale). Immutable
/// after init — redeploy a fresh proxy to change. MUST be `<= pauseTimeAfter`
/// (see `pauseTimeAfter`).
/// @param actionTypeMask Bitmap of action types that trigger the auto-pause.
/// `ACTION_TYPE_STOCK_SPLIT_V1` for splits only, or `type(uint256).max` for
/// every present and future action type. Must be non-zero.
/// @param pauseTimeBefore Seconds before a pending action's `effectiveTime` to
/// start pausing.
/// @param pauseTimeAfter Seconds after a completed action's `effectiveTime` to
/// keep pausing. At least one of before/after must be non-zero, AND
/// `pauseTimeAfter >= maxAge` is REQUIRED and enforced at init
/// (`PauseTimeAfterBelowMaxAge`) — the post-action pause must outlast the DIA
/// staleness window so a pre-action price can never be served against the
/// post-action ratio. The exact-equality boundary (`pauseTimeAfter == maxAge`)
/// is safe: the staleness check rejects the `maxAge` edge, so at pause-lift the
/// oldest still-acceptable push is strictly newer than `effectiveTime`. A
/// margin above `maxAge` is still recommended as defence-in-depth.
/// @param maxRatioDriftPerDayBps Width of the vault-ratio sanity band in
/// basis points per day, accrued linearly since the last anchor. Between
/// corporate actions the live `totalAssets/totalSupply` ratio must stay
/// within `anchorRatio * (1 ± drift)` where
/// `drift = maxRatioDriftPerDayBps * elapsed / 1 days / 10000`; a read
/// outside the band reverts `VaultRatioOutOfBand` (fails closed). Zero is a
/// valid (strictest) setting — the ratio may then only move via completed
/// corporate actions — but a small non-zero value is recommended to absorb
/// deposit/withdraw rounding dust. See `checkpointRatio`.
/// @dev The corporate-actions vault is NOT a config field: it is derived as
/// `IERC4626(vault).asset()` — the tStock the wtStock wraps, which is the
/// contract that implements `ICorporateActionsV1`. Deriving it removes a
/// mis-wiring surface (you can't point the auto-pause at the wrong token).
struct DIAVaultOracleConfig {
    IDIAOracleV2 diaOracle;
    string symbol;
    address vault;
    uint256 maxAge;
    uint256 actionTypeMask;
    uint64 pauseTimeBefore;
    uint64 pauseTimeAfter;
    uint32 maxRatioDriftPerDayBps;
}

/// @title DIAVaultOracle
/// @notice Prices ERC-4626 (`wtStock`) vault shares by reading the underlying
/// equity price from a DIA Data Association feed and multiplying by the
/// vault's assets-per-share ratio, and auto-pauses reads around scheduled
/// corporate actions. Exposes prices via Chainlink's `AggregatorV2V3Interface`
/// so consumers (Euler, Aave-style lending protocols) can target the same
/// surface they already use for Chainlink feeds.
///
/// Math: `vaultSharePrice = diaPrice * totalAssets / totalSupply` scaled to 8
/// decimals — i.e. the equity's USD price times `convertToAssets(1 share)`, so
/// the price tracks any NAV change inside the vault (most importantly the
/// post-split rebalance in the underlying `tStock`). Performed in Rain float
/// space throughout so neither operand can overflow uint256; the conversion to
/// fixed-point 8dp happens only at the final return.
///
/// Vault trust model (donations & the ratio band): the priced `vault` is a
/// `wtStock` wrapper whose `totalAssets()` IS raw
/// `IERC20(asset()).balanceOf(vault)` (the OZ ERC-4626 default). Direct
/// transfers into the vault ("donations") therefore DO move the share ratio —
/// by design: NAV bumps (dividend reinvestment, post-action rebalances) are
/// delivered as exactly such transfers. The classic ERC-4626
/// donation-inflation surface is real here and is gated by defence in depth,
/// not by an accounted ledger:
///
/// 1. tStock transfers are authorizer-gated upstream. There is no
///    permissionless donation path; only authorised holders (APs, MMs, KYC'd
///    users) can move tStock at all, so inflating the ratio requires an
///    authorised (or erroneous) transfer, not an anonymous attacker.
/// 2. Every scheduled NAV event is a corporate action on the tStock
///    (`ICorporateActionsV1`, e.g. splits and stables dividends): reads pause
///    around its `effectiveTime`, and a completed action stops price serving
///    (`VaultRatioNotAnchored`) until `checkpointRatio` re-anchors the
///    post-action ratio.
/// 3. Between actions the live ratio is gated by a drift band around the last
///    anchor (`maxRatioDriftPerDayBps`, linearly accrued). An unscheduled
///    ratio move beyond the band — most plausibly an erroneous direct
///    transfer — makes every read revert `VaultRatioOutOfBand` (fail closed)
///    until the cause is reviewed; if the new NAV is confirmed real, ops
///    re-anchor via a corporate action (or redeploy for pathological cases).
///
/// Residual risk (documented, accepted): between a completed action and its
/// re-anchoring `checkpointRatio` call the band is suspended, so a donation
/// landed in that window is baked into the new anchor. The window is
/// ops-bounded (checkpoint immediately after the pause lifts) and the
/// donation surface is authorizer-gated, so it is not permissionlessly
/// reachable. Arbitrary third-party ERC-4626 vaults remain OUTSIDE the trust
/// model: nothing here defends a vault whose transfer path is permissionless.
/// See `_vaultSharePrice` and `checkpointRatio` for the mechanics.
///
/// Auto-pause: on every read the oracle consults `ICorporateActionsV1` on the
/// corporate-actions vault — derived as the priced vault's `asset()`, i.e. the
/// tStock the wtStock wraps — via `LibCorporateActionsPause`, and reverts
/// `OraclePausedCorporateAction` inside the pre/post window of any matching
/// scheduled or completed action, so lending markets can't borrow or liquidate
/// against a stale-by-construction share price mid-rebalance. The auto-pause is
/// MANDATORY — every ST0x token implements corporate actions, so there is no
/// disabled path and no separate wrapper. There is no manual pause and no
/// admin: config is immutable, set once at initialize; to change anything,
/// deploy a fresh proxy and migrate consumers.
///
/// Cross-epoch safety invariant (`pauseTimeAfter >= maxAge`, enforced at init):
/// the share price multiplies a DIA equity price by the vault's LIVE
/// `totalAssets/totalSupply` ratio. Those two inputs must belong to the same
/// corporate-action epoch. When an action completes, the vault ratio rebalances
/// atomically, but DIA keeps serving the pre-action equity price until its next
/// push — up to `maxAge` seconds. The post-window pause is the only barrier
/// between the two epochs. If `pauseTimeAfter < maxAge` the pause lifts while a
/// pre-action DIA price is still within `maxAge` (hence accepted by the
/// staleness check), and that stale price pairs with the already-rebalanced
/// ratio: on a 2:1 split the share is valued at ~2x, letting a borrower draw
/// against phantom collateral (bad debt). Requiring `pauseTimeAfter >= maxAge`
/// makes the oldest still-acceptable push at pause-lift STRICTLY NEWER than the
/// action's `effectiveTime`: the staleness check rejects the exact-`maxAge`
/// edge (`age >= maxAge` is stale), so at the pause-lift instant
/// `t = effectiveTime + pauseTimeAfter` any served push is timestamped
/// `> t - maxAge >= effectiveTime`. The equal boundary (`pauseTimeAfter ==
/// maxAge`) is therefore airtight — no same-instant ambiguity — so only
/// same-epoch (post-action) prices are ever served. The staleness check alone
/// is NOT sufficient — it bounds age, not epoch; the invariant plus the
/// edge-rejecting staleness together are what close the window.
///
/// Deployed as a beacon-proxy clone via `ICloneableV2.initialize`.
contract DIAVaultOracle is AggregatorV2V3Interface, ICloneableV2, Initializable {
    /// @custom:storage-location erc7201:st0x.diavaultoracle.main
    struct MainStorage {
        // The DIA Data Association V2 oracle feed for the underlying asset.
        IDIAOracleV2 diaOracle;
        // The DIA feed key (bare symbol, e.g. `"COIN"`).
        string symbol;
        // The ERC-4626 vault this oracle prices shares for.
        address vault;
        // Maximum acceptable DIA push age in seconds.
        uint256 maxAge;
        // The ICorporateActionsV1 vault gating the auto-pause.
        address corporateActionsVault;
        // Bitmap of action types that trigger the auto-pause.
        uint256 actionTypeMask;
        // Seconds before a pending action's effectiveTime to start pausing.
        uint64 pauseTimeBefore;
        // Seconds after a completed action's effectiveTime to keep pausing.
        uint64 pauseTimeAfter;
        // Width of the vault-ratio sanity band in bps/day (see config NatSpec).
        uint32 maxRatioDriftPerDayBps;
        // The anchored vault ratio the drift band is centred on (Rain float).
        Float anchorRatio;
        // Timestamp the anchor was taken at; 0 = no valid anchor (fail closed).
        uint64 anchorTime;
        // `completedActionCount()` on the corporate-actions vault at anchor
        // time. Any increase invalidates the anchor until re-checkpointed.
        uint256 anchorCompletedActionCount;
    }

    // keccak256(abi.encode(uint256(keccak256("st0x.diavaultoracle.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MAIN_STORAGE_LOCATION = 0xa6b686aa52190f2ecc306934b0149933ff4f6d9fe65f143c543f7c981a9b1200;

    function _main() private pure returns (MainStorage storage $) {
        assembly ("memory-safe") {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    /// @notice Emitted when the oracle is initialized. Single source of
    /// truth for off-chain indexers — all immutable config in one event.
    /// @param sender The caller that initialized the proxy.
    /// @param config The initialization configuration.
    event DIAVaultOracleInitialized(address indexed sender, DIAVaultOracleConfig config);

    /// @notice Emitted when the vault-ratio anchor moves — at initialize (if
    /// the vault is already seeded) and on every successful `checkpointRatio`.
    /// @param sender The caller that moved the anchor.
    /// @param ratio The newly anchored ratio (Rain float).
    /// @param completedActionCount The corporate-actions completed count the
    /// anchor is valid for.
    event VaultRatioCheckpointed(address indexed sender, Float ratio, uint256 completedActionCount);

    constructor() {
        _disableInitializers();
    }

    /// @notice The DIA Data Association V2 oracle feed for the underlying asset.
    function diaOracle() public view returns (IDIAOracleV2) {
        return _main().diaOracle;
    }

    /// @notice The DIA feed key (bare symbol, e.g. `"COIN"`).
    function symbol() public view returns (string memory) {
        return _main().symbol;
    }

    /// @notice The ERC-4626 vault this oracle prices shares for.
    function vault() public view returns (address) {
        return _main().vault;
    }

    /// @notice Maximum acceptable DIA push age in seconds.
    function maxAge() public view returns (uint256) {
        return _main().maxAge;
    }

    /// @notice The `ICorporateActionsV1` vault gating the auto-pause.
    function corporateActionsVault() public view returns (address) {
        return _main().corporateActionsVault;
    }

    /// @notice Bitmap of action types that trigger the auto-pause.
    function actionTypeMask() public view returns (uint256) {
        return _main().actionTypeMask;
    }

    /// @notice Seconds before a pending action's `effectiveTime` to pause.
    function pauseTimeBefore() public view returns (uint64) {
        return _main().pauseTimeBefore;
    }

    /// @notice Seconds after a completed action's `effectiveTime` to pause.
    function pauseTimeAfter() public view returns (uint64) {
        return _main().pauseTimeAfter;
    }

    /// @notice Width of the vault-ratio sanity band in bps/day.
    function maxRatioDriftPerDayBps() public view returns (uint32) {
        return _main().maxRatioDriftPerDayBps;
    }

    /// @notice The anchored vault ratio the drift band is centred on.
    function anchorRatio() public view returns (Float) {
        return _main().anchorRatio;
    }

    /// @notice Timestamp of the current anchor; 0 = no valid anchor.
    function anchorTime() public view returns (uint64) {
        return _main().anchorTime;
    }

    /// @notice `completedActionCount()` on the corporate-actions vault when
    /// the anchor was taken.
    function anchorCompletedActionCount() public view returns (uint256) {
        return _main().anchorCompletedActionCount;
    }

    /// @notice Documents the typed signature of the initialize function. Per
    /// `ICloneableV2` this overload MUST always revert; callers use the
    /// `bytes calldata` overload below.
    /// @dev Always reverts with `InitializeSignatureFn`.
    /// @param config The initialization configuration. Ignored.
    /// @return Never returns; included only for the function signature.
    function initialize(DIAVaultOracleConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        DIAVaultOracleConfig memory config = abi.decode(data, (DIAVaultOracleConfig));

        if (address(config.diaOracle) == address(0)) revert ZeroDIAOracle();
        if (bytes(config.symbol).length == 0) revert EmptySymbol();
        if (config.vault == address(0)) revert ZeroVault();
        if (config.maxAge == 0) revert ZeroMaxAge();

        // The corporate-actions vault is the tStock the wtStock wraps — the
        // priced vault's own `asset()`. Deriving it (rather than taking a
        // separate config field) removes a mis-wiring surface.
        address derivedCorporateActionsVault = IERC4626(config.vault).asset();
        if (derivedCorporateActionsVault == address(0)) revert ZeroCorporateActionsVault();

        // Auto-pause is mandatory and must be coherently configured. The mask
        // must retain a real action bit AFTER the library strips
        // `ACTION_TYPE_INIT_V1` (the bootstrap node is not a real action) — a
        // mask of exactly `ACTION_TYPE_INIT_V1` would pass a bare `!= 0` check
        // yet the library short-circuits it to "never pauses", silently
        // defeating the mandatory auto-pause.
        if (
            (config.actionTypeMask & ~ACTION_TYPE_INIT_V1) == 0
                || (config.pauseTimeBefore == 0 && config.pauseTimeAfter == 0)
        ) {
            revert InvalidPauseConfig();
        }

        // Cross-epoch safety invariant: the post-action pause must outlast the
        // DIA staleness window. The vault's NAV ratio rebalances the instant a
        // corporate action completes, but DIA may still serve the pre-action
        // equity price for up to `maxAge` seconds afterwards. The pause is the
        // only thing separating those two epochs; if it lifts while a pre-action
        // price is still "fresh" (`pauseTimeAfter < maxAge`), that price pairs
        // with the post-action ratio and misprices the share (e.g. ~2x on a 2:1
        // split → over-borrow → bad debt). `pauseTimeAfter >= maxAge` guarantees
        // that once the pause lifts, the oldest still-acceptable DIA push was
        // timestamped at or after the action's `effectiveTime`. See the
        // contract NatSpec for the full argument.
        if (config.pauseTimeAfter < config.maxAge) {
            revert PauseTimeAfterBelowMaxAge(config.pauseTimeAfter, config.maxAge);
        }

        // Probe the corporate-actions vault once so an incompatible wiring — a
        // missing facet (ABI-decode revert) or a mask with no bits in the
        // upstream VALID_ACTION_TYPES_MASK (InvalidMask) — reverts THIS deploy
        // transaction rather than every future consumer read against immutable
        // config. The pause flag is reused below to decide whether the ratio
        // anchor may be captured at init.
        // The window's `effectiveTime` is deliberately unused at init — only
        // the pause flag gates the anchor capture below.
        // slither-disable-next-line unused-return
        (bool pausedAtInit,) = LibCorporateActionsPause.inPauseWindow(
            derivedCorporateActionsVault, config.actionTypeMask, config.pauseTimeBefore, config.pauseTimeAfter
        );

        MainStorage storage $ = _main();
        $.diaOracle = config.diaOracle;
        $.symbol = config.symbol;
        $.vault = config.vault;
        $.maxAge = config.maxAge;
        $.corporateActionsVault = derivedCorporateActionsVault;
        $.actionTypeMask = config.actionTypeMask;
        $.pauseTimeBefore = config.pauseTimeBefore;
        $.pauseTimeAfter = config.pauseTimeAfter;
        $.maxRatioDriftPerDayBps = config.maxRatioDriftPerDayBps;

        emit DIAVaultOracleInitialized(msg.sender, config);

        // Capture the ratio anchor now if the vault is already seeded and no
        // pause window is open (a mid-pause ratio may be transitional). An
        // unseeded or mid-pause deploy leaves the anchor unset: reads fail
        // closed (`VaultRatioNotAnchored`) until `checkpointRatio` is called.
        uint256 initTotalAssets = IERC4626(config.vault).totalAssets();
        uint256 initTotalSupply = IERC4626(config.vault).totalSupply();
        if (!pausedAtInit && initTotalAssets != 0 && initTotalSupply != 0) {
            Float initRatio = LibDecimalFloat.div(
                LibDecimalFloat.fromFixedDecimalLosslessPacked(initTotalAssets, 0),
                LibDecimalFloat.fromFixedDecimalLosslessPacked(initTotalSupply, 0)
            );
            uint256 completed = ICorporateActionsV1(derivedCorporateActionsVault).completedActionCount();
            $.anchorRatio = initRatio;
            $.anchorTime = uint64(block.timestamp);
            $.anchorCompletedActionCount = completed;
            emit VaultRatioCheckpointed(msg.sender, initRatio, completed);
        }

        return ICLONEABLE_V2_SUCCESS;
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev Deliberate deviation from the Chainlink-style pair-string
    /// convention: this returns the BARE DIA feed symbol (e.g. `"COIN"`), NOT
    /// a `"SYMBOL / USD"` pair string, because DIA keys its feeds by the bare
    /// symbol and that is the single source of truth here. Integrators that
    /// expect a Chainlink-formatted pair string must adjust. The interface
    /// NatSpec is worded so it does not contradict this.
    function description() external view override returns (string memory) {
        return _main().symbol;
    }

    /// @inheritdoc AggregatorV2V3Interface
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc AggregatorV2V3Interface
    function version() external pure override returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV2V3Interface
    function latestAnswer() external view override returns (int256) {
        _validateNotPaused();
        (uint128 diaPrice,) = _readDIAChecked();
        return _vaultSharePrice(diaPrice);
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev `roundId` and `answeredInRound` are derived from the DIA push
    /// `timestamp` (truncated to `uint80`) so they advance monotonically per
    /// Chainlink convention without adding storage. Integrators that diff
    /// `roundId` between calls to detect a fresh update will see a different
    /// value whenever DIA has produced a new push. The `uint80` window
    /// covers every plausible deployment lifetime.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _validateNotPaused();
        (uint128 diaPrice, uint128 timestamp) = _readDIAChecked();
        int256 scaledPrice = _vaultSharePrice(diaPrice);

        uint80 round = uint80(timestamp);
        return (round, scaledPrice, timestamp, timestamp, round);
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev DIA exposes only its latest value — no per-round history through
    /// this interface. Every call reverts with
    /// `HistoricalRoundDataUnsupported(_roundId)`. Callers needing
    /// point-in-time data should query DIA's off-chain feed history or an
    /// indexer of DIA pushes directly.
    function getRoundData(uint80 _roundId) external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert HistoricalRoundDataUnsupported(_roundId);
    }

    /// @dev Reverts `OraclePausedCorporateAction` if the current block is
    /// inside the pre/post window of any matching scheduled or completed
    /// action on the configured corporate-actions vault.
    function _validateNotPaused() internal view {
        MainStorage storage $ = _main();
        (bool paused, uint64 effectiveTime) = LibCorporateActionsPause.inPauseWindow(
            $.corporateActionsVault, $.actionTypeMask, $.pauseTimeBefore, $.pauseTimeAfter
        );
        if (paused) revert OraclePausedCorporateAction(effectiveTime);
    }

    /// @dev Read DIA and revert on either "never pushed" (DIAPriceNotSet) or
    /// "too old" (DIAPriceStale). DIA's `getValue` returns `(0, 0)` for an
    /// unset feed rather than reverting — we must check explicitly.
    function _readDIAChecked() internal view returns (uint128 value, uint128 timestamp) {
        MainStorage storage $ = _main();
        (value, timestamp) = $.diaOracle.getValue($.symbol);
        if (value == 0 || timestamp == 0) revert DIAPriceNotSet();
        // Comparing block.timestamp against the DIA push timestamp is the whole
        // point of the staleness check; sub-maxAge miner drift is immaterial
        // against a maxAge measured in hours. This is not a false-positive
        // dependence on block.timestamp for value/authorisation.
        //
        // A push timestamped at or before `now` applies the `maxAge` window. A
        // push timestamped in the FUTURE (a feed running slightly ahead, or a
        // chain-time regression / reorg) is treated as fresh (age 0), never
        // stale: the `<= block.timestamp` guard short-circuits the subtraction
        // so it can never underflow into a bare `Panic(0x11)` that integrators
        // cannot disambiguate from `DIAPriceStale` / `DIAPriceNotSet`.
        //
        // The staleness edge fails closed (`>=`): a push exactly `maxAge` old is
        // STALE. This is deliberate — it makes the cross-epoch invariant
        // (`pauseTimeAfter >= maxAge`, see the contract NatSpec) airtight at the
        // exact-equality boundary, and matches the fail-closed staleness
        // convention (the edge counts as stale).
        // slither-disable-next-line timestamp
        if (uint256(timestamp) <= block.timestamp && block.timestamp - uint256(timestamp) >= $.maxAge) {
            revert DIAPriceStale(uint256(timestamp));
        }
    }

    /// @notice Re-anchor the vault-ratio drift band on the live ratio.
    /// Permissionless: the band itself is what keeps the call safe.
    ///
    /// Two paths:
    /// - After a corporate action: once the pause window has lifted, the live
    ///   (post-action) ratio is accepted outright and the anchor moves to it —
    ///   this is the ONLY way serving resumes after
    ///   `completedActionCount()` advances (`VaultRatioNotAnchored`).
    /// - Between actions: the call must itself pass the same drift band that
    ///   gates reads, so an out-of-band donation cannot be laundered into a
    ///   new anchor; it re-bases the linear drift accrual at the current
    ///   ratio (useful housekeeping to keep the band tight).
    ///
    /// Reverts `OraclePausedCorporateAction` inside a pause window (a
    /// mid-pause ratio may be transitional), `ZeroVaultSupply` /
    /// `ZeroVaultAssets` on an unseeded vault, and `VaultRatioOutOfBand` when
    /// no action completed and the live ratio exceeds the accrued band.
    function checkpointRatio() external {
        _validateNotPaused();
        MainStorage storage $ = _main();
        IERC4626 vaultContract = IERC4626($.vault);
        uint256 totalAssets = vaultContract.totalAssets();
        uint256 totalSupply = vaultContract.totalSupply();
        if (totalSupply == 0) revert ZeroVaultSupply();
        if (totalAssets == 0) revert ZeroVaultAssets();

        Float ratio = LibDecimalFloat.div(
            LibDecimalFloat.fromFixedDecimalLosslessPacked(totalAssets, 0),
            LibDecimalFloat.fromFixedDecimalLosslessPacked(totalSupply, 0)
        );
        uint256 completed = ICorporateActionsV1($.corporateActionsVault).completedActionCount();

        // Between actions the anchor may only move within the band; across a
        // completed action (or from an unset anchor) the live ratio is
        // accepted outright — see the function NatSpec for why.
        if ($.anchorTime != 0 && completed == $.anchorCompletedActionCount) {
            _validateRatioInBand($, ratio);
        }

        $.anchorRatio = ratio;
        $.anchorTime = uint64(block.timestamp);
        $.anchorCompletedActionCount = completed;
        emit VaultRatioCheckpointed(msg.sender, ratio, completed);
    }

    /// @dev Validate the anchor is current (set, and no corporate action has
    /// completed since it was taken) then check `ratio` against the accrued
    /// drift band. Fails closed on every branch.
    function _validateRatioAnchored(MainStorage storage $, Float ratio) internal view {
        if ($.anchorTime == 0) revert VaultRatioNotAnchored();
        if (ICorporateActionsV1($.corporateActionsVault).completedActionCount() != $.anchorCompletedActionCount) {
            revert VaultRatioNotAnchored();
        }
        _validateRatioInBand($, ratio);
    }

    /// @dev Check `ratio` against `anchorRatio * (1 ± drift)` where
    /// `drift = maxRatioDriftPerDayBps * elapsed / 1 days / 10000`, all in
    /// Rain float space. The band is symmetric; once the accrued drift
    /// exceeds 1 the lower bound goes non-positive and only the upper bound
    /// binds (a ratio is always positive here).
    function _validateRatioInBand(MainStorage storage $, Float ratio) internal view {
        // anchorTime <= block.timestamp by construction (stored from
        // block.timestamp). uint32 bps * uint64 elapsed < 2^96 — no overflow.
        // Elapsed wall-clock time since the anchor is the whole point of a
        // linearly accrued drift allowance; sub-band miner drift is immaterial
        // against an allowance measured in bps/day. Not a value/authorisation
        // dependence on block.timestamp.
        // slither-disable-next-line timestamp
        uint256 elapsed = block.timestamp - $.anchorTime;
        Float drift = LibDecimalFloat.div(
            LibDecimalFloat.fromFixedDecimalLosslessPacked(uint256($.maxRatioDriftPerDayBps) * elapsed, 0),
            LibDecimalFloat.fromFixedDecimalLosslessPacked(10_000 * 1 days, 0)
        );
        Float one = LibDecimalFloat.packLossless(1, 0);
        Float anchor = $.anchorRatio;
        Float upper = LibDecimalFloat.mul(anchor, LibDecimalFloat.add(one, drift));
        Float lower = LibDecimalFloat.mul(anchor, LibDecimalFloat.sub(one, drift));
        // The band bounds derive from elapsed wall-clock time (see above) —
        // same justification, anchored where slither flags the comparison.
        // slither-disable-next-line timestamp
        if (LibDecimalFloat.gt(ratio, upper) || LibDecimalFloat.lt(ratio, lower)) {
            revert VaultRatioOutOfBand(ratio, anchor);
        }
    }

    /// @dev Compute vault share price from a DIA reading via Rain float math
    /// so neither operand can overflow uint256. DIA prices are 18-decimal
    /// `uint128`. The vault ratio is `totalAssets / totalSupply`. Output is
    /// 8-decimal `int256` per Chainlink `latestAnswer` convention.
    ///
    /// Donation / share-inflation trust model: this reads `totalAssets()`
    /// directly and feeds the resulting share price to lending markets, where
    /// an inflatable ratio lets a borrower draw against phantom collateral.
    /// The wtStock's `totalAssets()` IS raw `balanceOf` — donations move it by
    /// design (that is the NAV-bump delivery mechanism) — so the ratio is
    /// validated on every read against the anchored drift band
    /// (`_validateRatioAnchored`): an unscheduled out-of-band move reverts
    /// `VaultRatioOutOfBand`, and a ratio without a current anchor (none
    /// captured yet, or a corporate action completed since) reverts
    /// `VaultRatioNotAnchored`. See the contract NatSpec ("Vault trust
    /// model") for the full defence-in-depth argument and residual risk. The
    /// behaviour is pinned by the `testVaultRatioBand*` suite.
    function _vaultSharePrice(uint128 diaPrice) internal view returns (int256) {
        // DIA's value is 18-decimal uint128 — pack as a float with decimal
        // count 18 to recover the natural quantity.
        Float priceFloat = LibDecimalFloat.fromFixedDecimalLosslessPacked(uint256(diaPrice), 18);

        MainStorage storage $ = _main();
        IERC4626 vaultContract = IERC4626($.vault);
        uint256 totalAssets = vaultContract.totalAssets();
        uint256 totalSupply = vaultContract.totalSupply();

        if (totalSupply == 0) revert ZeroVaultSupply();

        Float assetsFloat = LibDecimalFloat.fromFixedDecimalLosslessPacked(totalAssets, 0);
        Float supplyFloat = LibDecimalFloat.fromFixedDecimalLosslessPacked(totalSupply, 0);
        Float ratioFloat = LibDecimalFloat.div(assetsFloat, supplyFloat);

        _validateRatioAnchored($, ratioFloat);

        // Rain float division is not integer division: dividing first loses no
        // precision to truncation the way uint division would, and the ratio
        // must exist as its own value for the band validation above.
        // slither-disable-next-line divide-before-multiply
        Float vaultSharePriceFloat = LibDecimalFloat.mul(priceFloat, ratioFloat);

        // The second return (bool lossy) is intentionally ignored — lossy
        // conversion is expected and acceptable when scaling to 8 decimals.
        // slither-disable-next-line unused-return
        (uint256 price8,) = LibDecimalFloat.toFixedDecimalLossy(vaultSharePriceFloat, 8);

        if (price8 == 0) revert ZeroVaultSharePrice();
        if (price8 > uint256(type(int256).max)) revert VaultSharePriceOverflow(price8);

        return int256(price8);
    }
}
