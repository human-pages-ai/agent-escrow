// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/interfaces/IRealityETH.sol";

contract MockRealityETH is IRealityETH {
    struct Question {
        address asker;
        bytes32 currentAnswer;
        uint256 currentBond;
        address lastAnswerer;
        uint32 timeout;
        uint256 lastAnswerTs;
        bool arbitrationPending;
    }

    mapping(bytes32 => Question) public questions;
    mapping(bytes32 => bool) private _finalized;
    mapping(bytes32 => bytes32) private _finalAnswer;
    uint256 private _nonce;

    function askQuestion(
        uint256,
        string memory,
        address,
        uint32 timeout,
        uint32,
        uint256
    ) external payable override returns (bytes32) {
        _nonce++;
        bytes32 questionId = keccak256(abi.encode(msg.sender, _nonce));
        questions[questionId] = Question({
            asker: msg.sender,
            currentAnswer: bytes32(0),
            currentBond: 0,
            lastAnswerer: address(0),
            timeout: timeout,
            lastAnswerTs: 0,
            arbitrationPending: false
        });
        return questionId;
    }

    function submitAnswer(
        bytes32 question_id,
        bytes32 answer,
        uint256 max_previous
    ) external payable override {
        Question storage q = questions[question_id];
        require(q.timeout > 0, "Question does not exist");
        require(!_finalized[question_id], "Already finalized");
        require(msg.value >= q.currentBond * 2 || q.currentBond == 0, "Bond too low");
        if (max_previous > 0) {
            require(q.currentBond <= max_previous, "Bond exceeds max_previous");
        }

        q.currentAnswer = answer;
        q.currentBond = msg.value;
        q.lastAnswerer = msg.sender;
        q.lastAnswerTs = block.timestamp;
    }

    function isFinalized(bytes32 question_id) external view override returns (bool) {
        if (_finalized[question_id]) return true;
        Question storage q = questions[question_id];
        if (q.lastAnswerTs == 0) return false;
        return block.timestamp >= q.lastAnswerTs + q.timeout;
    }

    function resultFor(bytes32 question_id) external view override returns (bytes32) {
        if (_finalized[question_id]) return _finalAnswer[question_id];
        Question storage q = questions[question_id];
        require(q.lastAnswerTs > 0, "No answer submitted");
        require(block.timestamp >= q.lastAnswerTs + q.timeout, "Not finalized");
        return q.currentAnswer;
    }

    // ======================== TEST HELPERS ========================

    function mockFinalize(bytes32 question_id, bytes32 answer) external {
        _finalized[question_id] = true;
        _finalAnswer[question_id] = answer;
    }
}
