// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @dev The live DIA push-oracle feed on Base that every DIA-backed vault
/// oracle reads. Single source of truth for the address that was previously
/// re-typed across README.md, `IDIAOracleV2.sol` and the fork test — import
/// this constant instead of pasting the literal. Last synced 2026-06-29.
/// https://basescan.org/address/0xCE521b52513242c5094bc56f57887BB2A05B8129
address constant DIA_FEED_BASE = 0xCE521b52513242c5094bc56f57887BB2A05B8129;
