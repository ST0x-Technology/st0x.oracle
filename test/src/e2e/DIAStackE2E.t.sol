// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {IDIAOracleV2} from "../../../src/interface/IDIAOracleV2.sol";
import {
    DIAVaultOracle,
    DIAVaultOracleConfig,
    VaultRatioNotAnchored,
    DIAPriceNotSet,
    DIAPriceStale,
    OraclePausedCorporateAction
} from "../../../src/concrete/oracle/DIAVaultOracle.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig
} from "../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {MockDIAOracle} from "../../mocks/MockDIAOracle.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockCorporateActions} from "../../mocks/MockCorporateActions.sol";
import {NODE_NONE} from "st0x-deploy-0.1.1/src/lib/LibCorporateActionNode.sol";

/// @title DIAStackE2ETest
/// @notice End-to-end happy-path + auto-pause exercise of the production deploy
/// graph for the DIA oracle. Mints a `DIAVaultOracle` proxy through its
/// beacon-set deployer (the real production path) and drives scenarios through
/// the oracle's `AggregatorV2V3Interface` surface — the same surface consumers
/// target. Complements the per-component unit tests by proving the full graph
/// wires up and behaves as a coherent whole, including the folded-in
/// corporate-action auto-pause.
contract DIAStackE2ETest is Test {
    MockDIAOracle internal diaOracle;
    MockERC4626 internal vault;
    MockCorporateActions internal corporateActions;
    DIAVaultOracle internal oracle;

    string internal constant SYMBOL = "COIN";
    uint256 internal constant MAX_AGE = 2 hours;
    uint64 internal constant PAUSE_BEFORE = 1 hours;
    // Cross-epoch invariant: pauseTimeAfter >= maxAge.
    uint64 internal constant PAUSE_AFTER = 2 hours;
    uint32 constant DRIFT_BPS_PER_DAY = 100;

    function setUp() public {
        diaOracle = new MockDIAOracle();
        vault = new MockERC4626();
        corporateActions = new MockCorporateActions();
        // The oracle derives its corporate-actions vault from vault.asset()
        // (the tStock the wtStock wraps).
        vault.setAsset(address(corporateActions));
        // Seed the vault 1:1 before the oracle deploys so `initialize`
        // captures the ratio anchor for the drift band.
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        DIAVaultOracleBeaconSetDeployer oracleBSD = new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: address(this), initialDIAVaultOracleImplementation: address(new DIAVaultOracle())
            })
        );

        // Warp far enough in that `block.timestamp - maxAge` and the pre/post
        // pause windows can be exercised without underflow.
        vm.warp(1_000_000);

        oracle = oracleBSD.newDIAVaultOracle(
            DIAVaultOracleConfig({
                diaOracle: IDIAOracleV2(address(diaOracle)),
                symbol: SYMBOL,
                vault: address(vault),
                maxAge: MAX_AGE,
                actionTypeMask: type(uint256).max,
                pauseTimeBefore: PAUSE_BEFORE,
                pauseTimeAfter: PAUSE_AFTER,
                maxRatioDriftPerDayBps: DRIFT_BPS_PER_DAY
            })
        );
    }

    /// @dev Scripts DIA to a fresh $100 reading at the current block.
    function _freshDIAAt100() internal {
        diaOracle.setValue(SYMBOL, 100e18, uint128(block.timestamp));
    }

    /// @dev Vault with 1:1 assets-per-share — `latestAnswer` mirrors the
    /// DIA price scaled to 8 decimals.
    function _flatVault() internal {
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
    }

    // -------- Scenario 1: happy path single price read --------

    function testHappyPathSinglePriceRead() external {
        _freshDIAAt100();
        _flatVault();

        assertEq(oracle.latestAnswer(), int256(100e8), "latestAnswer");
        assertEq(oracle.decimals(), uint8(8), "decimals");
        assertEq(oracle.description(), SYMBOL, "description is the DIA symbol");
        assertEq(oracle.version(), uint256(1), "version");
    }

    // -------- Scenario 2: wtStock NAV bump propagates --------

    function testWtStockNavBumpPropagates() external {
        _freshDIAAt100();
        _flatVault();

        // Baseline read: $100 underlying * 1.0 assets-per-share = $100.
        assertEq(oracle.latestAnswer(), int256(100e8), "pre-bump");

        // wtStock NAV doubles — same shares now claim 2× the underlying. The
        // vault's `totalAssets` doubles while `totalSupply` stays put. On the
        // real stack a bump of this size is delivered by a corporate action,
        // so the completed count advances; the drift band fails reads closed
        // until `checkpointRatio` re-anchors on the post-action ratio.
        vault.setTotalAssets(2e18);
        corporateActions.setCompletedActionCount(1);

        vm.expectRevert(abi.encodeWithSelector(VaultRatioNotAnchored.selector));
        oracle.latestAnswer();

        oracle.checkpointRatio();
        assertEq(oracle.latestAnswer(), int256(200e8), "post-bump");
    }

    // -------- Scenario 3: DIA timestamp appears in roundData --------

    function testDIATimestampAppearsInRoundData() external {
        uint256 t = 2_000_000;
        vm.warp(t);
        uint128 diaTs = uint128(t - 100);
        diaOracle.setValue(SYMBOL, 100e18, diaTs);
        _flatVault();

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(roundId, uint80(diaTs), "roundId == timestamp");
        assertEq(answer, int256(100e8), "answer");
        assertEq(startedAt, uint256(diaTs), "startedAt == timestamp");
        assertEq(updatedAt, uint256(diaTs), "updatedAt == timestamp");
        assertEq(answeredInRound, uint80(diaTs), "answeredInRound == timestamp");
    }

    // -------- Scenario 4: corporate-action auto-pause full lifecycle --------

    function testCorporateActionAutoPauseFullLifecycle() external {
        _freshDIAAt100();
        _flatVault();

        // No scheduled action — reads work cleanly.
        assertEq(oracle.latestAnswer(), int256(100e8), "pre-schedule reads");

        // Schedule a pending action 30 minutes out. Pre-window is 1 hour, so
        // we're squarely inside it.
        uint64 effectiveTime = uint64(block.timestamp + 30 minutes);
        corporateActions.setEarliestPending(1, type(uint256).max, effectiveTime);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();

        // Warp past `effectiveTime` but stay inside the post-window;
        // transition the mock from pending to completed as the real vault would.
        vm.warp(uint256(effectiveTime) + 15 minutes);
        _freshDIAAt100();
        corporateActions.setEarliestPending(NODE_NONE, 0, 0);
        corporateActions.setLatestCompleted(1, type(uint256).max, effectiveTime);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();

        // Warp past the post-window. The completed action advanced the
        // count, so reads stay failed-closed until the ratio is re-anchored —
        // the post-action checkpoint is part of the real lifecycle.
        vm.warp(uint256(effectiveTime) + uint256(PAUSE_AFTER) + 1);
        _freshDIAAt100();
        corporateActions.setCompletedActionCount(1);
        vm.expectRevert(abi.encodeWithSelector(VaultRatioNotAnchored.selector));
        oracle.latestAnswer();

        oracle.checkpointRatio();
        assertEq(oracle.latestAnswer(), int256(100e8), "post-window reads restored");
    }

    // -------- Scenario 5a: DIA never pushed propagates --------

    function testDIAPriceNotSetPropagates() external {
        _flatVault();

        // DIA was never poked for SYMBOL — the mock returns (0, 0) and the
        // never-pushed check fires.
        vm.expectRevert(DIAPriceNotSet.selector);
        oracle.latestAnswer();
    }

    // -------- Scenario 5b: stale DIA propagates --------

    function testStaleDIAPropagatesToCaller() external {
        _flatVault();

        uint128 staleTimestamp = uint128(block.timestamp - MAX_AGE - 1);
        diaOracle.setValue(SYMBOL, 100e18, staleTimestamp);

        vm.expectRevert(abi.encodeWithSelector(DIAPriceStale.selector, uint256(staleTimestamp)));
        oracle.latestAnswer();
    }
}
