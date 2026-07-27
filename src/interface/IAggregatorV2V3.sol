// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @title AggregatorV2V3Interface
/// @notice Hybrid of Chainlink's `AggregatorInterface` (v2 — `latestAnswer`)
/// and `AggregatorV3Interface` (v3 — `latestRoundData`, `getRoundData`).
/// Mirrors Chainlink's own `AggregatorV2V3Interface` so consumers can target
/// the v2 staleness-blind read (Aave V3 / Compound V3 / legacy oracle
/// consumers) and the v3 round-aware read against the same instance.
/// @dev We define this here to avoid pulling Chainlink as a dependency. The
/// surface intentionally includes the deprecated `latestAnswer()` because
/// Aave V3 and Compound V3 still call it on their oracle slots; new code
/// should prefer `latestRoundData()` and honour `updatedAt` for staleness.
interface AggregatorV2V3Interface {
    /// @notice Number of decimals the answer is scaled to.
    function decimals() external view returns (uint8);

    /// @notice Human-readable description of the feed. Chainlink feeds
    /// conventionally use a pair string (e.g. `"AAPL / USD"`), but the exact
    /// format is implementation-defined — a DIA-backed implementation may
    /// return the bare feed symbol (e.g. `"COIN"`) instead. Consumers should
    /// treat it as an opaque label, not parse it for the quote asset.
    function description() external view returns (string memory);

    /// @notice Aggregator version. Chainlink convention is `1` for v1 and
    /// higher for later aggregator versions.
    function version() external view returns (uint256);

    /// @notice The latest answer the aggregator computed.
    /// @dev Deprecated by Chainlink in favour of `latestRoundData()` because
    /// it carries no `updatedAt` timestamp and so prevents staleness checks
    /// at the call site. Retained here for Aave V3 / Compound V3 compatibility.
    function latestAnswer() external view returns (int256);

    /// @notice Get historical round data by `_roundId`.
    /// @param _roundId Round identifier.
    /// @return roundId The round ID returned for the supplied `_roundId`.
    /// @return answer The answer for that round.
    /// @return startedAt Timestamp when the round was started.
    /// @return updatedAt Timestamp when the round was updated.
    /// @return answeredInRound The round in which the answer was computed.
    /// @dev Pyth-backed implementations may revert because Pyth does not
    /// expose historical rounds via this interface. Pure Chainlink-backed
    /// implementations honour the request.
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Latest round data.
    /// @return roundId Round ID of the latest round.
    /// @return answer Latest answer.
    /// @return startedAt Timestamp when the round was started.
    /// @return updatedAt Timestamp when the round was last updated.
    /// @return answeredInRound Round in which `answer` was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
