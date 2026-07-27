// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Initializable} from "@openzeppelin-contracts-upgradeable-5.6.1/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin-contracts-5.6.1/interfaces/IERC20Metadata.sol";
import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";

import {IOracle} from "../../interface/IOracle.sol";
import {ST0xPriceOracle} from "../oracle/ST0xPriceOracle.sol";

/// @dev Error raised when a zero address is provided for a pair token.
error ZeroToken();

/// @dev Error raised when the base and quote token are the same address. A
/// pair prices one token in terms of a different one; an identical pair is a
/// configuration error.
error IdenticalTokens();

/// @title MorphoPairAdapter
/// @notice Beacon-proxied adapter binding one Morpho Blue market to one pair
/// on the central `ST0xPriceOracle`, converting the central store's
/// publisher-scaled value into Morpho Blue's `price()` convention.
///
/// # The scale contract (cross-repo)
///
/// `ST0xPriceOracle` treats stored values as opaque — scaling belongs to the
/// publisher/consumer of each pair. This adapter fixes that convention for
/// its markets: the off-chain publisher MUST sign, for `pairId(base, quote)`,
/// the price of one whole `base` (Morpho *collateral*) token denominated in
/// whole `quote` (Morpho *loan*) tokens, scaled to `PUBLISHER_DECIMALS`
/// (1e18). This constant is the explicit, versioned contract the separate
/// publisher repo must honour — the previous "forward the opaque value
/// verbatim" behaviour left the 36-decimal Morpho invariant as an unpinned
/// social agreement across three parties.
///
/// # Morpho Blue's convention
///
/// `IOracle.price()` must return the price of one collateral token in loan
/// token, scaled by `1e36 * 10^loanDecimals / 10^collateralDecimals`. With
/// `base` = collateral and `quote` = loan, and the publisher signing an
/// 18-decimal whole-token ratio `signed`:
///
///   price() = signed * 10^(36 + quoteDecimals - baseDecimals - 18)
///           = mulDiv(signed, 10^(36 + quoteDecimals), 10^(baseDecimals + 18))
///
/// The numerator/denominator form keeps both exponents non-negative and does
/// the division last (no precision loss beyond the final integer floor). Both
/// scale factors are precomputed once at `initialize` from the tokens'
/// on-chain `decimals()` and stored, so `price()` is a single `mulDiv`.
///
/// Every market's adapter is a `BeaconProxy` over one shared
/// `UpgradeableBeacon`, so a single beacon upgrade retargets all deployed
/// adapters at once. The central oracle address is an implementation immutable
/// (chain-constant, shared by every proxy); per-market state is namespaced
/// ERC-7201 storage set once in `initialize`.
contract MorphoPairAdapter is Initializable, IOracle {
    /// @notice The decimal scale the off-chain publisher MUST sign every price
    /// for a MorphoPairAdapter pair at: `signed = wholeQuotePerWholeBase * 1e18`.
    /// This is the load-bearing cross-repo contract between the publisher and
    /// this adapter — do not change without coordinating the publisher.
    uint256 public constant PUBLISHER_DECIMALS = 18;

    /// @notice The central multi-pair price store this adapter reads —
    /// chain-constant, shared by all beacon proxies, hence an
    /// implementation immutable.
    ST0xPriceOracle public immutable iCentral;

    /// @custom:storage-location erc7201:st0x.morphopairadapter.main
    struct MainStorage {
        // The Morpho collateral token (`base`) this adapter prices.
        address baseToken;
        // The Morpho loan token (`quote`) prices are denominated in.
        address quoteToken;
        // iCentral.pairId(baseToken, quoteToken), cached at init.
        bytes32 pairId;
        // 10^(36 + quoteDecimals) — the Morpho-scale numerator.
        uint256 scaleNumerator;
        // 10^(baseDecimals + PUBLISHER_DECIMALS) — the Morpho-scale denominator.
        uint256 scaleDenominator;
    }

    // keccak256(abi.encode(uint256(keccak256("st0x.morphopairadapter.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MAIN_STORAGE_LOCATION = 0x74b4f4941730157fbb9029e5ac16504bafcfacccce2e3df7268ce3b41dcfcc00;

    function _main() private pure returns (MainStorage storage $) {
        assembly ("memory-safe") {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    error ZeroCentral();

    constructor(ST0xPriceOracle central) {
        if (address(central) == address(0)) revert ZeroCentral();
        iCentral = central;
        _disableInitializers();
    }

    /// @notice Initialise one beacon proxy for a Morpho market pair.
    /// @param base The Morpho collateral token being priced. Reverts
    /// `ZeroToken` if zero, `IdenticalTokens` if equal to `quote`.
    /// @param quote The Morpho loan token prices are denominated in.
    /// @dev Reads both tokens' `decimals()` and precomputes the Morpho scale
    /// factors. A token whose `decimals()` is absurdly large makes the
    /// `10 ** ...` overflow and reverts here — fail-closed at init rather than
    /// minting an always-reverting adapter. The exact fail-closed boundaries
    /// are `quoteDecimals >= 42` (numerator `10^(36 + quoteDecimals)` exceeds
    /// `2^256`) and `baseDecimals >= 60` (denominator `10^(baseDecimals + 18)`
    /// exceeds `2^256`); both surface as an arithmetic-overflow panic.
    /// @dev Surviving init does NOT guarantee `price()` can never overflow.
    /// A quote token with e.g. 41 decimals passes here (`10^77 < 2^256`) but
    /// leaves `scaleNumerator ~= 1e77`, and `price()`'s
    /// `mulDiv(central, scaleNumerator, scaleDenominator)` can then exceed
    /// `2^256` for a normal central value when `scaleDenominator` is small —
    /// bricking that market (fail-closed revert, never a wrong price). This is
    /// only reachable with pathological 40+ decimal tokens; operators MUST bind
    /// only real, sane-decimal (`<= ~18`) tokens.
    function initialize(address base, address quote) external initializer {
        if (base == address(0) || quote == address(0)) revert ZeroToken();
        if (base == quote) revert IdenticalTokens();

        uint256 baseDecimals = IERC20Metadata(base).decimals();
        uint256 quoteDecimals = IERC20Metadata(quote).decimals();

        MainStorage storage $ = _main();
        $.baseToken = base;
        $.quoteToken = quote;
        $.pairId = iCentral.pairId(base, quote);
        $.scaleNumerator = 10 ** (36 + quoteDecimals);
        $.scaleDenominator = 10 ** (baseDecimals + PUBLISHER_DECIMALS);
    }

    /// @notice The Morpho collateral token (`base`) this adapter prices.
    function baseToken() external view returns (address) {
        return _main().baseToken;
    }

    /// @notice The Morpho loan token (`quote`) prices are denominated in.
    function quoteToken() external view returns (address) {
        return _main().quoteToken;
    }

    /// @notice The central-store pair id this adapter forwards.
    function pairId() external view returns (bytes32) {
        return _main().pairId;
    }

    /// @inheritdoc IOracle
    /// @dev Reads the publisher-signed 18-decimal value from the central store
    /// (which enforces staleness / unset reverts) and rescales it into Morpho
    /// Blue's `1e36 * 10^loanDec / 10^collDec` convention.
    /// @dev `Math.mulDiv` floors (rounds DOWN). This is deliberate and MUST NOT
    /// change: the result is the Morpho *collateral* price, and under-stating
    /// collateral is the conservative direction (less borrowing power, earlier
    /// liquidation) that favours the lender/protocol. A `Ceil` variant would
    /// silently reverse this safety property.
    function price() external view returns (uint256) {
        MainStorage storage $ = _main();
        return Math.mulDiv(iCentral.price($.pairId), $.scaleNumerator, $.scaleDenominator);
    }
}
