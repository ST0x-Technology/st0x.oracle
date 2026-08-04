// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, console2} from "forge-std-1.16.1/src/Test.sol";
import {IDIAOracleV2} from "../../../src/interface/IDIAOracleV2.sol";
import {
    DIAVaultOracle,
    DIAVaultOracleConfig,
    OraclePausedCorporateAction
} from "../../../src/concrete/oracle/DIAVaultOracle.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig
} from "../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {ICorporateActionsV1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {STOCK_SPLIT_V1_TYPE_HASH} from "st0x-deploy-0.1.1/src/lib/LibCorporateAction.sol";
import {LibStockSplit} from "st0x-deploy-0.1.1/src/lib/LibStockSplit.sol";
import {LibDecimalFloat} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {IAuthorizeV1} from "rain-vats-0.1.5/src/interface/IAuthorizeV1.sol";
import {LibProdTokensBase} from "st0x-deploy-0.1.1/src/lib/LibProdTokensBase.sol";
import {DIA_FEED_BASE} from "../../../src/lib/LibDIAFeed.sol";

/// @dev The `authorizer()` getter of the live receipt vault — enough surface to
/// mock its permission gate without pulling the whole vault interface.
interface IAuthorizable {
    function authorizer() external view returns (address);
}

/// @title DIAVaultOracleForkBaseTest
/// @notice Fork test against LIVE Base contracts proving the oracle really
/// auto-pauses off the REAL corporate-actions vault (not a mock): it schedules
/// an actual stock split on the deployed tCOIN receipt vault and asserts the
/// oracle — pointed at the wtCOIN wrapper — reverts `OraclePausedCorporateAction`.
///
/// Forks Base from `BASE_RPC_URL`. The dedicated `fork-tests.yaml` workflow
/// wires this from the `RPC_URL_BASE_FORK` repo secret and runs it for real in
/// CI. The per-push rainix job doesn't inject that RPC (it's a cross-org
/// reusable workflow), so when `BASE_RPC_URL` is unset this loudly logs and
/// returns rather than erroring — `no-ignored-tests` bans `vm.skip`, and a hard
/// `createSelectFork` failure would red every per-push run. Locally, export
/// `BASE_RPC_URL=https://mainnet.base.org` to run it.
contract DIAVaultOracleForkBaseTest is Test {
    // Live Base deployments. Token vaults are imported from the pinned
    // st0x-deploy `LibProdTokensBase` so an st0x-deploy version bump that
    // redeploys the COIN pair propagates here automatically instead of leaving
    // stale literals; DIA_FEED comes from the single repo-level constant.
    address constant DIA_FEED = DIA_FEED_BASE;
    address constant WTCOIN = LibProdTokensBase.COIN_WRAPPED_TOKEN_VAULT; // StoxWrappedTokenVault (priced)
    address constant TCOIN = LibProdTokensBase.COIN_RECEIPT_VAULT; // receipt vault, ICorporateActionsV1

    uint64 constant PAUSE_BEFORE = 1 hours;
    // Satisfies the cross-epoch invariant `pauseTimeAfter >= maxAge`. The DIA
    // feed is mocked to a fresh value for the pre-schedule read (see
    // `_seedFreshDIA`), so `maxAge` no longer depends on how recently the LIVE
    // DIA `COIN` feed was pushed at the fork block — the fork test's real
    // subject is the corporate-action vault, not DIA.
    uint256 constant MAX_AGE = 1 hours;
    uint64 constant PAUSE_AFTER = 1 hours;

    function _deployOracle() internal returns (DIAVaultOracle) {
        DIAVaultOracleBeaconSetDeployer bsd = new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: address(this), initialDIAVaultOracleImplementation: address(new DIAVaultOracle())
            })
        );
        return bsd.newDIAVaultOracle(
            DIAVaultOracleConfig({
                diaOracle: IDIAOracleV2(DIA_FEED),
                symbol: "COIN",
                vault: WTCOIN,
                maxAge: MAX_AGE,
                actionTypeMask: type(uint256).max,
                pauseTimeBefore: PAUSE_BEFORE,
                pauseTimeAfter: PAUSE_AFTER
            })
        );
    }

    /// @dev Permit any scheduling call on the live vault by mocking ONLY its
    /// authorizer's permission gate — the real facet's schedule + traversal
    /// (what the oracle reads) still run for real.
    function _permitScheduling() internal {
        address authorizer = IAuthorizable(TCOIN).authorizer();
        vm.mockCall(authorizer, abi.encodeWithSelector(IAuthorizeV1.authorize.selector), "");
    }

    /// @dev Mock the DIA feed to a fresh (age-0) COIN value so the pre-schedule
    /// read is deterministic regardless of how stale the LIVE feed is at the
    /// fork block. DIA is not what this fork test validates — the real
    /// corporate-action vault and its pause traversal are — so mocking the price
    /// source removes a live-feed-freshness CI dependency without weakening the
    /// pause assertions (the pause gate reverts before the DIA read anyway).
    function _seedFreshDIA() internal {
        vm.mockCall(
            DIA_FEED,
            abi.encodeWithSelector(IDIAOracleV2.getValue.selector),
            abi.encode(uint128(100e18), uint128(block.timestamp))
        );
    }

    /// @dev Schedule a real 2:1 stock split on the live tCOIN receipt vault,
    /// effective `secondsFromNow` in the future. Returns the effectiveTime.
    function _scheduleSplit(uint256 secondsFromNow) internal returns (uint64 effectiveTime) {
        effectiveTime = uint64(block.timestamp + secondsFromNow);
        bytes memory params = LibStockSplit.encodeParametersV1(LibDecimalFloat.packLossless(2, 0));
        ICorporateActionsV1(TCOIN).scheduleCorporateAction(STOCK_SPLIT_V1_TYPE_HASH, effectiveTime, params);
    }

    function testForkOracleAutoPausesOnRealScheduledSplit() external {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            // The dedicated fork job sets FORK_TESTS=1 (see fork-tests.yaml).
            // There a missing RPC is a misconfiguration (e.g. a lapsed repo
            // secret) and MUST fail loudly rather than silently no-op —
            // otherwise the only real-vault auto-pause proof would pass having
            // verified nothing. On the per-push rainix job FORK_TESTS is unset,
            // so this is an unambiguous non-run (no assertions were made).
            require(vm.envOr("FORK_TESTS", uint256(0)) == 0, "BASE_RPC_URL unset in fork job");
            console2.log("SKIP testForkOracleAutoPausesOnRealScheduledSplit: BASE_RPC_URL unset (per-push job)");
            return;
        }
        vm.createSelectFork(rpc);

        DIAVaultOracle oracle = _deployOracle();

        // The corporate-actions vault is derived as wtCOIN.asset() == tCOIN.
        assertEq(oracle.corporateActionsVault(), TCOIN, "derived corporate-actions vault is the tStock");

        // No action in-window right now: the oracle prices (a positive
        // 8-decimal answer) off the REAL vault ratio and a fresh mocked DIA
        // price. Guard on live supply so a not-yet-seeded vault doesn't make
        // this vacuous.
        _seedFreshDIA();
        uint256 supply = _liveTotalSupply();
        if (supply > 0) {
            int256 answer = oracle.latestAnswer();
            assertGt(answer, int256(0), "oracle prices a positive answer pre-schedule");
        }

        // Schedule a REAL 2:1 split 30 minutes out — squarely inside the 1h
        // pre-window — on the live tCOIN receipt vault.
        _permitScheduling();
        uint64 effectiveTime = _scheduleSplit(30 minutes);

        // The oracle reads the live schedule and pauses.
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestRoundData();
    }

    function _liveTotalSupply() internal view returns (uint256 supply) {
        (bool ok, bytes memory data) = WTCOIN.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (ok && data.length == 32) supply = abi.decode(data, (uint256));
    }
}
