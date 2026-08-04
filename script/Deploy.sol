// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Script, console2} from "forge-std-1.16.1/src/Script.sol";
import {Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable.sol";

import {DIAVaultOracle} from "../src/concrete/oracle/DIAVaultOracle.sol";
import {ST0xPriceOracle} from "../src/concrete/oracle/ST0xPriceOracle.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig
} from "../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {
    ST0xPriceOracleBeaconSetDeployer,
    ST0xPriceOracleBeaconSetDeployerConfig
} from "../src/concrete/deploy/ST0xPriceOracleBeaconSetDeployer.sol";
import {
    MorphoPairAdapterBeaconSetDeployer,
    MorphoPairAdapterBeaconSetDeployerConfig
} from "../src/concrete/deploy/MorphoPairAdapterBeaconSetDeployer.sol";

/// @dev Deploys the DIA stack infra: a fresh `DIAVaultOracle` implementation
/// and its beacon-set deployer. No per-vault proxies are minted — each vault's
/// oracle is minted afterwards through the beacon-set deployer with that
/// vault's DIA feed + corporate-action pause config.
bytes32 constant DEPLOYMENT_SUITE_DIA_VAULT_ORACLE = keccak256("dia-vault-oracle");

/// @dev Deploys the signed-price stack infra: a fresh `ST0xPriceOracle`
/// implementation and its beacon-set deployer, the singleton central store
/// minted through that deployer, and a `MorphoPairAdapterBeaconSetDeployer`
/// bound to that singleton. No per-market adapter proxies are minted — those
/// are deployed per Morpho market through the adapter beacon-set deployer with
/// the correct base/quote for that market.
bytes32 constant DEPLOYMENT_SUITE_SIGNED_PRICE_STACK = keccak256("signed-price-stack");

/// @title Deploy
/// @notice Deployment entry point consumed by `rainix-sol-artifacts`
/// (`manual-sol-artifacts.yaml`). Dispatches on the DEPLOYMENT_SUITE
/// environment variable; the broadcast key comes from DEPLOYMENT_KEY and the
/// beacon owner from BEACON_INITIAL_OWNER (both required, no defaults).
///
/// Run a suite manually with:
///     DEPLOYMENT_SUITE=dia-vault-oracle \
///     BEACON_INITIAL_OWNER=0x<governance-multisig> \
///         forge script script/Deploy.sol:Deploy \
///         --rpc-url $ETH_RPC_URL --broadcast \
///         --private-key $DEPLOYMENT_KEY
///
/// Omit `--broadcast` to dry-run.
contract Deploy is Script {
    /// @notice Deploys the DIA stack infra: a fresh `DIAVaultOracle`
    /// implementation and its beacon-set deployer (owning the beacon). Assumes
    /// the caller has an active broadcast.
    /// @param beaconInitialOwner Initial owner of the beacon.
    /// @return oracleBSD The deployed `DIAVaultOracleBeaconSetDeployer`.
    function deployDIAStackInfra(address beaconInitialOwner) internal returns (DIAVaultOracleBeaconSetDeployer) {
        DIAVaultOracle oracleImpl = new DIAVaultOracle();

        DIAVaultOracleBeaconSetDeployer oracleBSD = new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: beaconInitialOwner, initialDIAVaultOracleImplementation: address(oracleImpl)
            })
        );

        // Postcondition: the beacon — which controls the implementation behind
        // every oracle proxy, i.e. every served price — must be owned by the
        // requested owner, never left with the (hot, CI-held) deploy key.
        require(
            Ownable(address(oracleBSD.iDIAVaultOracleBeacon())).owner() == beaconInitialOwner,
            "oracle beacon owner mismatch"
        );

        console2.log("=== Deployed DIA stack infra ===");
        console2.log("oracleImpl", address(oracleImpl));
        console2.log("oracleBSD", address(oracleBSD));

        return oracleBSD;
    }

    /// @notice Deploys the signed-price stack infra: a fresh `ST0xPriceOracle`
    /// implementation and its beacon-set deployer, the singleton central store
    /// minted through that deployer, and a `MorphoPairAdapterBeaconSetDeployer`
    /// bound to that singleton. No per-market adapter proxies are minted here.
    /// Assumes the caller has an active broadcast. Reads the oracle config from
    /// env: `ST0X_ADMIN`, `ST0X_ORACLE_ADMIN`, `ST0X_SIGNER` (addresses) and
    /// `ST0X_TIMEOUT` (uint64).
    /// @param beaconInitialOwner Initial owner of both beacons.
    /// @return central The singleton central `ST0xPriceOracle` store.
    /// @return oracleBSD The deployed `ST0xPriceOracleBeaconSetDeployer`.
    /// @return adapterBSD The deployed `MorphoPairAdapterBeaconSetDeployer`.
    function deploySignedPriceStack(address beaconInitialOwner, address deployer)
        internal
        returns (
            ST0xPriceOracle central,
            ST0xPriceOracleBeaconSetDeployer oracleBSD,
            MorphoPairAdapterBeaconSetDeployer adapterBSD
        )
    {
        address admin = vm.envAddress("ST0X_ADMIN");
        address oracleAdmin = vm.envAddress("ST0X_ORACLE_ADMIN");
        address signer = vm.envAddress("ST0X_SIGNER");
        uint256 timeoutRaw = vm.envUint("ST0X_TIMEOUT");
        require(timeoutRaw <= type(uint64).max, "ST0X_TIMEOUT overflows uint64");
        uint64 timeout = uint64(timeoutRaw);

        // ST0X_ADMIN holds DEFAULT_ADMIN_ROLE, the role-admin for
        // ORACLE_ADMIN_ROLE — so it can grant itself ORACLE_ADMIN_ROLE and
        // rotate the publisher signer/timeout, i.e. fully control every served
        // price. It (and ST0X_ORACLE_ADMIN, which rotates them directly) must
        // therefore be governance, never the hot CI deploy key — the same
        // separation the beacon owner enforces. Fail the deploy loudly rather
        // than silently leaving the feed under the deploy key's control.
        require(admin != deployer, "ST0X_ADMIN must not be the deploy key");
        require(oracleAdmin != deployer, "ST0X_ORACLE_ADMIN must not be the deploy key");

        ST0xPriceOracle oracleImpl = new ST0xPriceOracle();
        oracleBSD = new ST0xPriceOracleBeaconSetDeployer(
            ST0xPriceOracleBeaconSetDeployerConfig({
                initialOwner: beaconInitialOwner, initialST0xPriceOracleImplementation: address(oracleImpl)
            })
        );

        // The singleton central store, minted through its own beacon-set
        // deployer so its creation is atomic and recorded (Deployment event).
        central = oracleBSD.newST0xPriceOracle(admin, oracleAdmin, signer, timeout);

        adapterBSD = new MorphoPairAdapterBeaconSetDeployer(
            MorphoPairAdapterBeaconSetDeployerConfig({initialOwner: beaconInitialOwner, central: central})
        );

        // Postcondition: the central store carries the requested signer and the
        // ORACLE_ADMIN_ROLE grant, so signer/timeout rotation is callable from
        // day one and no post-deploy grant step is left dangling.
        require(central.signer() == signer, "signer mismatch");
        require(central.timeout() == timeout, "timeout mismatch");
        require(central.hasRole(central.ORACLE_ADMIN_ROLE(), oracleAdmin), "oracle admin role not granted");

        // Postcondition: both beacons — which control the implementation behind
        // every proxy, i.e. every served price — must be owned by the requested
        // owner, never left with the (hot, CI-held) deploy key.
        require(
            Ownable(address(oracleBSD.iST0xPriceOracleBeacon())).owner() == beaconInitialOwner,
            "oracle beacon owner mismatch"
        );
        require(
            Ownable(address(adapterBSD.iMorphoPairAdapterBeacon())).owner() == beaconInitialOwner,
            "adapter beacon owner mismatch"
        );

        console2.log("=== Deployed signed-price stack infra ===");
        console2.log("oracleImpl", address(oracleImpl));
        console2.log("oracleBSD", address(oracleBSD));
        console2.log("central", address(central));
        console2.log("adapterBSD", address(adapterBSD));
    }

    /// @notice Entry point. Dispatches to the requested deployment suite
    /// based on the DEPLOYMENT_SUITE environment variable.
    ///
    /// BEACON_INITIAL_OWNER is REQUIRED and must differ from the deploy key:
    /// the beacon owner can swap the implementation behind every proxy, so it
    /// must be governance (a multisig), never the hot CI deploy key. A missing
    /// var fails the deploy loudly rather than silently owning the beacons
    /// with the deploy key.
    function run() external {
        uint256 deploymentKey = vm.envUint("DEPLOYMENT_KEY");
        address deployer = vm.addr(deploymentKey);
        address beaconInitialOwner = vm.envAddress("BEACON_INITIAL_OWNER");
        require(beaconInitialOwner != deployer, "BEACON_INITIAL_OWNER must not be the deploy key");
        bytes32 suite = keccak256(bytes(vm.envString("DEPLOYMENT_SUITE")));

        console2.log("deployer", deployer);
        console2.log("beacon initial owner", beaconInitialOwner);

        if (suite == DEPLOYMENT_SUITE_DIA_VAULT_ORACLE) {
            vm.startBroadcast(deploymentKey);
            deployDIAStackInfra(beaconInitialOwner);
            vm.stopBroadcast();
        } else if (suite == DEPLOYMENT_SUITE_SIGNED_PRICE_STACK) {
            vm.startBroadcast(deploymentKey);
            deploySignedPriceStack(beaconInitialOwner, deployer);
            vm.stopBroadcast();
        } else {
            revert("Unknown deployment suite");
        }
    }
}
