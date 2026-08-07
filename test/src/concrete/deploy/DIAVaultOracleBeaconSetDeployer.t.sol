// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {IDIAOracleV2} from "../../../../src/interface/IDIAOracleV2.sol";
import {DIAVaultOracle, DIAVaultOracleConfig, ZeroVault} from "../../../../src/concrete/oracle/DIAVaultOracle.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner,
    InitializeOracleFailed
} from "../../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {MockDIAOracle} from "../../../mocks/MockDIAOracle.sol";
import {MockERC4626} from "../../../mocks/MockERC4626.sol";
import {MockCorporateActions} from "../../../mocks/MockCorporateActions.sol";
import {MockWrongMagicDIAVaultOracle} from "../../../mocks/MockWrongMagicDIAVaultOracle.sol";
import {DIAVaultOracleV2} from "../../../mocks/DIAVaultOracleV2.sol";
import {ACTION_TYPE_STOCK_SPLIT_V1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";

contract DIAVaultOracleBeaconSetDeployerTest is Test {
    DIAVaultOracle internal implementation;
    MockDIAOracle internal diaOracle;
    MockERC4626 internal vault;
    MockCorporateActions internal actions;
    address internal constant BEACON_OWNER = address(0xBEEF);
    string internal constant SYMBOL = "COIN";
    uint256 internal constant MAX_AGE = 1 hours;

    event Deployment(address indexed caller, address indexed oracle);

    function setUp() public {
        implementation = new DIAVaultOracle();
        diaOracle = new MockDIAOracle();
        vault = new MockERC4626();
        actions = new MockCorporateActions();
        // The oracle derives its corporate-actions vault from vault.asset().
        vault.setAsset(address(actions));
        vm.warp(1_000_000);
    }

    function _deployBSD() internal returns (DIAVaultOracleBeaconSetDeployer) {
        return new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialDIAVaultOracleImplementation: address(implementation)
            })
        );
    }

    function _defaultOracleConfig() internal view returns (DIAVaultOracleConfig memory) {
        return DIAVaultOracleConfig({
            diaOracle: IDIAOracleV2(address(diaOracle)),
            symbol: SYMBOL,
            vault: address(vault),
            maxAge: MAX_AGE,
            actionTypeMask: ACTION_TYPE_STOCK_SPLIT_V1,
            pauseTimeBefore: 3600,
            pauseTimeAfter: 3600,
            maxRatioDriftPerDayBps: 100
        });
    }

    // -------- Constructor validation --------

    function testConstructorRevertsZeroImplementation() external {
        vm.expectRevert(ZeroImplementation.selector);
        new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialDIAVaultOracleImplementation: address(0)
            })
        );
    }

    function testConstructorRevertsZeroBeaconOwner() external {
        vm.expectRevert(ZeroBeaconOwner.selector);
        new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: address(0), initialDIAVaultOracleImplementation: address(implementation)
            })
        );
    }

    function testConstructorHappyPathDeploysBeacon() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();
        address beacon = address(bsd.I_DIA_VAULT_ORACLE_BEACON());
        assertTrue(beacon != address(0));
        assertEq(UpgradeableBeacon(beacon).owner(), BEACON_OWNER);
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));
    }

    // -------- newDIAVaultOracle --------

    /// @notice CREATE2 salt = keccak256(config): minting the same config twice
    /// reverts on the address collision rather than silently forking a second
    /// divergent oracle. A differing config lands at a different address.
    function testNewDIAVaultOracleIsIdempotentPerConfig() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();
        DIAVaultOracle first = bsd.newDIAVaultOracle(_defaultOracleConfig());

        // Same config → CREATE2 collision → revert (empty returndata).
        vm.expectRevert();
        bsd.newDIAVaultOracle(_defaultOracleConfig());

        // Differing config → different deterministic address. Vary
        // `pauseTimeAfter` (not `maxAge`) so the cross-epoch invariant
        // `pauseTimeAfter >= maxAge` still holds for the second config.
        DIAVaultOracleConfig memory other = _defaultOracleConfig();
        other.pauseTimeAfter = _defaultOracleConfig().pauseTimeAfter + 1;
        DIAVaultOracle second = bsd.newDIAVaultOracle(other);
        assertTrue(address(first) != address(second), "distinct config gives distinct address");
    }

    function testNewDIAVaultOracleEmitsDeployment() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();

        vm.recordLogs();
        DIAVaultOracle oracle = bsd.newDIAVaultOracle(_defaultOracleConfig());

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("Deployment(address,address)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(bsd) && entries[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(this), "caller mismatch");
                assertEq(address(uint160(uint256(entries[i].topics[2]))), address(oracle), "oracle mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "Deployment event not emitted");
    }

    function testNewDIAVaultOraclePropagatesInitRevertZeroVault() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();
        DIAVaultOracleConfig memory badConfig = _defaultOracleConfig();
        badConfig.vault = address(0);
        vm.expectRevert(ZeroVault.selector);
        bsd.newDIAVaultOracle(badConfig);
    }

    /// @notice A wrong-magic (non-`ICLONEABLE_V2_SUCCESS`) return from
    /// `initialize` — as opposed to a revert — must be rejected with
    /// `InitializeOracleFailed`. Distinct from
    /// `testNewDIAVaultOraclePropagatesInitRevertZeroVault`, which covers a
    /// REVERTING init. Point the beacon at a mock impl whose `initialize`
    /// succeeds but returns the wrong magic.
    function testNewDIAVaultOracleRevertsOnWrongInitMagic() external {
        MockWrongMagicDIAVaultOracle wrongImpl = new MockWrongMagicDIAVaultOracle();
        DIAVaultOracleBeaconSetDeployer bsd = new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialDIAVaultOracleImplementation: address(wrongImpl)
            })
        );
        vm.expectRevert(InitializeOracleFailed.selector);
        bsd.newDIAVaultOracle(_defaultOracleConfig());
    }

    /// @notice The beacon is genuinely SHARED: deploy two proxies with DISTINCT
    /// configs, then upgrade the single beacon to a V2 implementation and prove
    /// BOTH proxies retarget (answer the V2-only `implVersion()`), while each
    /// proxy retains its OWN distinct config across the upgrade. A tautological
    /// version (identical configs, no upgrade) would pass even if each proxy
    /// had its own beacon — this discriminates that.
    function testMultipleProxiesShareBeacon() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();

        // Distinct configs: different vault + symbol per proxy.
        MockERC4626 vaultB = new MockERC4626();
        vaultB.setAsset(address(actions));
        DIAVaultOracleConfig memory configA = _defaultOracleConfig();
        DIAVaultOracleConfig memory configB = _defaultOracleConfig();
        configB.symbol = "AMZN";
        configB.vault = address(vaultB);

        DIAVaultOracle a = bsd.newDIAVaultOracle(configA);
        DIAVaultOracle b = bsd.newDIAVaultOracle(configB);
        assertTrue(address(a) != address(b), "proxies must be distinct");

        address beacon = address(bsd.I_DIA_VAULT_ORACLE_BEACON());
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));

        // V1 has no `implVersion()` — both proxies revert on it pre-upgrade.
        (bool okA,) = address(a).staticcall(abi.encodeWithSignature("implVersion()"));
        (bool okB,) = address(b).staticcall(abi.encodeWithSignature("implVersion()"));
        assertFalse(okA, "V1 has no implVersion() (a)");
        assertFalse(okB, "V1 has no implVersion() (b)");

        // One beacon upgrade retargets EVERY proxy off that beacon.
        DIAVaultOracleV2 v2Impl = new DIAVaultOracleV2();
        vm.prank(BEACON_OWNER);
        UpgradeableBeacon(beacon).upgradeTo(address(v2Impl));

        assertEq(DIAVaultOracleV2(address(a)).implVersion(), 2, "proxy a retargeted");
        assertEq(DIAVaultOracleV2(address(b)).implVersion(), 2, "proxy b retargeted");

        // Each proxy retains its OWN distinct config across the upgrade.
        assertEq(a.vault(), address(vault), "proxy a keeps its own vault");
        assertEq(a.symbol(), SYMBOL, "proxy a keeps its own symbol");
        assertEq(b.vault(), address(vaultB), "proxy b keeps its own vault");
        assertEq(b.symbol(), "AMZN", "proxy b keeps its own symbol");
    }
}
