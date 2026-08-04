// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {ST0xPriceOracle} from "../oracle/ST0xPriceOracle.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error ZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner. Only constrains construction-time ownership; subsequent owner
/// rotations are the beacon's concern.
error ZeroBeaconOwner();

/// @title ST0xPriceOracleBeaconSetDeployerConfig
/// @notice Configuration for the `ST0xPriceOracleBeaconSetDeployer`
/// constructor.
/// @param initialOwner The initial owner of the beacon (controls upgrades).
/// @param initialST0xPriceOracleImplementation The initial implementation
/// contract behind the beacon.
struct ST0xPriceOracleBeaconSetDeployerConfig {
    address initialOwner;
    address initialST0xPriceOracleImplementation;
}

/// @title ST0xPriceOracleBeaconSetDeployer
/// @notice Deploys a beacon and the `ST0xPriceOracle` proxies that share it.
/// Beacon management (upgrades, ownership transfer) is performed externally by
/// the beacon owner; this contract retains no authority over the beacon after
/// construction. Follows the canonical `st0x.deploy`-style BeaconSetDeployer
/// pattern.
///
/// Unlike the DIA stack's beacon-set deployer, `ST0xPriceOracle` initialises
/// through OpenZeppelin's `Initializable` (an `external initializer` returning
/// void), not `ICloneableV2`, so initialization runs inside the proxy
/// constructor via the encoded `initialize` call and there is no magic-value
/// check to perform on this side.
contract ST0xPriceOracleBeaconSetDeployer {
    /// @notice Emitted when a new ST0xPriceOracle proxy is deployed.
    /// @param caller The direct on-chain caller of `newST0xPriceOracle`.
    /// Indexed so monitoring can filter by deployer.
    /// @param oracle The address of the new proxy. Indexed for filtering.
    event Deployment(address indexed caller, address indexed oracle);

    /// The beacon for the ST0xPriceOracle implementation contracts.
    IBeacon public immutable iST0xPriceOracleBeacon;

    constructor(ST0xPriceOracleBeaconSetDeployerConfig memory config) {
        if (config.initialST0xPriceOracleImplementation == address(0)) {
            revert ZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        iST0xPriceOracleBeacon = new UpgradeableBeacon(config.initialST0xPriceOracleImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new ST0xPriceOracle proxy.
    /// @dev The proxy is minted via CREATE2 with `salt = keccak256(args)`, so
    /// its address is a deterministic commitment to its init args and a re-run
    /// with identical args reverts on the CREATE2 collision instead of silently
    /// forking a second, divergent oracle. Initialization runs inside the proxy
    /// constructor via the encoded `initialize` call — `ST0xPriceOracle` uses
    /// OpenZeppelin `Initializable`, not `ICloneableV2`, so there is no
    /// magic-value return to check here; a reverting `initialize` bubbles up.
    /// @param admin Receives `DEFAULT_ADMIN_ROLE`.
    /// @param oracleAdmin Receives `ORACLE_ADMIN_ROLE`.
    /// @param signer The initial global publisher key.
    /// @param timeout The initial global staleness bound.
    /// @return oracle The deployed proxy as a typed reference.
    // slither-disable-next-line reentrancy-events
    function newST0xPriceOracle(address admin, address oracleAdmin, address signer, uint64 timeout)
        external
        returns (ST0xPriceOracle oracle)
    {
        bytes32 salt = keccak256(abi.encode(admin, oracleAdmin, signer, timeout));
        oracle = ST0xPriceOracle(
            address(
                new BeaconProxy{salt: salt}(
                    address(iST0xPriceOracleBeacon),
                    abi.encodeCall(ST0xPriceOracle.initialize, (admin, oracleAdmin, signer, timeout))
                )
            )
        );

        emit Deployment(msg.sender, address(oracle));

        return oracle;
    }
}
