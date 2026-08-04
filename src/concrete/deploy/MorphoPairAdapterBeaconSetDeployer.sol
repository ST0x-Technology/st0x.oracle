// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {MorphoPairAdapter} from "../adapter/MorphoPairAdapter.sol";
import {ST0xPriceOracle} from "../oracle/ST0xPriceOracle.sol";

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner. Only constrains construction-time ownership; subsequent owner
/// rotations are the beacon's concern.
error ZeroBeaconOwner();

/// @title MorphoPairAdapterBeaconSetDeployerConfig
/// @notice Configuration for the `MorphoPairAdapterBeaconSetDeployer`
/// constructor.
/// @param initialOwner The initial owner of the beacon (controls upgrades).
/// @param central The central `ST0xPriceOracle` store every adapter deployed
/// through this beacon reads. Baked into the implementation as an immutable, so
/// it is fixed for the beacon's whole life (a fresh central needs a fresh
/// deployer). A zero central reverts `MorphoPairAdapter.ZeroCentral` in the
/// implementation constructor.
struct MorphoPairAdapterBeaconSetDeployerConfig {
    address initialOwner;
    ST0xPriceOracle central;
}

/// @title MorphoPairAdapterBeaconSetDeployer
/// @notice Deploys a beacon and the `MorphoPairAdapter` proxies that share it.
/// Beacon management (upgrades, ownership transfer) is performed externally by
/// the beacon owner; this contract retains no authority over the beacon after
/// construction. Follows the canonical `st0x.deploy`-style BeaconSetDeployer
/// pattern.
///
/// The `MorphoPairAdapter` implementation takes the central `ST0xPriceOracle`
/// store as a constructor immutable, so this deployer constructs a fresh
/// implementation bound to `config.central` and puts the beacon over it. Every
/// adapter minted through the beacon therefore reads the same central store.
contract MorphoPairAdapterBeaconSetDeployer {
    /// @notice Emitted when a new MorphoPairAdapter proxy is deployed.
    /// @param caller The direct on-chain caller of `newMorphoPairAdapter`.
    /// Indexed so monitoring can filter by deployer.
    /// @param oracle The address of the new proxy. Indexed for filtering.
    event Deployment(address indexed caller, address indexed oracle);

    /// The beacon for the MorphoPairAdapter implementation contracts.
    IBeacon public immutable iMorphoPairAdapterBeacon;

    /// The central multi-pair price store every adapter deployed through this
    /// beacon reads — fixed for the beacon's whole life.
    ST0xPriceOracle public immutable iCentral;

    constructor(MorphoPairAdapterBeaconSetDeployerConfig memory config) {
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        // A zero central reverts `MorphoPairAdapter.ZeroCentral` in the
        // implementation constructor — no local guard needed.
        MorphoPairAdapter implementation = new MorphoPairAdapter(config.central);

        iCentral = config.central;
        iMorphoPairAdapterBeacon = new UpgradeableBeacon(address(implementation), config.initialOwner);
    }

    /// @notice Deploys and initializes a new MorphoPairAdapter proxy.
    /// @dev The proxy is minted via CREATE2 with `salt = keccak256(base, quote)`,
    /// so its address is a deterministic commitment to its pair and a re-run with
    /// the identical pair reverts on the CREATE2 collision instead of silently
    /// forking a second, divergent adapter. Initialization runs inside the proxy
    /// constructor via the encoded `initialize` call — `MorphoPairAdapter` uses
    /// OpenZeppelin `Initializable`, not `ICloneableV2`, so there is no
    /// magic-value return to check here; a reverting `initialize` bubbles up.
    /// @param base The Morpho collateral token being priced.
    /// @param quote The Morpho loan token prices are denominated in.
    /// @return oracle The deployed proxy as a typed reference.
    // slither-disable-next-line reentrancy-events
    function newMorphoPairAdapter(address base, address quote) external returns (MorphoPairAdapter oracle) {
        bytes32 salt = keccak256(abi.encode(base, quote));
        oracle = MorphoPairAdapter(
            address(
                new BeaconProxy{salt: salt}(
                    address(iMorphoPairAdapterBeacon), abi.encodeCall(MorphoPairAdapter.initialize, (base, quote))
                )
            )
        );

        emit Deployment(msg.sender, address(oracle));

        return oracle;
    }
}
