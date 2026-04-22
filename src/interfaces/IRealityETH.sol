// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRealityETH {
    function askQuestion(
        uint256 template_id,
        string memory question,
        address arbitrator,
        uint32 timeout,
        uint32 opening_ts,
        uint256 nonce
    ) external payable returns (bytes32);

    function submitAnswer(
        bytes32 question_id,
        bytes32 answer,
        uint256 max_previous
    ) external payable;

    function isFinalized(bytes32 question_id) external view returns (bool);
    function resultFor(bytes32 question_id) external view returns (bytes32);
}
