// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Deploy} from "../../../script/Deploy.sol";
import {DIAVaultOracleBeaconSetDeployer} from "../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {ST0xPriceOracleBeaconSetDeployer} from "../../../src/concrete/deploy/ST0xPriceOracleBeaconSetDeployer.sol";
import {MorphoPairAdapterBeaconSetDeployer} from "../../../src/concrete/deploy/MorphoPairAdapterBeaconSetDeployer.sol";
import {ST0xPriceOracle} from "../../../src/concrete/oracle/ST0xPriceOracle.sol";

/// @title DeployExposed
/// @dev Test-only subclass that exposes the internal deploy helpers for unit
/// testing. Calling `run()` directly is awkward because it opens a
/// `vm.startBroadcast`; this exposer lets the test drive the pure
/// wiring/postcondition logic without a broadcast or fork. The signed-price
/// exposer returns the created contracts so the test can re-assert the wired
/// signer/timeout/roles/owners externally, independent of the script's own
/// require()s.
contract DeployExposed is Deploy {
    function exposedDeployDIAStackInfra(address beaconInitialOwner) external returns (DIAVaultOracleBeaconSetDeployer) {
        return deployDIAStackInfra(beaconInitialOwner);
    }

    function exposedDeploySignedPriceStack(address beaconInitialOwner, address deployer)
        external
        returns (
            ST0xPriceOracle central,
            ST0xPriceOracleBeaconSetDeployer oracleBSD,
            MorphoPairAdapterBeaconSetDeployer adapterBSD
        )
    {
        return deploySignedPriceStack(beaconInitialOwner, deployer);
    }
}
