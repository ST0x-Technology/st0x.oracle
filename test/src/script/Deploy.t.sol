// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable.sol";
import {DIAVaultOracleBeaconSetDeployer} from "../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {ST0xPriceOracleBeaconSetDeployer} from "../../../src/concrete/deploy/ST0xPriceOracleBeaconSetDeployer.sol";
import {MorphoPairAdapterBeaconSetDeployer} from "../../../src/concrete/deploy/MorphoPairAdapterBeaconSetDeployer.sol";
import {ST0xPriceOracle} from "../../../src/concrete/oracle/ST0xPriceOracle.sol";
import {DeployExposed} from "./DeployExposed.sol";

/// @title DeployTest
/// @notice Unit coverage for the `Deploy` script's `deployDIAStackInfra`
/// helper and the `run()` beacon-owner guard. Exercised as a plain unit test
/// (no broadcast / fork) via a test-only subclass exposing the internal
/// helper.
contract DeployTest is Test {
    DeployExposed internal deploy;

    address internal constant BEACON_OWNER = address(0x6074E12);
    address internal constant DEPLOYER = address(0xDEB10E);

    // Signed-price stack env values, held as constants so the test can read
    // them back off the deployed central store rather than trusting the
    // script's internal require()s.
    address internal constant ST0X_ADMIN = address(0x57ADAD);
    address internal constant ST0X_ORACLE_ADMIN = address(0x57ADDD);
    address internal constant ST0X_SIGNER = address(0x57516E);
    uint64 internal constant ST0X_TIMEOUT = uint64(1 hours);

    function setUp() public {
        deploy = new DeployExposed();
    }

    /// @notice The helper deploys the DIA beacon-set deployer and owns its
    /// beacon with the requested owner (never the deploy key) — the security
    /// postcondition `run()` require()s.
    function testDeployDIAStackInfraWiresBeaconAndOwner() external {
        DIAVaultOracleBeaconSetDeployer oracleBSD = deploy.exposedDeployDIAStackInfra(BEACON_OWNER);

        assertTrue(address(oracleBSD) != address(0), "oracle BSD wired");
        assertEq(
            Ownable(address(oracleBSD.iDIAVaultOracleBeacon())).owner(),
            BEACON_OWNER,
            "oracle beacon owned by requested owner"
        );
    }

    /// @notice One sequential test covering everything that reads the PROCESS
    /// env (`ST0X_*`, `DEPLOYMENT_KEY`, `BEACON_INITIAL_OWNER`,
    /// `DEPLOYMENT_SUITE`): the signed-price helper's env-config wiring + its
    /// key-separation guards, AND the `run()` entry point's beacon-owner guard,
    /// both-suite dispatch and unknown-suite fall-through.
    ///
    /// ALL of these live in ONE test function on purpose. `vm.setEnv` is
    /// PROCESS-global and not rolled back per test, so splitting scenarios that
    /// touch the SAME env vars into separate test functions lets forge's
    /// concurrent execution race the shared vars and flake. Kept sequential
    /// here, the env mutations are deterministic. `vm.startBroadcast` inside
    /// `run()` is a no-op under `forge test`, so the deploy logic runs
    /// in-process against the test EVM.
    function testDeployEnvConfigDispatchAndKeySeparation() external {
        vm.setEnv("ST0X_ADMIN", vm.toString(ST0X_ADMIN));
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(ST0X_ORACLE_ADMIN));
        vm.setEnv("ST0X_SIGNER", vm.toString(ST0X_SIGNER));
        vm.setEnv("ST0X_TIMEOUT", vm.toString(uint256(ST0X_TIMEOUT)));

        // ----- signed-price helper: env-config wiring (#267) -----
        // Happy path: admin/oracleAdmin both distinct from the deploy key, so
        // the guards pass and the stack deploys. Assert the postconditions
        // EXTERNALLY off the returned contracts — independent of the script's
        // own require()s, so a deleted require or a deployer that wired a
        // DIFFERENT signer than env still fails here.
        (
            ST0xPriceOracle central,
            ST0xPriceOracleBeaconSetDeployer oracleBSD,
            MorphoPairAdapterBeaconSetDeployer adapterBSD
        ) = deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);

        assertEq(central.signer(), ST0X_SIGNER, "signer wired from env");
        assertEq(central.timeout(), ST0X_TIMEOUT, "timeout wired from env");
        assertTrue(
            central.hasRole(central.ORACLE_ADMIN_ROLE(), ST0X_ORACLE_ADMIN), "oracleAdmin granted ORACLE_ADMIN_ROLE"
        );
        assertEq(Ownable(address(oracleBSD.iST0xPriceOracleBeacon())).owner(), BEACON_OWNER, "st0x price beacon owner");
        assertEq(
            Ownable(address(adapterBSD.iMorphoPairAdapterBeacon())).owner(), BEACON_OWNER, "morpho adapter beacon owner"
        );
        assertEq(address(adapterBSD.iCentral()), address(central), "adapter bound to the minted central");

        // ----- run() suite dispatch + beacon-owner guard (#256) -----
        // Done here (before the ST0X_* guard mutations below) while ST0X_ADMIN /
        // ST0X_ORACLE_ADMIN still hold their non-deployer values, so the
        // signed-price success branch's own key-separation guards pass.
        uint256 deployKey = uint256(keccak256("deploy.t.sol.key"));
        address deployer = vm.addr(deployKey);
        vm.setEnv("DEPLOYMENT_KEY", vm.toString(deployKey));
        assertTrue(deployer != BEACON_OWNER && deployer != ST0X_ADMIN, "distinct keys");

        // Guard: `BEACON_INITIAL_OWNER` must differ from the deploy key — the
        // beacon owner can swap the implementation behind every proxy. Reverts
        // BEFORE the suite dispatch, so it runs regardless of the suite value.
        vm.setEnv("BEACON_INITIAL_OWNER", vm.toString(deployer));
        vm.setEnv("DEPLOYMENT_SUITE", "dia-vault-oracle");
        vm.expectRevert("BEACON_INITIAL_OWNER must not be the deploy key");
        deploy.run();

        // Owner now distinct, so the guard passes and we reach the dispatch.
        vm.setEnv("BEACON_INITIAL_OWNER", vm.toString(BEACON_OWNER));

        // Dispatch: "signed-price-stack" routes to `deploySignedPriceStack` and
        // completes without reverting — the ONLY end-to-end exercise of the
        // `DEPLOYMENT_SUITE_SIGNED_PRICE_STACK` match arm. A typo in the
        // constant preimage or a mis-wired arm surfaces here.
        vm.setEnv("DEPLOYMENT_SUITE", "signed-price-stack");
        deploy.run();

        // Dispatch: "dia-vault-oracle" routes to `deployDIAStackInfra`.
        vm.setEnv("DEPLOYMENT_SUITE", "dia-vault-oracle");
        deploy.run();

        // Fall-through: an unrecognised suite hits the explicit
        // `revert("Unknown deployment suite")`. Pins the fall-through so a
        // future refactor can't silently let an unknown suite no-op green.
        vm.setEnv("DEPLOYMENT_SUITE", "bogus-suite");
        vm.expectRevert("Unknown deployment suite");
        deploy.run();

        // ----- signed-price helper: key-separation guards (#267) -----
        // Guard: ST0X_ADMIN holds DEFAULT_ADMIN_ROLE (can rotate the publisher
        // signer), so it must never be the hot deploy key.
        vm.setEnv("ST0X_ADMIN", vm.toString(DEPLOYER));
        vm.expectRevert("ST0X_ADMIN must not be the deploy key");
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);

        // Guard: ST0X_ORACLE_ADMIN rotates signer/timeout directly — same rule.
        vm.setEnv("ST0X_ADMIN", vm.toString(ST0X_ADMIN));
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(DEPLOYER));
        vm.expectRevert("ST0X_ORACLE_ADMIN must not be the deploy key");
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);
    }
}
