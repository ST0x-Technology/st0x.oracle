// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ICorporateActionsV1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {CompletionFilter, NODE_NONE} from "st0x-deploy-0.1.1/src/lib/LibCorporateActionNode.sol";

/// @title MockCorporateActions
/// @notice Minimal mock of `ICorporateActionsV1` exposing only the two read
/// paths `LibCorporateActionsPause` consumes. Other interface methods revert
/// so a regression that calls them is caught loudly.
///
/// @dev Audit findings #45/#52 note this mock re-encodes beliefs about the
/// real `StoxCorporateActionsFacet` traversal. Rather than reproduce the
/// dependency's delegatecall + authorizer harness to re-test code the
/// `st0x-deploy` package already covers, the divergence surface is bounded
/// deliberately: the action-type bit encoding this mock relies on is pinned to
/// the imported constants by `ActionTypeEncoding.t.sol`, and the read contract
/// is the `ICorporateActionsV1` interface itself. The remaining cross-impl
/// check — that `LibCorporateActionsPause` reads a *real* deployed vault's
/// schedule identically — belongs in a fork test against a live vault, not a
/// reproduced harness.
///
/// Setters accept a caller-supplied cursor so tests can exercise both the
/// no-match sentinel (`NODE_NONE`) and the bootstrap node (cursor 0). Tests
/// that don't care about cursor can just pass `1`.
contract MockCorporateActions is ICorporateActionsV1 {
    struct StubAction {
        bool exists;
        uint256 cursor;
        uint256 actionType;
        uint64 effectiveTime;
    }

    StubAction private _earliestPending;
    StubAction private _latestCompleted;

    function setEarliestPending(uint256 cursor, uint256 actionType, uint64 effectiveTime) external {
        _earliestPending = StubAction({
            exists: cursor != NODE_NONE, cursor: cursor, actionType: actionType, effectiveTime: effectiveTime
        });
    }

    function setLatestCompleted(uint256 cursor, uint256 actionType, uint64 effectiveTime) external {
        _latestCompleted = StubAction({
            exists: cursor != NODE_NONE, cursor: cursor, actionType: actionType, effectiveTime: effectiveTime
        });
    }

    function earliestActionOfType(uint256 mask, CompletionFilter filter)
        external
        view
        override
        returns (uint256, uint256, uint64)
    {
        if (filter != CompletionFilter.PENDING) revert("mock: only PENDING supported");
        if (!_earliestPending.exists) return (NODE_NONE, 0, 0);
        if (_earliestPending.actionType & mask == 0) return (NODE_NONE, 0, 0);
        return (_earliestPending.cursor, _earliestPending.actionType, _earliestPending.effectiveTime);
    }

    function latestActionOfType(uint256 mask, CompletionFilter filter)
        external
        view
        override
        returns (uint256, uint256, uint64)
    {
        if (filter != CompletionFilter.COMPLETED) revert("mock: only COMPLETED supported");
        if (!_latestCompleted.exists) return (NODE_NONE, 0, 0);
        if (_latestCompleted.actionType & mask == 0) return (NODE_NONE, 0, 0);
        return (_latestCompleted.cursor, _latestCompleted.actionType, _latestCompleted.effectiveTime);
    }

    function scheduleCorporateAction(bytes32, uint64, bytes calldata) external pure override returns (uint256) {
        revert("mock: not implemented");
    }

    function cancelCorporateAction(uint256) external pure override {
        revert("mock: not implemented");
    }

    uint256 private _completedActionCount;

    function setCompletedActionCount(uint256 v) external {
        _completedActionCount = v;
    }

    function completedActionCount() external view override returns (uint256) {
        return _completedActionCount;
    }

    function nextOfType(uint256, uint256, CompletionFilter) external pure override returns (uint256, uint256, uint64) {
        revert("mock: not implemented");
    }

    function prevOfType(uint256, uint256, CompletionFilter) external pure override returns (uint256, uint256, uint64) {
        revert("mock: not implemented");
    }

    function getActionParameters(uint256) external pure override returns (bytes memory) {
        revert("mock: not implemented");
    }
}
