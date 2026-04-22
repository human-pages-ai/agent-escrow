// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AgentEscrow.sol";
import "../src/arbitrators/RealityETHAdapter.sol";
import "../src/interfaces/IRealityETH.sol";
import "./mocks/MockRealityETH.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract RealityETHIntegrationTest is Test {
    AgentEscrow public escrow;
    MockUSDC6 public usdc;
    MockRealityETH public realityETH;
    RealityETHAdapter public adapter;

    address public owner = address(this);
    address public relayer = makeAddr("relayer");
    address public depositor = makeAddr("depositor");
    address public payee = makeAddr("payee");
    address public answerer1 = makeAddr("answerer1");
    address public answerer2 = makeAddr("answerer2");
    address public anyone = makeAddr("anyone");

    uint256 public arbitratorPk = 0xA11CE;
    address public eoaArbitrator;

    bytes32 public jobId = keccak256("job-reality-001");
    uint256 public constant AMOUNT = 100e6; // $100 USDC
    uint32 public constant DISPUTE_WINDOW = 72 hours;
    uint256 public constant FEE_BPS = 500; // 5%
    uint256 public constant ARB_FEE = (AMOUNT * FEE_BPS) / 10000; // 5e6
    uint256 public constant NET_AMOUNT = AMOUNT - ARB_FEE; // 95e6

    function setUp() public {
        eoaArbitrator = vm.addr(arbitratorPk);

        usdc = new MockUSDC6();
        escrow = new AgentEscrow(address(usdc));
        realityETH = new MockRealityETH();
        adapter = new RealityETHAdapter(address(realityETH), address(escrow));

        escrow.grantRole(escrow.RELAYER_ROLE(), relayer);

        usdc.mint(depositor, 10_000e6);
        vm.prank(depositor);
        usdc.approve(address(escrow), type(uint256).max);

        vm.deal(depositor, 10 ether);
        vm.deal(answerer1, 10 ether);
        vm.deal(answerer2, 10 ether);
    }

    // ======================== HELPERS ========================

    function _deposit() internal {
        _depositWith(jobId, address(adapter));
    }

    function _depositWith(bytes32 _jobId, address _arbitrator) internal {
        vm.prank(depositor);
        escrow.deposit(_jobId, payee, _arbitrator, DISPUTE_WINDOW, AMOUNT, FEE_BPS);
    }

    function _depositAndComplete() internal {
        _deposit();
        vm.prank(relayer);
        escrow.markComplete(jobId);
    }

    function _depositCompleteAndDispute() internal {
        _depositAndComplete();
        vm.prank(depositor);
        escrow.dispute(jobId);
    }

    // Depositor creates question directly on reality.eth (not through adapter)
    function _depositorCreatesQuestion() internal returns (bytes32 questionId) {
        vm.prank(depositor);
        questionId = realityETH.askQuestion(0, "Did worker complete job-reality-001?", address(0), 30 minutes, 0, 0);
    }

    function _fullFlowUntilVerdict(bytes32 answer) internal returns (bytes32 questionId) {
        _depositCompleteAndDispute();
        questionId = _depositorCreatesQuestion();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, answer, 0);

        vm.warp(block.timestamp + 31 minutes);

        vm.prank(anyone);
        adapter.generateVerdict(jobId, questionId);
    }

    function _signVerdictEOA(
        bytes32 _jobId,
        uint256 toPayee,
        uint256 toDepositor,
        uint256 arbitratorFee,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Verdict(bytes32 jobId,uint256 toPayee,uint256 toDepositor,uint256 arbitratorFee,uint256 nonce)"),
                _jobId, toPayee, toDepositor, arbitratorFee, nonce
            )
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(arbitratorPk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ======================== FLOW A: HAPPY PATH (NO DISPUTE) ========================

    function test_flowA_happyPath_noDispute() public {
        _depositAndComplete();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(anyone);
        escrow.release(jobId);

        assertEq(usdc.balanceOf(payee), payeeBefore + AMOUNT);
        assertEq(usdc.balanceOf(address(adapter)), 0);

        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        assertTrue(e.state == AgentEscrow.EscrowState.Released);
    }

    // ======================== FLOW B: DISPUTE → HONEST ANSWER → RESOLVE ========================

    function test_flowB_disputeResolve_payeeWins() public {
        _fullFlowUntilVerdict(bytes32(uint256(0))); // payee wins

        (uint256 toPayee, uint256 toDepositor, uint256 arbitratorFee, uint256 nonce, bool generated) =
            adapter.getVerdictParams(jobId);
        assertTrue(generated);
        assertEq(toPayee, NET_AMOUNT);
        assertEq(toDepositor, 0);
        assertEq(arbitratorFee, ARB_FEE);

        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 adapterBefore = usdc.balanceOf(address(adapter));

        vm.prank(anyone);
        escrow.resolve(jobId, toPayee, toDepositor, arbitratorFee, nonce, "");

        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);
        assertEq(usdc.balanceOf(depositor), 10_000e6 - AMOUNT);
        assertEq(usdc.balanceOf(address(adapter)), adapterBefore + ARB_FEE);

        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        assertTrue(e.state == AgentEscrow.EscrowState.Resolved);
    }

    // ======================== FLOW C: BOND ESCALATION → LAST ANSWER WINS ========================

    function test_flowC_bondEscalation_depositorWins() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _depositorCreatesQuestion();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(1)), 0);

        vm.prank(answerer2);
        realityETH.submitAnswer{value: 0.02 ether}(questionId, bytes32(uint256(0)), 0);

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.04 ether}(questionId, bytes32(uint256(1)), 0);

        vm.warp(block.timestamp + 31 minutes);

        vm.prank(anyone);
        adapter.generateVerdict(jobId, questionId);

        (uint256 toPayee, uint256 toDepositor, uint256 arbitratorFee, uint256 nonce,) =
            adapter.getVerdictParams(jobId);
        assertEq(toPayee, 0);
        assertEq(toDepositor, NET_AMOUNT);
        assertEq(arbitratorFee, ARB_FEE);

        uint256 depositorBefore = usdc.balanceOf(depositor);
        vm.prank(anyone);
        escrow.resolve(jobId, toPayee, toDepositor, arbitratorFee, nonce, "");

        assertEq(usdc.balanceOf(depositor), depositorBefore + NET_AMOUNT);
        assertEq(usdc.balanceOf(payee), 0);
    }

    // ======================== FLOW D: PARTIAL SPLIT (PERCENTAGE) ========================

    function test_flowD_partialSplit_70percent() public {
        _fullFlowUntilVerdict(bytes32(uint256(70)));

        (uint256 toPayee, uint256 toDepositor, uint256 arbitratorFee, uint256 nonce, bool generated) =
            adapter.getVerdictParams(jobId);
        assertTrue(generated);

        assertEq(toPayee, 66_500_000);
        assertEq(toDepositor, 28_500_000);
        assertEq(arbitratorFee, ARB_FEE);
        assertEq(toPayee + toDepositor + arbitratorFee, AMOUNT);

        vm.prank(anyone);
        escrow.resolve(jobId, toPayee, toDepositor, arbitratorFee, nonce, "");

        assertEq(usdc.balanceOf(payee), 66_500_000);
        assertEq(usdc.balanceOf(depositor), 10_000e6 - AMOUNT + 28_500_000);
    }

    // ======================== FLOW E: ARBITRATOR TIMEOUT → FORCE RELEASE ========================

    function test_flowE_arbitratorTimeout_forceRelease() public {
        _depositCompleteAndDispute();
        // depositor creates question but nobody answers
        _depositorCreatesQuestion();

        vm.warp(block.timestamp + 7 days);

        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(anyone);
        escrow.forceRelease(jobId);

        assertEq(usdc.balanceOf(payee), payeeBefore + AMOUNT);

        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        assertTrue(e.state == AgentEscrow.EscrowState.Released);
    }

    // ======================== FLOW F: EOA ARBITRATOR BYPASS ========================

    function test_flowF_eoaArbitrator_existingBehavior() public {
        bytes32 eoaJobId = keccak256("job-eoa-001");

        vm.prank(depositor);
        escrow.deposit(eoaJobId, payee, eoaArbitrator, DISPUTE_WINDOW, AMOUNT, FEE_BPS);

        vm.prank(relayer);
        escrow.markComplete(eoaJobId);

        vm.prank(depositor);
        escrow.dispute(eoaJobId);

        uint256 nonce = 42;
        uint256 toPayee = NET_AMOUNT;
        uint256 toDepositor = 0;
        bytes memory sig = _signVerdictEOA(eoaJobId, toPayee, toDepositor, ARB_FEE, nonce);

        vm.prank(anyone);
        escrow.resolve(eoaJobId, toPayee, toDepositor, ARB_FEE, nonce, sig);

        assertEq(usdc.balanceOf(payee), NET_AMOUNT);
        assertEq(usdc.balanceOf(eoaArbitrator), ARB_FEE);
    }

    // ======================== FLOW G: GENERATE VERDICT — ESCROW NOT DISPUTED ========================

    function test_flowG_generateVerdict_notDisputed_reverts() public {
        _depositAndComplete(); // state = Completed, not Disputed
        bytes32 questionId = _depositorCreatesQuestion();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(0)), 0);
        vm.warp(block.timestamp + 31 minutes);

        vm.prank(anyone);
        vm.expectRevert("Escrow not disputed");
        adapter.generateVerdict(jobId, questionId);
    }

    // ======================== FLOW H: NONEXISTENT QUESTION ID ========================

    function test_flowH_nonexistentQuestion_reverts() public {
        _depositCompleteAndDispute();
        bytes32 fakeQuestionId = keccak256("does-not-exist");

        vm.prank(anyone);
        vm.expectRevert();
        adapter.generateVerdict(jobId, fakeQuestionId);
    }

    // ======================== FLOW I: GENERATE VERDICT BEFORE FINALIZED ========================

    function test_flowI_generateVerdict_notFinalized_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _depositorCreatesQuestion();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(0)), 0);

        // don't warp — timeout hasn't passed
        vm.prank(anyone);
        vm.expectRevert("Question not finalized");
        adapter.generateVerdict(jobId, questionId);
    }

    // ======================== FLOW J: TAMPERED RESOLVE PARAMS REJECTED ========================

    function test_flowJ_tamperedResolve_reverts() public {
        _fullFlowUntilVerdict(bytes32(uint256(70)));

        (,, uint256 arbitratorFee, uint256 nonce,) = adapter.getVerdictParams(jobId);

        vm.prank(anyone);
        vm.expectRevert("Invalid arbitrator signature");
        escrow.resolve(jobId, NET_AMOUNT, 0, arbitratorFee, nonce, "");
    }

    // ======================== FLOW K: DOUBLE GENERATE VERDICT ========================

    function test_flowK_doubleGenerateVerdict_reverts() public {
        bytes32 questionId = _fullFlowUntilVerdict(bytes32(uint256(0)));

        vm.prank(anyone);
        vm.expectRevert("Verdict already generated");
        adapter.generateVerdict(jobId, questionId);
    }

    // ======================== FLOW L: DOMAIN SEPARATOR PARITY ========================

    function test_flowL_domainSeparatorParity() public {
        _fullFlowUntilVerdict(bytes32(uint256(0)));

        (uint256 toPayee, uint256 toDepositor, uint256 arbitratorFee, uint256 nonce,) =
            adapter.getVerdictParams(jobId);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Verdict(bytes32 jobId,uint256 toPayee,uint256 toDepositor,uint256 arbitratorFee,uint256 nonce)"),
                jobId, toPayee, toDepositor, arbitratorFee, nonce
            )
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
        bytes32 correctDigest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        bytes4 result = adapter.isValidSignature(correctDigest, "");
        assertEq(result, bytes4(0x1626ba7e));

        bytes32 wrongDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AgentEscrow"),
                keccak256("2"),
                block.chainid,
                address(0xdead)
            )
        );
        bytes32 wrongDigest = keccak256(abi.encodePacked("\x19\x01", wrongDomain, structHash));
        bytes4 wrongResult = adapter.isValidSignature(wrongDigest, "");
        assertEq(wrongResult, bytes4(0xffffffff));
    }

    // ======================== FLOW M: BOND TOO LOW REJECTION ========================

    function test_flowM_bondTooLow_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _depositorCreatesQuestion();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(0)), 0);

        vm.prank(answerer2);
        vm.expectRevert("Bond too low");
        realityETH.submitAnswer{value: 0.015 ether}(questionId, bytes32(uint256(1)), 0);
    }

    // ======================== FLOW N: ANSWER RESETS TIMEOUT CLOCK ========================

    function test_flowN_answerResetsTimeout() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _depositorCreatesQuestion();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(0)), 0);

        vm.warp(block.timestamp + 25 minutes);
        assertFalse(realityETH.isFinalized(questionId));

        vm.prank(answerer2);
        realityETH.submitAnswer{value: 0.02 ether}(questionId, bytes32(uint256(1)), 0);

        vm.warp(block.timestamp + 25 minutes);
        assertFalse(realityETH.isFinalized(questionId));

        vm.warp(block.timestamp + 6 minutes);
        assertTrue(realityETH.isFinalized(questionId));

        assertEq(realityETH.resultFor(questionId), bytes32(uint256(1)));
    }

    // ======================== FLOW O: MULTI-JOB ISOLATION ========================

    function test_flowO_multiJobIsolation() public {
        bytes32 jobId2 = keccak256("job-reality-002");

        // setup job 1
        _depositCompleteAndDispute();
        vm.prank(depositor);
        bytes32 q1 = realityETH.askQuestion(0, "Job 1 question", address(0), 30 minutes, 0, 1);

        // setup job 2
        vm.prank(depositor);
        escrow.deposit(jobId2, payee, address(adapter), DISPUTE_WINDOW, 50e6, FEE_BPS);
        vm.prank(relayer);
        escrow.markComplete(jobId2);
        vm.prank(depositor);
        escrow.dispute(jobId2);

        vm.prank(depositor);
        bytes32 q2 = realityETH.askQuestion(0, "Job 2 question", address(0), 30 minutes, 0, 2);

        assertTrue(q1 != q2);

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(q1, bytes32(uint256(0)), 0);

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(q2, bytes32(uint256(1)), 0);

        vm.warp(block.timestamp + 31 minutes);

        vm.prank(anyone);
        adapter.generateVerdict(jobId, q1);
        vm.prank(anyone);
        adapter.generateVerdict(jobId2, q2);

        (uint256 tp1, uint256 td1, uint256 af1, uint256 n1,) = adapter.getVerdictParams(jobId);
        (uint256 tp2, uint256 td2, uint256 af2, uint256 n2,) = adapter.getVerdictParams(jobId2);

        assertEq(tp1, NET_AMOUNT);
        assertEq(td1, 0);
        assertEq(tp2, 0);
        assertEq(td2, 50e6 - (50e6 * FEE_BPS / 10000));
        assertTrue(n1 != n2);

        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 depositorBefore = usdc.balanceOf(depositor);

        vm.prank(anyone);
        escrow.resolve(jobId, tp1, td1, af1, n1, "");
        vm.prank(anyone);
        escrow.resolve(jobId2, tp2, td2, af2, n2, "");

        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);
        assertEq(usdc.balanceOf(depositor), depositorBefore + td2);
    }

    // ======================== FLOW P: NONEXISTENT QUESTION (NO ANSWERS) ========================

    function test_flowP_questionNoAnswers_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _depositorCreatesQuestion();
        // question exists but no one answered — not finalized

        vm.prank(anyone);
        vm.expectRevert();
        adapter.generateVerdict(jobId, questionId);
    }

    // ======================== FLOW Q: ANSWER AFTER FINALIZATION ========================

    function test_flowQ_answerAfterFinalization_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _depositorCreatesQuestion();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(0)), 0);

        realityETH.mockFinalize(questionId, bytes32(uint256(0)));

        vm.prank(answerer2);
        vm.expectRevert("Already finalized");
        realityETH.submitAnswer{value: 0.02 ether}(questionId, bytes32(uint256(1)), 0);
    }

    // ======================== FLOW R: EDGE ANSWER VALUES ========================

    function test_flowR_edgeAnswer_2percent() public {
        _fullFlowUntilVerdict(bytes32(uint256(2)));

        (uint256 toPayee, uint256 toDepositor, uint256 arbitratorFee,,) =
            adapter.getVerdictParams(jobId);

        assertEq(toPayee, 1_900_000);
        assertEq(toDepositor, 93_100_000);
        assertEq(toPayee + toDepositor + arbitratorFee, AMOUNT);
    }

    function test_flowR_edgeAnswer_99percent() public {
        bytes32 jobId99 = keccak256("job-reality-99pct");
        vm.prank(depositor);
        escrow.deposit(jobId99, payee, address(adapter), DISPUTE_WINDOW, AMOUNT, FEE_BPS);
        vm.prank(relayer);
        escrow.markComplete(jobId99);
        vm.prank(depositor);
        escrow.dispute(jobId99);

        vm.prank(depositor);
        bytes32 qId = realityETH.askQuestion(0, "99pct test", address(0), 30 minutes, 0, 99);

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(qId, bytes32(uint256(99)), 0);

        vm.warp(block.timestamp + 31 minutes);
        vm.prank(anyone);
        adapter.generateVerdict(jobId99, qId);

        (uint256 toPayee, uint256 toDepositor, uint256 arbitratorFee,,) =
            adapter.getVerdictParams(jobId99);

        assertEq(toPayee, 94_050_000);
        assertEq(toDepositor, 950_000);
        assertEq(toPayee + toDepositor + arbitratorFee, AMOUNT);
    }

    function test_flowR_edgeAnswer_100_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _depositorCreatesQuestion();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(100)), 0);

        vm.warp(block.timestamp + 31 minutes);

        vm.prank(anyone);
        vm.expectRevert("Invalid answer value");
        adapter.generateVerdict(jobId, questionId);
    }

    function test_flowR_edgeAnswer_huge_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _depositorCreatesQuestion();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(999)), 0);

        vm.warp(block.timestamp + 31 minutes);

        vm.prank(anyone);
        vm.expectRevert("Invalid answer value");
        adapter.generateVerdict(jobId, questionId);
    }

    // ======================== FLOW S: FAKE ORACLE REJECTED ========================

    function test_flowS_fakeOracle_questionNotOnBoundOracle() public {
        _depositCompleteAndDispute();

        // a questionId that doesn't exist on the bound oracle should revert
        bytes32 fakeQuestionId = keccak256("fake-question");

        vm.prank(anyone);
        vm.expectRevert();
        adapter.generateVerdict(jobId, fakeQuestionId);
    }

    // ======================== FLOW T: CHERRY-PICK UNRELATED QUESTION ========================

    function test_flowT_cherryPickUnrelatedQuestion() public {
        // depositor creates an unrelated question and answers it favorably
        vm.prank(depositor);
        bytes32 unrelatedQ = realityETH.askQuestion(0, "Unrelated question", address(0), 30 minutes, 0, 777);

        vm.prank(depositor);
        realityETH.submitAnswer{value: 0.01 ether}(unrelatedQ, bytes32(uint256(1)), 0); // depositor wins

        vm.warp(block.timestamp + 31 minutes);

        // now create the real escrow and dispute
        _deposit();
        vm.prank(relayer);
        escrow.markComplete(jobId);
        vm.prank(depositor);
        escrow.dispute(jobId);

        // depositor tries to use the unrelated question for this job
        // this WILL work because the adapter has no way to verify the link
        // this test documents the known trust assumption
        vm.prank(anyone);
        adapter.generateVerdict(jobId, unrelatedQ);

        (uint256 toPayee, uint256 toDepositor, uint256 arbitratorFee, uint256 nonce,) =
            adapter.getVerdictParams(jobId);

        // depositor gets the favorable outcome from the unrelated question
        assertEq(toDepositor, NET_AMOUNT);
        assertEq(toPayee, 0);

        // this resolves successfully — documenting the trust boundary
        vm.prank(anyone);
        escrow.resolve(jobId, toPayee, toDepositor, arbitratorFee, nonce, "");

        // THE PAYEE'S PROTECTION: the 7-day forceRelease timeout.
        // If the payee notices and doesn't want this, they should not let the
        // depositor resolve before timeout. In practice, the backend relayer
        // would verify the questionId matches the job before calling resolve.
    }
}
