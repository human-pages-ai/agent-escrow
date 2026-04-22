// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "../interfaces/IRealityETH.sol";
import "../AgentEscrow.sol";

/// @title RealityETHAdapter
/// @notice Bridges reality.eth oracle answers to AgentEscrow verdicts via EIP-1271.
/// The depositor creates questions and posts bonds on reality.eth directly.
/// This adapter only reads finalized answers and translates them into verdicts.
/// Answer encoding: 0 = payee wins, 1 = depositor wins, 2-99 = payee gets N%.
contract RealityETHAdapter is IERC1271 {
    IRealityETH public immutable realityETH;
    AgentEscrow public immutable escrow;

    bytes32 private constant VERDICT_TYPEHASH =
        keccak256("Verdict(bytes32 jobId,uint256 toPayee,uint256 toDepositor,uint256 arbitratorFee,uint256 nonce)");

    struct Verdict {
        uint256 toPayee;
        uint256 toDepositor;
        uint256 arbitratorFee;
        uint256 nonce;
        bool generated;
    }

    mapping(bytes32 => Verdict) public verdicts;
    mapping(bytes32 => bool) public approvedDigests;
    uint256 private _verdictNonce;

    event VerdictGenerated(bytes32 indexed jobId, bytes32 indexed questionId, uint256 toPayee, uint256 toDepositor, uint256 arbitratorFee);

    constructor(address _realityETH, address _escrow) {
        realityETH = IRealityETH(_realityETH);
        escrow = AgentEscrow(_escrow);
    }

    function generateVerdict(bytes32 jobId, bytes32 questionId) external {
        require(!verdicts[jobId].generated, "Verdict already generated");

        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        require(e.state == AgentEscrow.EscrowState.Disputed, "Escrow not disputed");

        require(realityETH.isFinalized(questionId), "Question not finalized");
        bytes32 answer = realityETH.resultFor(questionId);
        uint256 answerVal = uint256(answer);

        uint256 arbitratorFee = (e.amount * e.arbitratorFeeBps) / 10000;
        uint256 netAmount = e.amount - arbitratorFee;

        uint256 toPayee;
        uint256 toDepositor;

        if (answerVal == 0) {
            toPayee = netAmount;
            toDepositor = 0;
        } else if (answerVal == 1) {
            toPayee = 0;
            toDepositor = netAmount;
        } else {
            require(answerVal >= 2 && answerVal <= 99, "Invalid answer value");
            toPayee = (netAmount * answerVal) / 100;
            toDepositor = netAmount - toPayee;
        }

        _verdictNonce++;
        verdicts[jobId] = Verdict({
            toPayee: toPayee,
            toDepositor: toDepositor,
            arbitratorFee: arbitratorFee,
            nonce: _verdictNonce,
            generated: true
        });

        bytes32 digest = _computeDigest(jobId, toPayee, toDepositor, arbitratorFee, _verdictNonce);
        approvedDigests[digest] = true;

        emit VerdictGenerated(jobId, questionId, toPayee, toDepositor, arbitratorFee);
    }

    function getVerdictParams(bytes32 jobId) external view returns (
        uint256 toPayee,
        uint256 toDepositor,
        uint256 arbitratorFee,
        uint256 nonce,
        bool generated
    ) {
        Verdict memory v = verdicts[jobId];
        return (v.toPayee, v.toDepositor, v.arbitratorFee, v.nonce, v.generated);
    }

    function isValidSignature(bytes32 hash, bytes memory) external view override returns (bytes4) {
        if (approvedDigests[hash]) {
            return 0x1626ba7e;
        }
        return 0xffffffff;
    }

    function _computeDigest(
        bytes32 jobId,
        uint256 toPayee,
        uint256 toDepositor,
        uint256 arbitratorFee,
        uint256 nonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(VERDICT_TYPEHASH, jobId, toPayee, toDepositor, arbitratorFee, nonce)
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
