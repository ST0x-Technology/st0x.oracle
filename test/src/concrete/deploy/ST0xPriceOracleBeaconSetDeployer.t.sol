// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {ST0xPriceOracle} from "../../../../src/concrete/oracle/ST0xPriceOracle.sol";
import {
    ST0xPriceOracleBeaconSetDeployer,
    ST0xPriceOracleBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "../../../../src/concrete/deploy/ST0xPriceOracleBeaconSetDeployer.sol";
import {ST0xPriceOracleV2} from "../../../mocks/ST0xPriceOracleV2.sol";

contract ST0xPriceOracleBeaconSetDeployerTest is Test {
    ST0xPriceOracle internal implementation;

    address internal constant BEACON_OWNER = address(0xBEEF);
    address internal constant ADMIN = address(0xC0DE);
    address internal constant ORACLE_ADMIN = address(0xADDD);
    uint256 internal constant SIGNER_PK = uint256(keccak256("st0x.price-oracle.signer.test"));
    address internal SIGNER;
    uint64 internal constant TIMEOUT = 1 hours;

    event Deployment(address indexed caller, address indexed oracle);

    function setUp() public {
        implementation = new ST0xPriceOracle();
        SIGNER = vm.addr(SIGNER_PK);
        vm.warp(1_000_000);
    }

    function _deployBSD() internal returns (ST0xPriceOracleBeaconSetDeployer) {
        return new ST0xPriceOracleBeaconSetDeployer(
            ST0xPriceOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialST0xPriceOracleImplementation: address(implementation)
            })
        );
    }

    // -------- Constructor validation --------

    function testConstructorRevertsZeroImplementation() external {
        vm.expectRevert(ZeroImplementation.selector);
        new ST0xPriceOracleBeaconSetDeployer(
            ST0xPriceOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialST0xPriceOracleImplementation: address(0)
            })
        );
    }

    function testConstructorRevertsZeroBeaconOwner() external {
        vm.expectRevert(ZeroBeaconOwner.selector);
        new ST0xPriceOracleBeaconSetDeployer(
            ST0xPriceOracleBeaconSetDeployerConfig({
                initialOwner: address(0), initialST0xPriceOracleImplementation: address(implementation)
            })
        );
    }

    function testConstructorHappyPathDeploysBeacon() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();
        address beacon = address(bsd.iST0xPriceOracleBeacon());
        assertTrue(beacon != address(0));
        assertEq(UpgradeableBeacon(beacon).owner(), BEACON_OWNER);
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));
    }

    // -------- newST0xPriceOracle --------

    /// @notice The proxy is initialized inside its constructor: signer, timeout,
    /// and both role grants are live immediately after mint.
    function testNewST0xPriceOracleInitializesState() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();
        ST0xPriceOracle oracle = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT);

        assertEq(oracle.signer(), SIGNER, "signer set");
        assertEq(oracle.timeout(), TIMEOUT, "timeout set");
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), ADMIN), "admin has default admin role");
        assertTrue(oracle.hasRole(oracle.ORACLE_ADMIN_ROLE(), ORACLE_ADMIN), "oracle admin has oracle admin role");
    }

    /// @notice CREATE2 salt = keccak256(args): minting the same args twice
    /// reverts on the address collision rather than silently forking a second
    /// divergent oracle. Differing args land at a different address.
    function testNewST0xPriceOracleIsIdempotentPerConfig() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();
        ST0xPriceOracle first = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT);

        // Same args → CREATE2 collision → revert (empty returndata).
        vm.expectRevert();
        bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT);

        // Differing args → different deterministic address.
        ST0xPriceOracle second = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT + 1);
        assertTrue(address(first) != address(second), "distinct args give distinct address");
    }

    function testNewST0xPriceOracleEmitsDeployment() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();

        vm.recordLogs();
        ST0xPriceOracle oracle = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT);

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

    /// @notice A reverting `initialize` (here a zero signer) bubbles straight up
    /// out of the proxy constructor — there is no magic-value check to swallow
    /// it, unlike the DIA stack's beacon-set deployer.
    function testNewST0xPriceOraclePropagatesInitRevertZeroSigner() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();
        vm.expectRevert(ST0xPriceOracle.ZeroSigner.selector);
        bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, address(0), TIMEOUT);
    }

    /// @notice The beacon is genuinely SHARED: deploy two singletons with
    /// DISTINCT args, then upgrade the single beacon to a V2 implementation and
    /// prove BOTH proxies retarget (answer the V2-only `implVersion()`), while
    /// each proxy retains its OWN distinct config across the upgrade.
    function testMultipleProxiesShareBeacon() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();

        ST0xPriceOracle a = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT);
        ST0xPriceOracle b = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT + 1);
        assertTrue(address(a) != address(b), "proxies must be distinct");

        address beacon = address(bsd.iST0xPriceOracleBeacon());
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));

        // V1 has no `implVersion()` — both proxies revert on it pre-upgrade.
        (bool okA,) = address(a).staticcall(abi.encodeWithSignature("implVersion()"));
        (bool okB,) = address(b).staticcall(abi.encodeWithSignature("implVersion()"));
        assertFalse(okA, "V1 has no implVersion() (a)");
        assertFalse(okB, "V1 has no implVersion() (b)");

        // One beacon upgrade retargets EVERY proxy off that beacon.
        ST0xPriceOracleV2 v2Impl = new ST0xPriceOracleV2();
        vm.prank(BEACON_OWNER);
        UpgradeableBeacon(beacon).upgradeTo(address(v2Impl));

        assertEq(ST0xPriceOracleV2(address(a)).implVersion(), 2, "proxy a retargeted");
        assertEq(ST0xPriceOracleV2(address(b)).implVersion(), 2, "proxy b retargeted");

        // Each proxy retains its OWN distinct config across the upgrade.
        assertEq(a.timeout(), TIMEOUT, "proxy a keeps its own timeout");
        assertEq(b.timeout(), TIMEOUT + 1, "proxy b keeps its own timeout");
    }
}
