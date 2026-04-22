// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IArbitratorStatus {
    function isDisputePending(bytes32 jobId) external view returns (bool);
}
