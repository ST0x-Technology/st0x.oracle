// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, stdError} from "forge-std-1.16.1/src/Test.sol";

import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable-5.6.1/proxy/utils/Initializable.sol";

import {ST0xPriceOracle} from "../../../../src/concrete/oracle/ST0xPriceOracle.sol";
import {MorphoPairAdapter, ZeroToken, IdenticalTokens} from "../../../../src/concrete/adapter/MorphoPairAdapter.sol";
import {MorphoPairAdapterV2} from "../../../mocks/MorphoPairAdapterV2.sol";
import {MockERC20Decimals} from "../../../mocks/MockERC20Decimals.sol";

/// @title MorphoPairAdapterTest
/// @notice Unit coverage for the `MorphoPairAdapter` beacon-proxied adapter:
/// the publisher-scale → Morpho-convention rescale (known-answer), central
/// staleness/unset passthrough, constructor / initializer guards, and the
/// shared beacon upgrade retargeting every deployed adapter proxy at once.
contract MorphoPairAdapterTest is Test {
    uint256 constant SIGNER_PK = uint256(keccak256("st0x.price-oracle.signer.test"));
    address SIGNER;

    address constant ADMIN = address(0xC0DE);
    uint64 constant TIMEOUT = 1 hours;

    // base = Morpho collateral (18 dec), quote = Morpho loan (6 dec, USDC-like).
    MockERC20Decimals base;
    MockERC20Decimals quote;
    bytes32 PAIR_A;

    ST0xPriceOracle oracle;
    UpgradeableBeacon adapterBeacon;

    function setUp() public {
        SIGNER = vm.addr(SIGNER_PK);
        // Same shape as production: implementation behind a beacon proxy.
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), ADMIN);
        oracle = ST0xPriceOracle(
            address(
                new BeaconProxy(
                    address(beacon), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ADMIN, SIGNER, TIMEOUT))
                )
            )
        );

        // The adapter beacon, shared by every MorphoPairAdapter proxy.
        MorphoPairAdapter adapterImpl = new MorphoPairAdapter(oracle);
        adapterBeacon = new UpgradeableBeacon(address(adapterImpl), ADMIN);

        base = new MockERC20Decimals(18);
        quote = new MockERC20Decimals(6);
        PAIR_A = oracle.pairId(address(base), address(quote));
    }

    /// @notice Known-answer scale test. Publisher signs an 18-dp whole-token
    /// ratio; the adapter must return Morpho's `1e36 * 10^loanDec / 10^collDec`
    /// value. base=18dec (collateral), quote=6dec (loan), signed = 42e18 (42.0
    /// loan per collateral) ⇒ price() = 42 * 10^(36 + 6 - 18) = 42e24.
    function test_MorphoPairAdapter_RescalesToMorphoConvention() public {
        MorphoPairAdapter adapter = _deployAdapter(address(base), address(quote));
        assertEq(adapter.pairId(), PAIR_A, "pairId wired");
        assertEq(adapter.baseToken(), address(base), "base wired");
        assertEq(adapter.quoteToken(), address(quote), "quote wired");

        _push(PAIR_A, 42e18, block.timestamp);
        assertEq(adapter.price(), 42e24, "42.0 loan/collateral in Morpho scale");
    }

    /// @notice A pair with equal base/quote decimals leaves the value at the
    /// bare 1e36 Morpho scale: signed 1e18 (1.0) ⇒ price() = 1e36.
    function test_MorphoPairAdapter_EqualDecimals_BareScale() public {
        MockERC20Decimals base18 = new MockERC20Decimals(18);
        MockERC20Decimals quote18 = new MockERC20Decimals(18);
        MorphoPairAdapter adapter = _deployAdapter(address(base18), address(quote18));
        bytes32 id = oracle.pairId(address(base18), address(quote18));
        _push(id, 1e18, block.timestamp);
        assertEq(adapter.price(), 1e36, "1.0 at equal decimals is bare 1e36");
    }

    /// @notice Central staleness / unset reverts pass straight through the
    /// rescale — the adapter never masks them.
    function test_MorphoPairAdapter_CentralRevertsPassThrough() public {
        MorphoPairAdapter adapter = _deployAdapter(address(base), address(quote));

        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceUnset.selector, PAIR_A));
        adapter.price();

        _push(PAIR_A, 42e18, block.timestamp);
        vm.warp(block.timestamp + TIMEOUT + 1);
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceStale.selector, PAIR_A));
        adapter.price();
    }

    function test_MorphoPairAdapter_ZeroCentral_Reverts() public {
        vm.expectRevert(MorphoPairAdapter.ZeroCentral.selector);
        new MorphoPairAdapter(ST0xPriceOracle(address(0)));
    }

    function test_MorphoPairAdapter_ZeroToken_Reverts() public {
        vm.expectRevert(ZeroToken.selector);
        _deployAdapter(address(0), address(quote));
        vm.expectRevert(ZeroToken.selector);
        _deployAdapter(address(base), address(0));
    }

    function test_MorphoPairAdapter_IdenticalTokens_Reverts() public {
        vm.expectRevert(IdenticalTokens.selector);
        _deployAdapter(address(base), address(base));
    }

    /// @notice Fail-closed at init: a quote (loan) token with absurdly large
    /// `decimals()` makes `scaleNumerator = 10 ** (36 + quoteDecimals)`
    /// overflow uint256, reverting init with an arithmetic panic rather than
    /// minting an always-reverting adapter. The boundary is `quoteDecimals >=
    /// 42` (`10^78 > 2^256`); pins the NatSpec "fail-closed" safety claim.
    function test_MorphoPairAdapter_AbsurdQuoteDecimals_RevertsAtInit() public {
        MockERC20Decimals hugeQuote = new MockERC20Decimals(42);
        vm.expectRevert(stdError.arithmeticError);
        _deployAdapter(address(base), address(hugeQuote));
    }

    /// @notice Fail-closed at init on the denominator side: a base (collateral)
    /// token with absurdly large `decimals()` makes `scaleDenominator = 10 **
    /// (baseDecimals + 18)` overflow uint256. The boundary is `baseDecimals >=
    /// 60` (`10^78 > 2^256`).
    function test_MorphoPairAdapter_AbsurdBaseDecimals_RevertsAtInit() public {
        MockERC20Decimals hugeBase = new MockERC20Decimals(60);
        vm.expectRevert(stdError.arithmeticError);
        _deployAdapter(address(hugeBase), address(quote));
    }

    /// @notice Rounding-direction pin (#265). When the net Morpho exponent is
    /// negative the rescale divides, and `Math.mulDiv` MUST floor (round DOWN)
    /// — the conservative direction for a Morpho collateral price. base=30dec
    /// (collateral), quote=6dec (loan) ⇒ net exponent 36 + 6 - 30 - 18 = -6, so
    /// price() = floor(central / 1e6). A non-divisible central value that would
    /// give 1 flooring vs 2 ceiling discriminates the direction.
    function test_MorphoPairAdapter_PriceFloorsDown() public {
        MockERC20Decimals base30 = new MockERC20Decimals(30);
        MorphoPairAdapter adapter = _deployAdapter(address(base30), address(quote));
        bytes32 id = oracle.pairId(address(base30), address(quote));
        // 1_999_999 / 1e6 = 1.999999 → floors to 1 (ceil would be 2).
        _push(id, 1_999_999, block.timestamp);
        assertEq(adapter.price(), 1, "mulDiv must floor (round DOWN), not ceil");
    }

    function test_MorphoPairAdapter_InitializeOnlyOnce() public {
        MorphoPairAdapter adapter = _deployAdapter(address(base), address(quote));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapter.initialize(address(base), address(quote));
    }

    function test_MorphoPairAdapter_ImplementationInitializersDisabled() public {
        MorphoPairAdapter impl = new MorphoPairAdapter(oracle);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(base), address(quote));
    }

    /// @notice The `MainStorage` slot constant is a hardcoded hex literal.
    /// Pin it to the ERC-7201 derivation: after init, the first field
    /// (`baseToken`) must be readable at the recomputed slot.
    function test_MorphoPairAdapter_MainStorageLocationMatchesErc7201Derivation() public {
        MorphoPairAdapter adapter = _deployAdapter(address(base), address(quote));
        bytes32 derived =
            keccak256(abi.encode(uint256(keccak256("st0x.morphopairadapter.main")) - 1)) & ~bytes32(uint256(0xff));
        address storedBase = address(uint160(uint256(vm.load(address(adapter), derived))));
        assertEq(storedBase, adapter.baseToken(), "MainStorage must be at the ERC-7201 derived slot");
    }

    /// @notice One shared-beacon upgrade retargets EVERY deployed adapter
    /// proxy at once, with per-proxy state and the implementation immutable
    /// (`iCentral`) surviving the upgrade.
    function test_MorphoPairAdapter_BeaconUpgradeRetargetsAllProxies() public {
        MockERC20Decimals base2 = new MockERC20Decimals(8);
        MorphoPairAdapter adapterA = _deployAdapter(address(base), address(quote));
        MorphoPairAdapter adapterB = _deployAdapter(address(base2), address(quote));
        bytes32 pairB = oracle.pairId(address(base2), address(quote));

        // V1 has no `version()` — both proxies revert on it pre-upgrade.
        (bool okBefore,) = address(adapterA).staticcall(abi.encodeWithSignature("version()"));
        assertFalse(okBefore, "V1 has no version()");

        // One beacon upgrade...
        MorphoPairAdapterV2 v2Impl = new MorphoPairAdapterV2(oracle);
        vm.prank(ADMIN);
        adapterBeacon.upgradeTo(address(v2Impl));

        // ...retargets ALL deployed adapters.
        assertEq(MorphoPairAdapterV2(address(adapterA)).version(), 2, "adapter A retargeted");
        assertEq(MorphoPairAdapterV2(address(adapterB)).version(), 2, "adapter B retargeted");

        // Per-proxy state survives the upgrade and forwarding still works.
        assertEq(adapterA.pairId(), PAIR_A, "adapter A proxy state intact");
        assertEq(adapterB.pairId(), pairB, "adapter B proxy state intact");
        assertEq(address(adapterA.iCentral()), address(oracle), "central immutable intact");
        _push(PAIR_A, 42e18, block.timestamp);
        assertEq(adapterA.price(), 42e24, "still rescales the central price");

        // Known-answer for the only 8-dec-collateral / 6-dec-loan pair in the
        // suite. Publisher signs the whole-token ratio 42.0 as 42e18; the
        // adapter rescales by num/denom = 10^(36+6) / 10^(8+18), so
        // price() = 42e18 * 10^42 / 10^26 = 42 * 10^34. Catches an exponent
        // sign error that only shows when baseDecimals is neither 18 nor equal
        // to quoteDecimals.
        _push(pairB, 42e18, block.timestamp);
        assertEq(adapterB.price(), 42 * 10 ** 34, "8-dec collateral / 6-dec loan rescale");
    }

    // -------- Helpers --------

    function _deployAdapter(address baseToken, address quoteToken) internal returns (MorphoPairAdapter) {
        return MorphoPairAdapter(
            address(
                new BeaconProxy(
                    address(adapterBeacon), abi.encodeCall(MorphoPairAdapter.initialize, (baseToken, quoteToken))
                )
            )
        );
    }

    function _digest(bytes32 id, uint256 price, uint256 timestamp) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(oracle.PRICE_UPDATE_TYPEHASH(), id, price, timestamp));
        return keccak256(abi.encodePacked("\x19\x01", oracle.domainSeparator(), structHash));
    }

    function _sign(bytes32 id, uint256 price, uint256 timestamp) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, _digest(id, price, timestamp));
        return abi.encodePacked(r, s, v);
    }

    function _push(bytes32 id, uint256 price, uint256 timestamp) internal {
        assertTrue(oracle.updatePrice(id, price, timestamp, _sign(id, price, timestamp)));
    }
}
