// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {ST0xPriceOracle} from "../../../../src/concrete/oracle/ST0xPriceOracle.sol";
import {MorphoPairAdapter} from "../../../../src/concrete/adapter/MorphoPairAdapter.sol";
import {
    MorphoPairAdapterBeaconSetDeployer,
    MorphoPairAdapterBeaconSetDeployerConfig
} from "../../../../src/concrete/deploy/MorphoPairAdapterBeaconSetDeployer.sol";
import {
    ST0xPriceOracleBeaconSetDeployer,
    ST0xPriceOracleBeaconSetDeployerConfig
} from "../../../../src/concrete/deploy/ST0xPriceOracleBeaconSetDeployer.sol";
import {MockERC20Decimals} from "../../../mocks/MockERC20Decimals.sol";

/// @title DeployerSaltDerivationTest
/// @notice Pins the CREATE2 salt derivation of the Morpho and ST0x beacon-set
/// deployers to their documented formulas. The idempotence tests only prove two
/// DISTINCT configs land at DISTINCT addresses — but for these two deployers the
/// proxy init-code already carries the full config, so distinctness holds even if
/// the salt drops config fields. These tests independently recompute the CREATE2
/// address from `salt = keccak256(<documented args>)` and assert the deployed
/// proxy lands EXACTLY there, so the salt formula cannot silently drift.
contract DeployerSaltDerivationTest is Test {
    address internal constant BEACON_OWNER = address(0xBEEF);
    address internal constant ADMIN = address(0xC0DE);
    address internal constant ORACLE_ADMIN = address(0xADDD);
    address internal constant SIGNER = address(0x516E);
    uint64 internal constant TIMEOUT = 1 hours;

    function setUp() public {
        vm.warp(1_000_000);
    }

    /// @dev CREATE2 address predicted from the deployer, a salt, and the full
    /// BeaconProxy init-code (creation code ++ encoded (beacon, data)).
    function _predict(address deployer, bytes32 salt, address beacon, bytes memory data)
        internal
        pure
        returns (address)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, data)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Morpho salt MUST be keccak256(abi.encode(base, quote)). If the
    /// deployer drops `quote` (or otherwise changes the salt args), the deployed
    /// address will not match this independent prediction.
    function testMorphoSaltIsKeccakBaseQuote() external {
        ST0xPriceOracle central;
        {
            ST0xPriceOracle impl = new ST0xPriceOracle();
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), ADMIN);
            central = ST0xPriceOracle(
                address(
                    new BeaconProxy(
                        address(beacon), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ADMIN, SIGNER, TIMEOUT))
                    )
                )
            );
        }
        MockERC20Decimals base = new MockERC20Decimals(18);
        MockERC20Decimals quote = new MockERC20Decimals(6);

        MorphoPairAdapterBeaconSetDeployer bsd = new MorphoPairAdapterBeaconSetDeployer(
            MorphoPairAdapterBeaconSetDeployerConfig({initialOwner: BEACON_OWNER, central: central})
        );

        bytes32 expectedSalt = keccak256(abi.encode(address(base), address(quote)));
        address predicted = _predict(
            address(bsd),
            expectedSalt,
            address(bsd.iMorphoPairAdapterBeacon()),
            abi.encodeCall(MorphoPairAdapter.initialize, (address(base), address(quote)))
        );

        MorphoPairAdapter adapter = bsd.newMorphoPairAdapter(address(base), address(quote));
        assertEq(address(adapter), predicted, "Morpho proxy must land at keccak256(base,quote) CREATE2 address");
    }

    /// @notice ST0x salt MUST be keccak256(abi.encode(admin, oracleAdmin, signer,
    /// timeout)). If the deployer drops any arg (e.g. timeout) from the salt, the
    /// deployed address will not match this independent prediction.
    function testST0xSaltIsKeccakAllArgs() external {
        ST0xPriceOracle implementation = new ST0xPriceOracle();
        ST0xPriceOracleBeaconSetDeployer bsd = new ST0xPriceOracleBeaconSetDeployer(
            ST0xPriceOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialST0xPriceOracleImplementation: address(implementation)
            })
        );

        bytes32 expectedSalt = keccak256(abi.encode(ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT));
        address predicted = _predict(
            address(bsd),
            expectedSalt,
            address(bsd.iST0xPriceOracleBeacon()),
            abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT))
        );

        ST0xPriceOracle oracle = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT);
        assertEq(address(oracle), predicted, "ST0x proxy must land at keccak256(all-args) CREATE2 address");
    }
}
