// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "../interfaces/IRealityETH.sol";
import "../interfaces/IArbitratorStatus.sol";
import "../AgentEscrow.sol";

/// @title RealityETHAdapter
/// @notice Bridges reality.eth oracle answers to AgentEscrow verdicts via EIP-1271.
/// Either dispute party calls initiateDispute() to create a reality.eth question.
/// The adapter stores the jobId→questionId binding and generates verdicts from finalized answers.
/// Answer encoding: 0 = payee wins, 1 = depositor wins, 2-99 = payee gets N%.
contract RealityETHAdapter is IERC1271, IArbitratorStatus {
    IRealityETH public immutable realityETH;
    AgentEscrow public immutable escrow;

    bytes32 private constant VERDICT_TYPEHASH =
        keccak256("Verdict(bytes32 jobId,uint256 toPayee,uint256 toDepositor,uint256 nonce)");

    string public constant DISPUTE_BASE_URL = "https://humanpages.ai/disputes/";
    uint32 public constant REALITY_TIMEOUT = 86400; // 24h answer timeout

    struct Verdict {
        uint256 toPayee;
        uint256 toDepositor;
        uint256 nonce;
        bool generated;
    }

    mapping(bytes32 => bytes32) public jobQuestions;
    mapping(bytes32 => Verdict) public verdicts;
    mapping(bytes32 => bool) public approvedDigests;
    uint256 private _verdictNonce;

    event DisputeInitiated(bytes32 indexed jobId, bytes32 indexed questionId);
    event VerdictGenerated(bytes32 indexed jobId, bytes32 indexed questionId, uint256 toPayee, uint256 toDepositor);

    constructor(address _realityETH, address _escrow) {
        realityETH = IRealityETH(_realityETH);
        escrow = AgentEscrow(_escrow);
    }

    function initiateDispute(bytes32 jobId) external returns (bytes32) {
        require(jobQuestions[jobId] == bytes32(0), "Dispute already initiated");

        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        require(e.state == AgentEscrow.EscrowState.Disputed, "Escrow not disputed");
        require(msg.sender == e.depositor || msg.sender == e.payee, "Not a party");

        string memory question = string(abi.encodePacked(
            DISPUTE_BASE_URL,
            Strings.toHexString(uint256(jobId), 32)
        ));

        bytes32 questionId = realityETH.askQuestion(
            0,
            question,
            address(0),
            REALITY_TIMEOUT,
            uint32(block.timestamp),
            uint256(jobId)
        );

        jobQuestions[jobId] = questionId;
        emit DisputeInitiated(jobId, questionId);
        return questionId;
    }

    function generateVerdict(bytes32 jobId) external {
        bytes32 questionId = jobQuestions[jobId];
        require(questionId != bytes32(0), "Dispute not initiated");
        require(!verdicts[jobId].generated, "Verdict already generated");

        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        require(e.state == AgentEscrow.EscrowState.Disputed, "Escrow not disputed");

        require(realityETH.isFinalized(questionId), "Question not finalized");
        bytes32 answer = realityETH.resultFor(questionId);
        uint256 answerVal = uint256(answer);

        uint256 toPayee;
        uint256 toDepositor;

        if (answerVal == 0) {
            toPayee = e.amount;
            toDepositor = 0;
        } else if (answerVal == 1) {
            toPayee = 0;
            toDepositor = e.amount;
        } else {
            require(answerVal >= 2 && answerVal <= 99, "Invalid answer value");
            toPayee = (e.amount * answerVal) / 100;
            toDepositor = e.amount - toPayee;
        }

        _verdictNonce++;
        verdicts[jobId] = Verdict({
            toPayee: toPayee,
            toDepositor: toDepositor,
            nonce: _verdictNonce,
            generated: true
        });

        bytes32 digest = _computeDigest(jobId, toPayee, toDepositor, _verdictNonce);
        approvedDigests[digest] = true;

        emit VerdictGenerated(jobId, questionId, toPayee, toDepositor);
    }

    function getVerdictParams(bytes32 jobId) external view returns (
        uint256 toPayee,
        uint256 toDepositor,
        uint256 nonce,
        bool generated
    ) {
        Verdict memory v = verdicts[jobId];
        return (v.toPayee, v.toDepositor, v.nonce, v.generated);
    }

    function isValidSignature(bytes32 hash, bytes memory) external view override returns (bytes4) {
        if (approvedDigests[hash]) {
            return 0x1626ba7e;
        }
        return 0xffffffff;
    }

    function isDisputePending(bytes32 jobId) external view override returns (bool) {
        bytes32 questionId = jobQuestions[jobId];
        if (questionId == bytes32(0)) return false;
        return !realityETH.isFinalized(questionId);
    }

    function _computeDigest(
        bytes32 jobId,
        uint256 toPayee,
        uint256 toDepositor,
        uint256 nonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(VERDICT_TYPEHASH, jobId, toPayee, toDepositor, nonce)
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AgentEscrow"),
                keccak256("2"),
                block.chainid,
                address(escrow)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
