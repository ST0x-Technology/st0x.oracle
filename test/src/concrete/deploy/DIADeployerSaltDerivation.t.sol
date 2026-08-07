// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {IDIAOracleV2} from "../../../../src/interface/IDIAOracleV2.sol";
import {DIAVaultOracle, DIAVaultOracleConfig} from "../../../../src/concrete/oracle/DIAVaultOracle.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig
} from "../../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {MockDIAOracle} from "../../../mocks/MockDIAOracle.sol";
import {MockERC4626} from "../../../mocks/MockERC4626.sol";
import {MockCorporateActions} from "../../../mocks/MockCorporateActions.sol";
import {ACTION_TYPE_STOCK_SPLIT_V1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";

/// @title DIADeployerSaltDerivationTest
/// @notice The DIA beacon-set deployer mints proxies with EMPTY init-code
/// (`BeaconProxy(..., "")`), so the CREATE2 salt is the SOLE source of address
/// uniqueness — unlike the Morpho/ST0x deployers whose init-code carries the
/// config. `keccak256(abi.encode(config))` must therefore fold in EVERY config
/// field. These tests independently recompute the CREATE2 address from the whole
/// config and prove that two configs differing in ONLY ONE field (here `symbol`)
/// land at DISTINCT addresses — catching a salt that silently omits a field.
contract DIADeployerSaltDerivationTest is Test {
    DIAVaultOracle internal implementation;
    MockDIAOracle internal diaOracle;
    MockERC4626 internal vault;
    MockCorporateActions internal actions;
    address internal constant BEACON_OWNER = address(0xBEEF);
    uint256 internal constant MAX_AGE = 1 hours;

    function setUp() public {
        implementation = new DIAVaultOracle();
        diaOracle = new MockDIAOracle();
        vault = new MockERC4626();
        actions = new MockCorporateActions();
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

    function _config(string memory symbol) internal view returns (DIAVaultOracleConfig memory) {
        return DIAVaultOracleConfig({
            diaOracle: IDIAOracleV2(address(diaOracle)),
            symbol: symbol,
            vault: address(vault),
            maxAge: MAX_AGE,
            actionTypeMask: ACTION_TYPE_STOCK_SPLIT_V1,
            pauseTimeBefore: 3600,
            pauseTimeAfter: 3600,
            maxRatioDriftPerDayBps: 100
        });
    }

    function _predict(address deployer, bytes32 salt, address beacon) internal pure returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, bytes(""))));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice The deployed DIA proxy MUST land at the CREATE2 address predicted
    /// from `salt = keccak256(abi.encode(config))`. Empty init-code means the
    /// salt is the only thing that moves the address, so this pins the exact
    /// salt formula.
    function testDIASaltIsKeccakWholeConfig() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();
        DIAVaultOracleConfig memory cfg = _config("COIN");

        bytes32 expectedSalt = keccak256(abi.encode(cfg));
        address predicted = _predict(address(bsd), expectedSalt, address(bsd.I_DIA_VAULT_ORACLE_BEACON()));

        DIAVaultOracle oracle = bsd.newDIAVaultOracle(cfg);
        assertEq(address(oracle), predicted, "DIA proxy must land at keccak256(config) CREATE2 address");
    }

    /// @notice Two configs differing in ONLY `symbol` must mint to DISTINCT
    /// addresses. If the salt omits `symbol`, they collide and the second deploy
    /// reverts — this asserts that never happens.
    function testDIASymbolOnlyDifferenceGivesDistinctAddress() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();

        DIAVaultOracle a = bsd.newDIAVaultOracle(_config("COIN"));
        DIAVaultOracle b = bsd.newDIAVaultOracle(_config("AMZN"));

        assertTrue(address(a) != address(b), "symbol-only difference must yield distinct addresses");
        assertEq(a.symbol(), "COIN", "proxy a symbol");
        assertEq(b.symbol(), "AMZN", "proxy b symbol");
    }
}
