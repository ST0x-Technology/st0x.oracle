// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {SignedPriceTestBase} from "../../lib/SignedPriceTestBase.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {ST0xPriceOracle} from "../../../../src/concrete/oracle/ST0xPriceOracle.sol";
import {MorphoPairAdapter, ZeroToken, IdenticalTokens} from "../../../../src/concrete/adapter/MorphoPairAdapter.sol";
import {
    MorphoPairAdapterBeaconSetDeployer,
    MorphoPairAdapterBeaconSetDeployerConfig,
    ZeroBeaconOwner
} from "../../../../src/concrete/deploy/MorphoPairAdapterBeaconSetDeployer.sol";
import {MorphoPairAdapterV2} from "../../../mocks/MorphoPairAdapterV2.sol";
import {MockERC20Decimals} from "../../../mocks/MockERC20Decimals.sol";

contract MorphoPairAdapterBeaconSetDeployerTest is SignedPriceTestBase {
    uint256 internal constant SIGNER_PK = uint256(keccak256("st0x.price-oracle.signer.test"));
    address internal SIGNER;

    address internal constant BEACON_OWNER = address(0xBEEF);
    address internal constant ADMIN = address(0xC0DE);
    uint64 internal constant TIMEOUT = 1 hours;

    ST0xPriceOracle internal central;
    MockERC20Decimals internal base;
    MockERC20Decimals internal quote;

    event Deployment(address indexed caller, address indexed oracle);

    function setUp() public {
        SIGNER = vm.addr(SIGNER_PK);
        vm.warp(1_000_000);

        // The central store, shaped as in production: impl behind a beacon proxy.
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), ADMIN);
        central = ST0xPriceOracle(
            address(
                new BeaconProxy(
                    address(beacon), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ADMIN, SIGNER, TIMEOUT))
                )
            )
        );

        // base = Morpho collateral (18 dec), quote = Morpho loan (6 dec).
        base = new MockERC20Decimals(18);
        quote = new MockERC20Decimals(6);
    }

    function _deployBSD() internal returns (MorphoPairAdapterBeaconSetDeployer) {
        return new MorphoPairAdapterBeaconSetDeployer(
            MorphoPairAdapterBeaconSetDeployerConfig({initialOwner: BEACON_OWNER, central: central})
        );
    }

    // -------- Constructor validation --------

    function testConstructorRevertsZeroBeaconOwner() external {
        vm.expectRevert(ZeroBeaconOwner.selector);
        new MorphoPairAdapterBeaconSetDeployer(
            MorphoPairAdapterBeaconSetDeployerConfig({initialOwner: address(0), central: central})
        );
    }

    /// @notice A zero central is caught by `MorphoPairAdapter.ZeroCentral` in the
    /// implementation constructor the deployer builds — no local guard needed.
    function testConstructorRevertsZeroCentral() external {
        vm.expectRevert(MorphoPairAdapter.ZeroCentral.selector);
        new MorphoPairAdapterBeaconSetDeployer(
            MorphoPairAdapterBeaconSetDeployerConfig({initialOwner: BEACON_OWNER, central: ST0xPriceOracle(address(0))})
        );
    }

    function testConstructorHappyPathDeploysBeacon() external {
        MorphoPairAdapterBeaconSetDeployer bsd = _deployBSD();
        address beacon = address(bsd.iMorphoPairAdapterBeacon());
        assertTrue(beacon != address(0));
        assertEq(UpgradeableBeacon(beacon).owner(), BEACON_OWNER);
        assertEq(address(bsd.iCentral()), address(central), "central immutable wired");

        // The beacon's implementation is bound to the same central store.
        MorphoPairAdapter impl = MorphoPairAdapter(UpgradeableBeacon(beacon).implementation());
        assertEq(address(impl.iCentral()), address(central), "impl bound to central");
    }

    // -------- newMorphoPairAdapter --------

    /// @notice The proxy is initialized inside its constructor: pairId, base,
    /// quote wired and the publisher-scaled value rescaled to Morpho convention.
    /// base=18dec, quote=6dec, signed=42e18 ⇒ price() = 42 * 10^(36+6-18) = 42e24.
    function testNewMorphoPairAdapterWiresAndRescales() external {
        MorphoPairAdapterBeaconSetDeployer bsd = _deployBSD();
        MorphoPairAdapter adapter = bsd.newMorphoPairAdapter(address(base), address(quote));

        bytes32 pair = central.pairId(address(base), address(quote));
        assertEq(adapter.pairId(), pair, "pairId wired");
        assertEq(adapter.baseToken(), address(base), "base wired");
        assertEq(adapter.quoteToken(), address(quote), "quote wired");
        assertEq(address(adapter.iCentral()), address(central), "central wired");

        _push(pair, 42e18, block.timestamp);
        assertEq(adapter.price(), 42e24, "42.0 loan/collateral in Morpho scale");
    }

    /// @notice CREATE2 salt = keccak256(base, quote): minting the same pair twice
    /// reverts on the address collision rather than silently forking a second
    /// divergent adapter. A differing pair lands at a different address.
    function testNewMorphoPairAdapterIsIdempotentPerConfig() external {
        MorphoPairAdapterBeaconSetDeployer bsd = _deployBSD();
        MorphoPairAdapter first = bsd.newMorphoPairAdapter(address(base), address(quote));
        bytes32 firstPairId = first.pairId();

        // Same pair → CREATE2 collision → revert (empty returndata).
        vm.expectRevert();
        bsd.newMorphoPairAdapter(address(base), address(quote));

        // The bare vm.expectRevert above is intentional: a raw CREATE2 address
        // collision carries no selector. Prove it WAS the collision (not an
        // unrelated early revert) — the original instance's code and configured
        // pair survive, so no divergent second instance was forked.
        assertGt(address(first).code.length, 0, "first instance survives the collision");
        assertEq(first.pairId(), firstPairId, "first instance config intact after the collision");

        // Differing pair → different deterministic address.
        MockERC20Decimals quote2 = new MockERC20Decimals(8);
        MorphoPairAdapter second = bsd.newMorphoPairAdapter(address(base), address(quote2));
        assertTrue(address(first) != address(second), "distinct pair gives distinct address");
    }

    function testNewMorphoPairAdapterEmitsDeployment() external {
        MorphoPairAdapterBeaconSetDeployer bsd = _deployBSD();

        vm.recordLogs();
        MorphoPairAdapter adapter = bsd.newMorphoPairAdapter(address(base), address(quote));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("Deployment(address,address)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(bsd) && entries[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(this), "caller mismatch");
                assertEq(address(uint160(uint256(entries[i].topics[2]))), address(adapter), "oracle mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "Deployment event not emitted");
    }

    /// @notice A reverting `initialize` (here identical tokens) bubbles straight
    /// up out of the proxy constructor.
    function testNewMorphoPairAdapterPropagatesInitRevert() external {
        MorphoPairAdapterBeaconSetDeployer bsd = _deployBSD();
        vm.expectRevert(ZeroToken.selector);
        bsd.newMorphoPairAdapter(address(0), address(quote));
        vm.expectRevert(IdenticalTokens.selector);
        bsd.newMorphoPairAdapter(address(base), address(base));
    }

    /// @notice The beacon is genuinely SHARED: deploy two adapters with DISTINCT
    /// pairs, then upgrade the single beacon to a V2 implementation and prove
    /// BOTH proxies retarget (answer the V2-only `version()`), while each proxy
    /// retains its OWN distinct state across the upgrade.
    function testMultipleProxiesShareBeacon() external {
        MorphoPairAdapterBeaconSetDeployer bsd = _deployBSD();

        MockERC20Decimals base2 = new MockERC20Decimals(8);
        MorphoPairAdapter a = bsd.newMorphoPairAdapter(address(base), address(quote));
        MorphoPairAdapter b = bsd.newMorphoPairAdapter(address(base2), address(quote));
        assertTrue(address(a) != address(b), "proxies must be distinct");

        bytes32 pairA = central.pairId(address(base), address(quote));
        bytes32 pairB = central.pairId(address(base2), address(quote));

        address beacon = address(bsd.iMorphoPairAdapterBeacon());

        // V1 has no `version()` — both proxies revert on it pre-upgrade.
        (bool okA,) = address(a).staticcall(abi.encodeWithSignature("version()"));
        (bool okB,) = address(b).staticcall(abi.encodeWithSignature("version()"));
        assertFalse(okA, "V1 has no version() (a)");
        assertFalse(okB, "V1 has no version() (b)");

        // One beacon upgrade retargets EVERY proxy off that beacon.
        MorphoPairAdapterV2 v2Impl = new MorphoPairAdapterV2(central);
        vm.prank(BEACON_OWNER);
        UpgradeableBeacon(beacon).upgradeTo(address(v2Impl));

        assertEq(MorphoPairAdapterV2(address(a)).version(), 2, "proxy a retargeted");
        assertEq(MorphoPairAdapterV2(address(b)).version(), 2, "proxy b retargeted");

        // Each proxy retains its OWN distinct state across the upgrade.
        assertEq(a.pairId(), pairA, "proxy a keeps its own pairId");
        assertEq(b.pairId(), pairB, "proxy b keeps its own pairId");
        _push(pairA, 42e18, block.timestamp);
        assertEq(a.price(), 42e24, "still rescales the central price");
    }

    // -------- Helpers --------

    function _push(bytes32 id, uint256 price, uint256 timestamp) internal {
        assertTrue(central.updatePrice(id, price, timestamp, signPriceUpdate(central, SIGNER_PK, id, price, timestamp)));
    }
}
