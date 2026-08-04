// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Initializable} from "@openzeppelin-contracts-upgradeable-5.6.1/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-contracts-upgradeable-5.6.1/access/AccessControlUpgradeable.sol";
import {ECDSA} from "@openzeppelin-contracts-5.6.1/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin-contracts-5.6.1/utils/cryptography/MessageHashUtils.sol";

/// @title ST0xPriceOracle
/// @notice Singleton multi-pair price store. Lives behind a beacon proxy:
/// Initializable + AccessControl with ERC-7201 namespaced storage.
///
/// There is NO pair registration: a pair either has a stored price or it
/// doesn't. Pair ids are deterministic —
/// `keccak256(abi.encodePacked(baseToken, quoteToken))`, exposed as the
/// `pairId` pure helper — and the first `updatePrice` on a brand-new pair
/// simply works. The publisher key (`signer`) and the staleness bound
/// (`timeout`) are GLOBAL, shared by every pair, and rotated via two
/// separate role-gated setters (separate functions deliberately, so a
/// signer rotation can never race a timeout change in one calldata blob).
///
/// Price VALUES are opaque `uint256`s: scaling and semantics belong
/// entirely to the publisher / consumer of each pair. Each pair's publisher
/// decides what its values mean; this contract never interprets them.
///
/// `updatePrice` is PERMISSIONLESS — the global publisher's EIP-712
/// signature is what authorises an update, not the caller. Replay
/// protection is the STRICT per-pair timestamp inequality: an update
/// applies only if its timestamp is strictly newer than the stored one. A
/// not-strictly-newer payload is a NO-OP that returns `false` rather than a
/// revert, so callers may push a signed price in the same transaction that
/// consumes it without risking a brick on a lost race. An invalid signature
/// on an otherwise-fresh payload is malformed input and reverts.
///
/// CROSS-CHAIN REPLAY IS DELIBERATE: the EIP-712 domain binds name +
/// version ONLY — no chainId, no verifyingContract — and there is no nonce,
/// so the same signed price payload is valid on every deployment sharing
/// the global signer. One publisher signature fans out to every chain the
/// oracle is deployed on; that is a feature for multi-chain deployment, not
/// an oversight. NOTE the precondition: because `pairId` binds the base and
/// quote token ADDRESSES (`keccak256(abi.encodePacked(baseToken,
/// quoteToken))`), a signature only replays to deployments where the pair's
/// token addresses are IDENTICAL (e.g. deterministic CREATE2 addresses).
/// Pairs whose token addresses differ per chain resolve to different
/// `pairId`s and therefore require a per-chain signature; a publisher must
/// not assume one signature covers a pair whose addresses vary by chain.
///
/// Roles:
///  - `DEFAULT_ADMIN_ROLE` — role administration only (granted to `admin`
///    at `initialize`).
///  - `ORACLE_ADMIN_ROLE` — `setSigner` / `setTimeout`.
contract ST0xPriceOracle is Initializable, AccessControlUpgradeable {
    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN");

    /// @notice Upper bound on the global staleness `timeout`. A value larger
    /// than this is a misconfiguration (e.g. a milliseconds figure) that would
    /// silently disable staleness protection — reject it rather than let
    /// `price()` serve arbitrarily old values.
    uint64 public constant MAX_TIMEOUT = 30 days;

    /// @notice EIP-712 typehash binding (pairId, price, timestamp). No
    /// nonce — replay protection is the strict timestamp inequality in
    /// `updatePrice`.
    bytes32 public constant PRICE_UPDATE_TYPEHASH =
        keccak256("PriceUpdate(bytes32 pairId,uint256 price,uint256 timestamp)");

    /// @dev The EIP-712 domain separator. The domain deliberately omits
    /// chainId and verifyingContract so a signed price replays across every
    /// chain / deployment (see contract NatSpec):
    /// keccak256(abi.encode(
    ///     keccak256("EIP712Domain(string name,string version)"),
    ///     keccak256("ST0xPriceOracle"),
    ///     keccak256("1")
    /// ))
    bytes32 private constant DOMAIN_SEPARATOR = 0x661a9d4f8ddbbd7ecb90573d81a96060fc99c958049c913cf71722ddcc8ddd48;

    /// @dev Latest accepted price state for one pair.
    struct PricePoint {
        uint256 price;
        uint256 timestamp;
    }

    /// @custom:storage-location erc7201:st0x.priceoracle.main
    struct MainStorage {
        // ---- global configuration (setSigner / setTimeout) ----
        // Publisher key whose ECDSA signature authorises every price update.
        address signer;
        // Maximum allowed staleness on `price()` before it reverts.
        uint64 timeout;
        // ---- per-pair price state (updatePrice) ----
        mapping(bytes32 pairId => PricePoint) prices;
    }

    // keccak256(abi.encode(uint256(keccak256("st0x.priceoracle.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MAIN_STORAGE_LOCATION = 0x8bea1968915949cd5f395bf014546362fbf876c96d338f9e38ecadb2c70bcf00;

    function _main() private pure returns (MainStorage storage $) {
        assembly ("memory-safe") {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    error ZeroAdmin();
    error ZeroSigner();
    /// @dev Raised when a zero `timeout` is set — it would make `price()`
    /// revert `PriceStale` for every reading past its own block, bricking the
    /// oracle. Mirrors the DIA stack's `ZeroMaxAge`.
    error ZeroTimeout();
    /// @dev Raised when a `timeout` above `MAX_TIMEOUT` is set.
    /// @param timeout The rejected timeout value.
    error TimeoutTooLarge(uint64 timeout);
    error PriceUnset(bytes32 pairId);
    error PriceStale(bytes32 pairId);
    error PriceFuture(bytes32 pairId);
    /// @dev Raised when a signed update carries a zero `price`. A zero is the
    /// uninitialized default of the signing pipeline and, if served, values a
    /// pair at nothing downstream (e.g. Morpho collateral priced at zero).
    /// Rejected at the update boundary, symmetric with the other
    /// degenerate-value guards, per the fail-closed rule.
    /// @param pairId The pair whose update carried a zero price.
    error PriceZero(bytes32 pairId);
    error PriceUpdateInvalidSignature(bytes32 pairId);

    event SignerSet(address indexed signer);
    event TimeoutSet(uint64 timeout);
    event PriceUpdated(bytes32 indexed pairId, uint256 price, uint256 timestamp);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the singleton. `admin` receives
    /// `DEFAULT_ADMIN_ROLE` (role administration only) and `oracleAdmin`
    /// receives `ORACLE_ADMIN_ROLE` (signer/timeout rotation) — both granted
    /// atomically so no post-deploy "remember to grant the role" step exists.
    /// A missing grant would leave `setSigner` uncallable, blocking an
    /// emergency key rotation behind the `DEFAULT_ADMIN` multisig while the
    /// compromised signer's permissionless payloads keep landing. The initial
    /// global signer and timeout are set here and announced through the same
    /// events the setters emit.
    /// @param admin Receives `DEFAULT_ADMIN_ROLE`. Cannot be zero.
    /// @param oracleAdmin Receives `ORACLE_ADMIN_ROLE`. Cannot be zero (may be
    /// the same address as `admin` if a single multisig holds both).
    /// @param signer_ The initial global publisher key. Cannot be zero.
    /// @param timeout_ The initial global staleness bound. `(0, MAX_TIMEOUT]`.
    function initialize(address admin, address oracleAdmin, address signer_, uint64 timeout_) external initializer {
        if (admin == address(0) || oracleAdmin == address(0)) revert ZeroAdmin();
        if (signer_ == address(0)) revert ZeroSigner();
        _validateTimeout(timeout_);
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ADMIN_ROLE, oracleAdmin);

        MainStorage storage $ = _main();
        $.signer = signer_;
        $.timeout = timeout_;
        emit SignerSet(signer_);
        emit TimeoutSet(timeout_);
    }

    // ------------------------------------------------------------------ //
    //                        Global configuration                        //
    // ------------------------------------------------------------------ //

    /// @notice Rotate the GLOBAL publisher key. Deliberately a separate
    /// function from `setTimeout` so the two config axes can never race
    /// each other inside one calldata blob.
    function setSigner(address newSigner) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroSigner();
        _main().signer = newSigner;
        emit SignerSet(newSigner);
    }

    /// @notice Set the GLOBAL staleness bound applied by `price()`. Bounded to
    /// `(0, MAX_TIMEOUT]` — zero bricks every read, and an over-large value
    /// silently disables staleness.
    function setTimeout(uint64 newTimeout) external onlyRole(ORACLE_ADMIN_ROLE) {
        _validateTimeout(newTimeout);
        _main().timeout = newTimeout;
        emit TimeoutSet(newTimeout);
    }

    /// @dev Reverts `ZeroTimeout` / `TimeoutTooLarge` for out-of-range values.
    function _validateTimeout(uint64 newTimeout) private pure {
        if (newTimeout == 0) revert ZeroTimeout();
        if (newTimeout > MAX_TIMEOUT) revert TimeoutTooLarge(newTimeout);
    }

    // ------------------------------------------------------------------ //
    //                            Price updates                           //
    // ------------------------------------------------------------------ //

    /// @notice The canonical pair id: base token first, quote token second,
    /// plain concatenation. Deterministic — no registration step exists;
    /// consumers and publishers derive the same id independently.
    function pairId(address baseToken, address quoteToken) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseToken, quoteToken));
    }

    /// @notice Push a signed price for a pair. Open — anyone may submit;
    /// the global publisher's EIP-712 signature over
    /// (pairId, price, timestamp) is what authorises. No registration is
    /// required: the first update on a brand-new pair works as-is.
    /// @return applied `true` if the update was strictly newer and was
    /// stored (a `PriceUpdated` event was emitted); `false` if the payload
    /// was not strictly newer than the stored timestamp — a deliberate
    /// NO-OP, so a lost update race can never revert a surrounding call. A
    /// strictly-newer payload timestamped in the FUTURE (`> block.timestamp`)
    /// reverts `PriceFuture` — it would strand `price()` behind an arithmetic
    /// underflow. A strictly-newer payload carrying a zero `price` reverts
    /// `PriceZero`. An invalid signature on a strictly-newer payload is
    /// malformed input and reverts `PriceUpdateInvalidSignature`; the
    /// signature is verified before the future/zero content checks, so an
    /// unauthenticated payload always reverts the signature error.
    function updatePrice(bytes32 id, uint256 newPrice, uint256 newTimestamp, bytes calldata signature)
        external
        returns (bool applied)
    {
        MainStorage storage $ = _main();
        PricePoint storage stored = $.prices[id];

        // Not strictly newer → no-op, not a revert. Checked BEFORE the
        // signature so stale replays are cheap and never brick a caller.
        if (newTimestamp <= stored.timestamp) {
            return false;
        }

        // Verify the publisher signature BEFORE any content validation of the
        // payload, so an unauthenticated payload always reverts
        // `PriceUpdateInvalidSignature` — never a content-check selector
        // (`PriceFuture` / `PriceZero`) that would misreport an unsigned probe
        // as an operator/clock fault to off-chain monitoring. The stale/no-op
        // short-circuit above stays first: it is intentionally cheap and
        // signature-free so a lost update race can never brick a caller.
        bytes32 structHash = keccak256(abi.encode(PRICE_UPDATE_TYPEHASH, id, newPrice, newTimestamp));
        if (ECDSA.recover(MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash), signature) != $.signer) {
            revert PriceUpdateInvalidSignature(id);
        }

        // A future timestamp is out-of-model input: `price()` computes
        // `block.timestamp - stored.timestamp`, which would underflow (revert
        // with an arithmetic panic) for any stored timestamp ahead of the
        // block clock — stranding the pair for every consumer until wall-clock
        // catches up, and blocking every honest lower-timestamped update in
        // between. Reject it rather than admit an un-serveable price. Miner
        // drift on block.timestamp only moves the accept/reject boundary by
        // seconds and cannot forge a signature, so the comparison is safe.
        // slither-disable-next-line timestamp
        if (newTimestamp > block.timestamp) {
            revert PriceFuture(id);
        }

        // A zero price is the uninitialized default of the signing pipeline;
        // serving it would value the pair at nothing downstream. Reject it,
        // symmetric with the future-timestamp guard.
        if (newPrice == 0) {
            revert PriceZero(id);
        }

        stored.price = newPrice;
        stored.timestamp = newTimestamp;
        emit PriceUpdated(id, newPrice, newTimestamp);
        return true;
    }

    // ------------------------------------------------------------------ //
    //                            Read views                              //
    // ------------------------------------------------------------------ //

    /// @notice The stored price for a pair. Reverts `PriceUnset` when no
    /// update has ever landed (stored timestamp 0) and `PriceStale` when
    /// the stored timestamp has aged past the global `timeout`. Value
    /// semantics are the publisher's — this contract treats them as opaque.
    function price(bytes32 id) external view returns (uint256) {
        MainStorage storage $ = _main();
        PricePoint storage stored = $.prices[id];
        if (stored.timestamp == 0) revert PriceUnset(id);
        // Staleness is measured against block time by design — miner drift
        // is seconds against a timeout measured in minutes/hours.
        // slither-disable-next-line timestamp
        if (block.timestamp - stored.timestamp > $.timeout) revert PriceStale(id);
        return stored.price;
    }

    /// @notice The global publisher key.
    function signer() external view returns (address) {
        return _main().signer;
    }

    /// @notice The global staleness bound applied by `price()`.
    function timeout() external view returns (uint64) {
        return _main().timeout;
    }

    /// @notice Raw stored price state (no staleness check) — for publishers
    /// sizing their next timestamp and for off-chain monitoring.
    function pairPrice(bytes32 id) external view returns (uint256 storedPrice, uint256 storedTimestamp) {
        PricePoint storage stored = _main().prices[id];
        return (stored.price, stored.timestamp);
    }

    /// @notice EIP-712 domain separator — used by publishers / tests. A
    /// constant: the domain binds name + version only, so signed payloads
    /// replay across chains and deployments by design.
    function domainSeparator() external pure returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }
}
