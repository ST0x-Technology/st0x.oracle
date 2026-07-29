// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";

import {ST0xPriceOracle} from "../../../src/concrete/oracle/ST0xPriceOracle.sol";

/// @title SignedPriceTestBase
/// @notice Shared test base holding the single canonical EIP-712 signing
/// implementation for `ST0xPriceOracle` price updates. Every concrete test
/// that needs to forge a signed `updatePrice` payload inherits this so the
/// digest derivation (`PRICE_UPDATE_TYPEHASH` struct hash + `\x19\x01`
/// domain-separator packing) lives in exactly one place. If the signing
/// scheme ever changes, this is the only helper to update and every inheriting
/// suite recompiles against it — no silent per-file drift.
abstract contract SignedPriceTestBase is Test {
    /// @notice Recreates the EIP-712 digest an off-chain signer would sign for
    /// a price update against `store`, taking the oracle store as a parameter
    /// so the derivation is not tied to any one test's local variable name.
    /// @param store The oracle whose domain separator and typehash are used.
    /// @param id The pair id.
    /// @param price The price being pushed.
    /// @param timestamp The observation timestamp.
    /// @return The 32-byte EIP-712 digest.
    function digestFor(ST0xPriceOracle store, bytes32 id, uint256 price, uint256 timestamp)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(store.PRICE_UPDATE_TYPEHASH(), id, price, timestamp));
        return keccak256(abi.encodePacked("\x19\x01", store.domainSeparator(), structHash));
    }

    /// @notice Signs a price update for `store` with `pk`, producing the
    /// packed `(r, s, v)` signature `updatePrice` expects.
    /// @param store The oracle the signature is for.
    /// @param pk The private key to sign with.
    /// @param id The pair id.
    /// @param price The price being pushed.
    /// @param timestamp The observation timestamp.
    /// @return The `abi.encodePacked(r, s, v)` signature.
    function signPriceUpdate(ST0xPriceOracle store, uint256 pk, bytes32 id, uint256 price, uint256 timestamp)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digestFor(store, id, price, timestamp));
        return abi.encodePacked(r, s, v);
    }
}
