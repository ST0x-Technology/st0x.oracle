// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {SignedPriceTestBase} from "../../lib/SignedPriceTestBase.sol";

import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable-5.6.1/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin-contracts-5.6.1/access/IAccessControl.sol";

import {ST0xPriceOracle} from "../../../../src/concrete/oracle/ST0xPriceOracle.sol";

/// @title ST0xPriceOracleTest
/// @notice Unit coverage for the central multi-pair oracle: global signer /
/// timeout config, the strict-timestamp no-op-vs-revert semantics of
/// `updatePrice` (no registration, no nonce), `price()` unset/staleness
/// reverts, and the deterministic `pairId` derivation.
contract ST0xPriceOracleTest is SignedPriceTestBase {
    uint256 constant SIGNER_PK = uint256(keccak256("st0x.price-oracle.signer.test"));
    address SIGNER;

    address constant ADMIN = address(0xC0DE);
    address constant ORACLE_ADMIN = address(0xADDD);
    address constant RANDO = address(0xF00D);

    address constant BASE_TOKEN = address(0xAAA1);
    address constant QUOTE_TOKEN = address(0xBBB2);
    uint64 constant TIMEOUT = 1 hours;

    bytes32 PAIR_A;
    bytes32 constant PAIR_UNKNOWN = keccak256("pair-unknown");

    ST0xPriceOracle oracle;
    UpgradeableBeacon beacon;

    function setUp() public {
        SIGNER = vm.addr(SIGNER_PK);
        // Same shape as production: implementation behind a beacon proxy.
        ST0xPriceOracle impl = new ST0xPriceOracle();
        beacon = new UpgradeableBeacon(address(impl), ADMIN);
        oracle = ST0xPriceOracle(
            address(
                new BeaconProxy(
                    address(beacon), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT))
                )
            )
        );
        // ORACLE_ADMIN receives ORACLE_ADMIN_ROLE atomically at initialize
        // (no separate grant step) — the rotation tests depend on it.
        PAIR_A = oracle.pairId(BASE_TOKEN, QUOTE_TOKEN);
    }

    // -------- pairId: deterministic derivation --------

    /// @notice `pairId` is `keccak256(abi.encodePacked(base, quote))` —
    /// base first, quote second, plain concatenation.
    function test_PairId_IsPackedKeccakBaseThenQuote() public view {
        assertEq(
            oracle.pairId(BASE_TOKEN, QUOTE_TOKEN),
            keccak256(abi.encodePacked(BASE_TOKEN, QUOTE_TOKEN)),
            "packed keccak, base first"
        );
        assertTrue(
            oracle.pairId(BASE_TOKEN, QUOTE_TOKEN) != oracle.pairId(QUOTE_TOKEN, BASE_TOKEN), "order is significant"
        );
    }

    // -------- initialize --------

    function test_Initialize_SetsGlobalsAndEmits() public {
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), ADMIN);
        // Initial values arrive as initialize params but are announced
        // through the same events the setters emit.
        vm.expectEmit();
        emit ST0xPriceOracle.SignerSet(SIGNER);
        vm.expectEmit();
        emit ST0xPriceOracle.TimeoutSet(TIMEOUT);
        ST0xPriceOracle fresh = ST0xPriceOracle(
            address(
                new BeaconProxy(
                    address(b), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT))
                )
            )
        );
        assertEq(fresh.signer(), SIGNER, "global signer set");
        assertEq(fresh.timeout(), TIMEOUT, "global timeout set");
    }

    /// @notice Both roles are granted atomically at initialize — no separate
    /// grant step. ORACLE_ADMIN can rotate config immediately; DEFAULT_ADMIN
    /// cannot (rotation authority is not implicitly the role admin).
    function test_Initialize_GrantsBothRolesAtomically() public {
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), ADMIN), "admin has DEFAULT_ADMIN_ROLE");
        assertTrue(oracle.hasRole(oracle.ORACLE_ADMIN_ROLE(), ORACLE_ADMIN), "oracleAdmin has ORACLE_ADMIN_ROLE");
        assertFalse(oracle.hasRole(oracle.ORACLE_ADMIN_ROLE(), ADMIN), "default admin is not implicitly oracle admin");
        // ORACLE_ADMIN can rotate immediately, with no prior grant tx.
        vm.prank(ORACLE_ADMIN);
        oracle.setTimeout(2 hours);
        assertEq(oracle.timeout(), 2 hours, "oracle admin rotates config at once");
    }

    function test_Initialize_ZeroAdmin_Reverts() public {
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), ADMIN);
        vm.expectRevert(ST0xPriceOracle.ZeroAdmin.selector);
        new BeaconProxy(
            address(b), abi.encodeCall(ST0xPriceOracle.initialize, (address(0), ORACLE_ADMIN, SIGNER, TIMEOUT))
        );
    }

    function test_Initialize_ZeroOracleAdmin_Reverts() public {
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), ADMIN);
        vm.expectRevert(ST0xPriceOracle.ZeroAdmin.selector);
        new BeaconProxy(address(b), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, address(0), SIGNER, TIMEOUT)));
    }

    function test_Initialize_ZeroSigner_Reverts() public {
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), ADMIN);
        vm.expectRevert(ST0xPriceOracle.ZeroSigner.selector);
        new BeaconProxy(
            address(b), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ORACLE_ADMIN, address(0), TIMEOUT))
        );
    }

    function test_Initialize_ZeroTimeout_Reverts() public {
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), ADMIN);
        vm.expectRevert(ST0xPriceOracle.ZeroTimeout.selector);
        new BeaconProxy(address(b), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ORACLE_ADMIN, SIGNER, 0)));
    }

    function test_Initialize_TimeoutTooLarge_Reverts() public {
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), ADMIN);
        uint64 tooLarge = oracle.MAX_TIMEOUT() + 1;
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.TimeoutTooLarge.selector, tooLarge));
        new BeaconProxy(address(b), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ORACLE_ADMIN, SIGNER, tooLarge)));
    }

    function test_Initialize_TimeoutAtMax_Ok() public {
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), ADMIN);
        uint64 atMax = impl.MAX_TIMEOUT();
        ST0xPriceOracle fresh = ST0xPriceOracle(
            address(
                new BeaconProxy(
                    address(b), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ORACLE_ADMIN, SIGNER, atMax))
                )
            )
        );
        assertEq(fresh.timeout(), atMax, "timeout at MAX_TIMEOUT is accepted");
    }

    function test_SetTimeout_Zero_Reverts() public {
        vm.prank(ORACLE_ADMIN);
        vm.expectRevert(ST0xPriceOracle.ZeroTimeout.selector);
        oracle.setTimeout(0);
    }

    function test_SetTimeout_TooLarge_Reverts() public {
        uint64 tooLarge = oracle.MAX_TIMEOUT() + 1;
        vm.prank(ORACLE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.TimeoutTooLarge.selector, tooLarge));
        oracle.setTimeout(tooLarge);
    }

    function test_Initialize_OnlyOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(RANDO, ORACLE_ADMIN, SIGNER, TIMEOUT);
    }

    // -------- updatePrice: applied vs no-op vs revert --------

    /// @notice There is NO pair registration — the very first update on a
    /// brand-new pair just works (stored timestamp starts at 0 and any real
    /// timestamp is strictly newer).
    function test_UpdatePrice_FirstUpdateOnBrandNewPair_AppliesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ST0xPriceOracle.PriceUpdated(PAIR_A, 42e18, block.timestamp);
        bool applied = oracle.updatePrice(
            PAIR_A, 42e18, block.timestamp, signPriceUpdate(oracle, SIGNER_PK, PAIR_A, 42e18, block.timestamp)
        );
        assertTrue(applied, "fresh update should apply");

        (uint256 storedPrice, uint256 storedTs) = oracle.pairPrice(PAIR_A);
        assertEq(storedPrice, 42e18, "price stored");
        assertEq(storedTs, block.timestamp, "timestamp stored");
        assertEq(oracle.price(PAIR_A), 42e18, "price() serves stored value");
    }

    /// @notice A timestamp EQUAL to stored is not strictly newer — a NO-OP,
    /// not a revert: no state change, no event, even with a garbage
    /// signature (freshness is checked before the signature).
    function test_UpdatePrice_EqualTimestamp_NoOpNotRevert() public {
        _push(PAIR_A, 42e18, block.timestamp);

        vm.recordLogs();
        bool applied = oracle.updatePrice(PAIR_A, 99e18, block.timestamp, hex"deadbeef");
        assertFalse(applied, "equal timestamp must be a no-op");
        assertEq(vm.getRecordedLogs().length, 0, "no event on a no-op");

        (uint256 storedPrice, uint256 storedTs) = oracle.pairPrice(PAIR_A);
        assertEq(storedPrice, 42e18, "price unchanged");
        assertEq(storedTs, block.timestamp, "timestamp unchanged");
    }

    /// @notice A timestamp older than stored is equally a NO-OP.
    function test_UpdatePrice_OlderTimestamp_NoOpNotRevert() public {
        vm.warp(block.timestamp + 100);
        _push(PAIR_A, 42e18, block.timestamp);

        vm.recordLogs();
        bool applied = oracle.updatePrice(PAIR_A, 99e18, block.timestamp - 50, hex"deadbeef");
        assertFalse(applied, "older timestamp must be a no-op");
        assertEq(vm.getRecordedLogs().length, 0, "no event on a no-op");

        (uint256 storedPrice, uint256 storedTs) = oracle.pairPrice(PAIR_A);
        assertEq(storedPrice, 42e18, "price unchanged");
        assertEq(storedTs, block.timestamp, "timestamp unchanged");
    }

    /// @notice An invalid signature (checked against the GLOBAL signer) on
    /// a strictly-newer payload is malformed input — that DOES revert.
    function test_UpdatePrice_InvalidSignatureOnFreshTimestamp_Reverts() public {
        uint256 wrongPk = uint256(keccak256("wrong-signer"));
        bytes32 digest = digestFor(oracle, PAIR_A, 42e18, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceUpdateInvalidSignature.selector, PAIR_A));
        oracle.updatePrice(PAIR_A, 42e18, block.timestamp, abi.encodePacked(r, s, v));
    }

    /// @notice `updatePrice` is permissionless — any caller with a validly
    /// signed fresh payload succeeds.
    function test_UpdatePrice_Permissionless() public {
        bytes memory sig = signPriceUpdate(oracle, SIGNER_PK, PAIR_A, 42e18, block.timestamp);
        vm.prank(RANDO);
        assertTrue(oracle.updatePrice(PAIR_A, 42e18, block.timestamp, sig), "rando can push a signed price");
    }

    /// @notice DELIBERATE PROPERTY: with no nonce and an EIP-712 domain
    /// that binds name + version only (no chainId, no verifyingContract),
    /// the exact same signed payload applies on a different chain and a
    /// different oracle deployment — one publisher signature fans out to a
    /// multi-chain deployment.
    function test_UpdatePrice_CrossChainReplay_SameSignatureAppliesOnOtherDeployment() public {
        bytes memory sig = signPriceUpdate(oracle, SIGNER_PK, PAIR_A, 42e18, block.timestamp);
        assertTrue(oracle.updatePrice(PAIR_A, 42e18, block.timestamp, sig), "applies on the home chain");

        // A second deployment (fresh proxy → different verifyingContract)
        // on a different chainId, sharing the global signer.
        vm.chainId(424242);
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), ADMIN);
        ST0xPriceOracle other = ST0xPriceOracle(
            address(
                new BeaconProxy(
                    address(b), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ORACLE_ADMIN, SIGNER, TIMEOUT))
                )
            )
        );
        assertTrue(other.updatePrice(PAIR_A, 42e18, block.timestamp, sig), "same signature replays cross-chain");
        assertEq(other.price(PAIR_A), 42e18, "replayed price served");
    }

    /// @notice A payload timestamped in the FUTURE (ahead of block.timestamp)
    /// must be rejected. Accepting it strands the pair: `price()` computes
    /// `block.timestamp - stored.timestamp`, which underflows (arithmetic
    /// panic) for a future stored timestamp — bricking every consumer read
    /// until wall-clock catches up, and blocking every honest
    /// lower-timestamped update in the meantime. The signer is trusted, but
    /// a clock-skewed / buggy publisher signing `now + delta` is a realistic
    /// operational fault, so the contract must reject it rather than admit
    /// an un-serveable price.
    function test_UpdatePrice_FutureTimestamp_Rejected() public {
        uint256 future = block.timestamp + 1 hours;
        bytes memory sig = signPriceUpdate(oracle, SIGNER_PK, PAIR_A, 42e18, future);
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceFuture.selector, PAIR_A));
        oracle.updatePrice(PAIR_A, 42e18, future, sig);

        // The pair stays unset — nothing was stored, so price() reverts the
        // normal unset revert (NOT an arithmetic panic).
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceUnset.selector, PAIR_A));
        oracle.price(PAIR_A);
    }

    /// @notice The boundary: a payload timestamped at EXACTLY block.timestamp
    /// is not in the future and applies. (`newTimestamp <= block.timestamp`
    /// is the accepted region.)
    function test_UpdatePrice_CurrentTimestamp_Applies() public {
        assertTrue(
            oracle.updatePrice(
                PAIR_A, 42e18, block.timestamp, signPriceUpdate(oracle, SIGNER_PK, PAIR_A, 42e18, block.timestamp)
            ),
            "now is not the future"
        );
        assertEq(oracle.price(PAIR_A), 42e18, "current-timestamp price is servable");
    }

    /// @notice Per-pair isolation: two DISTINCT pairs each keep their own
    /// price and timestamp. A regression that collapses the pair mapping to a
    /// single global slot (or mis-keys writes/reads) would make one pair's
    /// write clobber the other — this test fails under that mutation.
    function test_UpdatePrice_TwoPairs_IsolatedState() public {
        address baseTokenB = address(0xCCC3);
        address quoteTokenB = address(0xDDD4);
        bytes32 pairB = oracle.pairId(baseTokenB, quoteTokenB);
        assertTrue(pairB != PAIR_A, "pairs must be distinct");

        // Distinct prices AND distinct timestamps per pair.
        uint256 tsA = block.timestamp;
        vm.warp(block.timestamp + 7);
        uint256 tsB = block.timestamp;

        _push(PAIR_A, 42e18, tsA);
        _push(pairB, 99e18, tsB);

        // Each pair reads back exactly its own value — not the other's, and
        // not a shared last-write.
        (uint256 priceA, uint256 storedTsA) = oracle.pairPrice(PAIR_A);
        (uint256 priceB, uint256 storedTsB) = oracle.pairPrice(pairB);
        assertEq(priceA, 42e18, "pair A price isolated");
        assertEq(storedTsA, tsA, "pair A timestamp isolated");
        assertEq(priceB, 99e18, "pair B price isolated");
        assertEq(storedTsB, tsB, "pair B timestamp isolated");

        assertEq(oracle.price(PAIR_A), 42e18, "price() serves pair A's own value");
        assertEq(oracle.price(pairB), 99e18, "price() serves pair B's own value");

        // Overwriting pair A with a fresher price must not touch pair B.
        vm.warp(block.timestamp + 7);
        _push(PAIR_A, 43e18, block.timestamp);
        assertEq(oracle.price(PAIR_A), 43e18, "pair A advanced");
        (uint256 priceBAfter, uint256 storedTsBAfter) = oracle.pairPrice(pairB);
        assertEq(priceBAfter, 99e18, "pair B price untouched by pair A write");
        assertEq(storedTsBAfter, tsB, "pair B timestamp untouched by pair A write");
    }

    // -------- constant-derivation pins (convention-vs-enforcement) --------

    /// @notice `DOMAIN_SEPARATOR` is a hardcoded hex literal — pin it to its
    /// normative EIP-712 derivation so a wrong literal can never ship
    /// undetected. Recomputed independently here (not read off the contract).
    function test_DomainSeparator_MatchesNormativeDerivation() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version)"), keccak256("ST0xPriceOracle"), keccak256("1")
            )
        );
        assertEq(oracle.domainSeparator(), expected, "domain separator must equal its EIP-712 derivation");
    }

    /// @notice The `PRICE_UPDATE_TYPEHASH` matches its normative string.
    function test_PriceUpdateTypehash_MatchesNormativeDerivation() public view {
        assertEq(
            oracle.PRICE_UPDATE_TYPEHASH(),
            keccak256("PriceUpdate(bytes32 pairId,uint256 price,uint256 timestamp)"),
            "typehash must equal its EIP-712 struct derivation"
        );
    }

    /// @notice `MAX_TIMEOUT` is the documented 30-day upper bound on the
    /// global staleness `timeout`. Pin the exact value: a widened bound would
    /// silently let `price()` serve staler data than the spec permits, and no
    /// other test asserts it (the range-reject tests read `MAX_TIMEOUT()`
    /// dynamically, so they float with the constant).
    function test_MaxTimeout_IsThirtyDays() public view {
        assertEq(oracle.MAX_TIMEOUT(), 30 days, "MAX_TIMEOUT must be exactly 30 days");
        assertEq(oracle.MAX_TIMEOUT(), 2592000, "30 days in seconds");
    }

    /// @notice `ORACLE_ADMIN_ROLE` is the public role identifier off-chain
    /// tooling and Safe bundles reference. Pin it to its normative
    /// `keccak256("ORACLE_ADMIN")` derivation so a changed role string
    /// (which stays internally consistent and passes every behavioural test)
    /// can never silently break external role grants.
    function test_OracleAdminRole_MatchesNormativeDerivation() public view {
        assertEq(
            oracle.ORACLE_ADMIN_ROLE(),
            keccak256("ORACLE_ADMIN"),
            "ORACLE_ADMIN_ROLE must equal keccak256(\"ORACLE_ADMIN\")"
        );
    }

    /// @notice The ERC-7201 `MainStorage` slot constant is a hardcoded hex
    /// literal with no getter. Pin it to the normative derivation by proving
    /// storage actually lands there: after `initialize`, the first field
    /// (`signer`) must be readable at the recomputed slot.
    function test_MainStorageLocation_MatchesErc7201Derivation() public view {
        bytes32 derived =
            keccak256(abi.encode(uint256(keccak256("st0x.priceoracle.main")) - 1)) & ~bytes32(uint256(0xff));
        // signer is the first member of MainStorage → sits exactly at the slot.
        address storedSigner = address(uint160(uint256(vm.load(address(oracle), derived))));
        assertEq(storedSigner, oracle.signer(), "MainStorage must be namespaced at the ERC-7201 derived slot");
    }

    // -------- price(): unset + staleness --------

    /// @notice A pair either has a stored price or it doesn't — an unset
    /// pair (stored timestamp 0) reverts `PriceUnset`.
    function test_Price_UnsetPair_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceUnset.selector, PAIR_UNKNOWN));
        oracle.price(PAIR_UNKNOWN);
    }

    function test_Price_RevertsWhenPastGlobalTimeout() public {
        _push(PAIR_A, 42e18, block.timestamp);

        vm.warp(block.timestamp + TIMEOUT);
        assertEq(oracle.price(PAIR_A), 42e18, "still fresh at the timeout bound");

        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceStale.selector, PAIR_A));
        oracle.price(PAIR_A);
    }

    // -------- setSigner / setTimeout --------

    /// @notice Rotating the global signer emits `SignerSet`, invalidates
    /// payloads signed by the old key, and honours the new one. Stored
    /// price state is untouched.
    function test_SetSigner_RotatesAndEmits() public {
        _push(PAIR_A, 42e18, block.timestamp);

        uint256 newPk = uint256(keccak256("rotated-signer"));
        address newSigner = vm.addr(newPk);
        vm.expectEmit(address(oracle));
        emit ST0xPriceOracle.SignerSet(newSigner);
        vm.prank(ORACLE_ADMIN);
        oracle.setSigner(newSigner);
        assertEq(oracle.signer(), newSigner, "signer rotated");

        // Old key no longer authorises a fresh payload...
        vm.warp(block.timestamp + 1);
        bytes memory oldKeySig = signPriceUpdate(oracle, SIGNER_PK, PAIR_A, 43e18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceUpdateInvalidSignature.selector, PAIR_A));
        oracle.updatePrice(PAIR_A, 43e18, block.timestamp, oldKeySig);

        // ...the new key does.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newPk, digestFor(oracle, PAIR_A, 43e18, block.timestamp));
        assertTrue(oracle.updatePrice(PAIR_A, 43e18, block.timestamp, abi.encodePacked(r, s, v)), "new key applies");

        // Rotation preserved the previously stored state until then.
        assertEq(oracle.price(PAIR_A), 43e18, "state advanced under the new key");
    }

    function test_SetSigner_RoleGated() public {
        bytes32 oracleAdminRole = oracle.ORACLE_ADMIN_ROLE();
        vm.prank(RANDO);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, RANDO, oracleAdminRole)
        );
        oracle.setSigner(RANDO);
    }

    /// @notice `DEFAULT_ADMIN_ROLE` administers roles only — it does NOT
    /// carry `ORACLE_ADMIN_ROLE`.
    function test_SetSigner_AdminWithoutOracleAdminRole_Reverts() public {
        bytes32 oracleAdminRole = oracle.ORACLE_ADMIN_ROLE();
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, oracleAdminRole)
        );
        oracle.setSigner(RANDO);
    }

    function test_SetSigner_ZeroSigner_Reverts() public {
        vm.prank(ORACLE_ADMIN);
        vm.expectRevert(ST0xPriceOracle.ZeroSigner.selector);
        oracle.setSigner(address(0));
    }

    /// @notice Tightening the global timeout emits `TimeoutSet` and
    /// immediately applies to every pair's `price()`.
    function test_SetTimeout_UpdatesAndEmits() public {
        _push(PAIR_A, 42e18, block.timestamp);
        vm.warp(block.timestamp + 10 minutes);
        assertEq(oracle.price(PAIR_A), 42e18, "fresh under the 1h timeout");

        vm.expectEmit(address(oracle));
        emit ST0xPriceOracle.TimeoutSet(5 minutes);
        vm.prank(ORACLE_ADMIN);
        oracle.setTimeout(5 minutes);
        assertEq(oracle.timeout(), 5 minutes, "timeout updated");

        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceStale.selector, PAIR_A));
        oracle.price(PAIR_A);
    }

    function test_SetTimeout_RoleGated() public {
        bytes32 oracleAdminRole = oracle.ORACLE_ADMIN_ROLE();
        vm.prank(RANDO);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, RANDO, oracleAdminRole)
        );
        oracle.setTimeout(5 minutes);
    }

    // -------- Helpers --------

    function _push(bytes32 id, uint256 price, uint256 timestamp) internal {
        assertTrue(oracle.updatePrice(id, price, timestamp, signPriceUpdate(oracle, SIGNER_PK, id, price, timestamp)));
    }
}
