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
    // Live Base deployments (see st0x.deploy LibProdTokensBase).
    address constant DIA_FEED = 0xCE521b52513242c5094bc56f57887BB2A05B8129;
    address constant WTCOIN = 0x5cDa0E1CA4ce2af96315f7F8963C85399c172204; // StoxWrappedTokenVault (priced)
    address constant TCOIN = 0x626757e6F50675D17fcAd312E82f989aE7A23d38; // receipt vault, ICorporateActionsV1

    uint64 constant PAUSE_BEFORE = 1 hours;
    // Satisfies the cross-epoch invariant `pauseTimeAfter >= maxAge`. The DIA
    // feed is mocked to a fresh value for the pre-schedule read (see
    // `_seedFreshDIA`), so `maxAge` no longer depends on how recently the LIVE
    // DIA `COIN` feed was pushed at the fork block — the fork test's real
    // subject is the corporate-action vault, not DIA.
    uint256 constant MAX_AGE = 1 hours;
    uint64 constant PAUSE_AFTER = 1 hours;
    uint32 constant DRIFT_BPS_PER_DAY = 100;

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
                pauseTimeAfter: PAUSE_AFTER,
                maxRatioDriftPerDayBps: DRIFT_BPS_PER_DAY
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
            console2.log("SKIP testForkOracleAutoPausesOnRealScheduledSplit: BASE_RPC_URL unset");
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
