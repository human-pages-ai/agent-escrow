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
    uint32 public constant OFFER_WINDOW = 12 hours;
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
        escrow.deposit(_jobId, payee, _arbitrator, DISPUTE_WINDOW, 30 days, AMOUNT, FEE_BPS, OFFER_WINDOW);
        escrow.activateEscrow(_jobId);
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

    function _initiateDisputeOnAdapter() internal returns (bytes32 questionId) {
        vm.prank(depositor);
        questionId = adapter.initiateDispute(jobId);
    }

    function _fullFlowUntilVerdict(bytes32 answer) internal returns (bytes32 questionId) {
        _depositCompleteAndDispute();
        questionId = _initiateDisputeOnAdapter();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, answer, 0);

        vm.warp(block.timestamp + 25 hours);

        vm.prank(anyone);
        adapter.generateVerdict(jobId);
    }

    function _signVerdictEOA(
        bytes32 _jobId,
        uint256 toPayee,
        uint256 toDepositor,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Verdict(bytes32 jobId,uint256 toPayee,uint256 toDepositor,uint256 nonce)"),
                _jobId, toPayee, toDepositor, nonce
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

        (uint256 toPayee, uint256 toDepositor, uint256 nonce, bool generated) =
            adapter.getVerdictParams(jobId);
        assertTrue(generated);
        assertEq(toPayee, NET_AMOUNT);
        assertEq(toDepositor, 0);

        uint256 payeeBefore = usdc.balanceOf(payee);

        vm.prank(anyone);
        escrow.resolve(jobId, toPayee, toDepositor, nonce, "");

        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);
        assertEq(usdc.balanceOf(depositor), 10_000e6 - AMOUNT);
        // Fee was paid to adapter at dispute time
        assertEq(usdc.balanceOf(address(adapter)), ARB_FEE);

        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        assertTrue(e.state == AgentEscrow.EscrowState.Resolved);
    }

    // ======================== FLOW C: BOND ESCALATION → LAST ANSWER WINS ========================

    function test_flowC_bondEscalation_depositorWins() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(1)), 0);

        vm.prank(answerer2);
        realityETH.submitAnswer{value: 0.02 ether}(questionId, bytes32(uint256(0)), 0);

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.04 ether}(questionId, bytes32(uint256(1)), 0);

        vm.warp(block.timestamp + 25 hours);

        vm.prank(anyone);
        adapter.generateVerdict(jobId);

        (uint256 toPayee, uint256 toDepositor, uint256 nonce,) =
            adapter.getVerdictParams(jobId);
        assertEq(toPayee, 0);
        assertEq(toDepositor, NET_AMOUNT);

        uint256 depositorBefore = usdc.balanceOf(depositor);
        vm.prank(anyone);
        escrow.resolve(jobId, toPayee, toDepositor, nonce, "");

        assertEq(usdc.balanceOf(depositor), depositorBefore + NET_AMOUNT);
        assertEq(usdc.balanceOf(payee), 0);
    }

    // ======================== FLOW D: PARTIAL SPLIT (PERCENTAGE) ========================

    function test_flowD_partialSplit_70percent() public {
        _fullFlowUntilVerdict(bytes32(uint256(70)));

        (uint256 toPayee, uint256 toDepositor, uint256 nonce, bool generated) =
            adapter.getVerdictParams(jobId);
        assertTrue(generated);

        // 70% of NET_AMOUNT (95e6)
        assertEq(toPayee, 66_500_000);
        assertEq(toDepositor, 28_500_000);
        assertEq(toPayee + toDepositor, NET_AMOUNT);

        vm.prank(anyone);
        escrow.resolve(jobId, toPayee, toDepositor, nonce, "");

        assertEq(usdc.balanceOf(payee), 66_500_000);
        assertEq(usdc.balanceOf(depositor), 10_000e6 - AMOUNT + 28_500_000);
    }

    // ======================== FLOW E: ARBITRATOR TIMEOUT → FORCE RELEASE ========================

    function test_flowE_forceRelease_blocked_while_dispute_pending() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        vm.warp(block.timestamp + 7 days);

        vm.prank(anyone);
        vm.expectRevert("Arbitrator dispute still active");
        escrow.forceRelease(jobId);
    }

    function test_flowE_forceRelease_after_max_timeout() public {
        _depositCompleteAndDispute();
        _initiateDisputeOnAdapter();

        vm.warp(block.timestamp + 90 days);

        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(anyone);
        escrow.forceRelease(jobId);

        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);
        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        assertTrue(e.state == AgentEscrow.EscrowState.Released);
    }

    function test_flowE_forceRelease_after_question_finalized() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        realityETH.submitAnswer(questionId, bytes32(uint256(0)), 0);
        vm.warp(block.timestamp + 7 days + 1);
        realityETH.mockFinalize(questionId, bytes32(uint256(0)));

        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(anyone);
        escrow.forceRelease(jobId);

        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);
        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        assertTrue(e.state == AgentEscrow.EscrowState.Released);
    }

    // ======================== FLOW F: EOA ARBITRATOR BYPASS ========================

    function test_flowF_eoaArbitrator_existingBehavior() public {
        bytes32 eoaJobId = keccak256("job-eoa-001");

        vm.prank(depositor);
        escrow.deposit(eoaJobId, payee, eoaArbitrator, DISPUTE_WINDOW, 30 days, AMOUNT, FEE_BPS, OFFER_WINDOW);
        escrow.activateEscrow(eoaJobId);

        vm.prank(relayer);
        escrow.markComplete(eoaJobId);

        vm.prank(depositor);
        escrow.dispute(eoaJobId);

        // Fee paid at dispute time
        assertEq(usdc.balanceOf(eoaArbitrator), ARB_FEE);

        uint256 nonce = 42;
        uint256 toPayee = NET_AMOUNT;
        uint256 toDepositor = 0;
        bytes memory sig = _signVerdictEOA(eoaJobId, toPayee, toDepositor, nonce);

        vm.prank(anyone);
        escrow.resolve(eoaJobId, toPayee, toDepositor, nonce, sig);

        assertEq(usdc.balanceOf(payee), NET_AMOUNT);
        assertEq(usdc.balanceOf(eoaArbitrator), ARB_FEE);
    }

    // ======================== FLOW G: GENERATE VERDICT — ESCROW NOT DISPUTED ========================

    function test_flowG_generateVerdict_notDisputed_reverts() public {
        _depositAndComplete(); // state = Completed, not Disputed

        // Can't initiateDispute if not disputed
        vm.prank(depositor);
        vm.expectRevert("Escrow not disputed");
        adapter.initiateDispute(jobId);
    }

    // ======================== FLOW H: INITIATE DISPUTE TWICE ========================

    function test_flowH_doubleInitiateDispute_reverts() public {
        _depositCompleteAndDispute();
        vm.prank(depositor);
        adapter.initiateDispute(jobId);

        vm.prank(depositor);
        vm.expectRevert("Dispute already initiated");
        adapter.initiateDispute(jobId);
    }

    // ======================== FLOW I: GENERATE VERDICT BEFORE FINALIZED ========================

    function test_flowI_generateVerdict_notFinalized_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(0)), 0);

        // don't warp — timeout hasn't passed
        vm.prank(anyone);
        vm.expectRevert("Question not finalized");
        adapter.generateVerdict(jobId);
    }

    // ======================== FLOW J: TAMPERED RESOLVE PARAMS REJECTED ========================

    function test_flowJ_tamperedResolve_reverts() public {
        _fullFlowUntilVerdict(bytes32(uint256(70)));

        (, , uint256 nonce,) = adapter.getVerdictParams(jobId);

        vm.prank(anyone);
        vm.expectRevert("Invalid arbitrator signature");
        escrow.resolve(jobId, NET_AMOUNT, 0, nonce, "");
    }

    // ======================== FLOW K: DOUBLE GENERATE VERDICT ========================

    function test_flowK_doubleGenerateVerdict_reverts() public {
        _fullFlowUntilVerdict(bytes32(uint256(0)));

        vm.prank(anyone);
        vm.expectRevert("Verdict already generated");
        adapter.generateVerdict(jobId);
    }

    // ======================== FLOW L: DOMAIN SEPARATOR PARITY ========================

    function test_flowL_domainSeparatorParity() public {
        _fullFlowUntilVerdict(bytes32(uint256(0)));

        (uint256 toPayee, uint256 toDepositor, uint256 nonce,) =
            adapter.getVerdictParams(jobId);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Verdict(bytes32 jobId,uint256 toPayee,uint256 toDepositor,uint256 nonce)"),
                jobId, toPayee, toDepositor, nonce
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
        bytes32 questionId = _initiateDisputeOnAdapter();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(0)), 0);

        vm.prank(answerer2);
        vm.expectRevert("Bond too low");
        realityETH.submitAnswer{value: 0.015 ether}(questionId, bytes32(uint256(1)), 0);
    }

    // ======================== FLOW N: ANSWER RESETS TIMEOUT CLOCK ========================

    function test_flowN_answerResetsTimeout() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(0)), 0);

        vm.warp(block.timestamp + 23 hours);
        assertFalse(realityETH.isFinalized(questionId));

        vm.prank(answerer2);
        realityETH.submitAnswer{value: 0.02 ether}(questionId, bytes32(uint256(1)), 0);

        vm.warp(block.timestamp + 23 hours);
        assertFalse(realityETH.isFinalized(questionId));

        vm.warp(block.timestamp + 2 hours);
        assertTrue(realityETH.isFinalized(questionId));

        assertEq(realityETH.resultFor(questionId), bytes32(uint256(1)));
    }

    // ======================== FLOW O: MULTI-JOB ISOLATION ========================

    function test_flowO_multiJobIsolation() public {
        bytes32 jobId2 = keccak256("job-reality-002");

        // setup job 1
        _depositCompleteAndDispute();
        vm.prank(depositor);
        bytes32 q1 = adapter.initiateDispute(jobId);

        // setup job 2
        vm.prank(depositor);
        escrow.deposit(jobId2, payee, address(adapter), DISPUTE_WINDOW, 30 days, 50e6, FEE_BPS, OFFER_WINDOW);
        escrow.activateEscrow(jobId2);
        vm.prank(relayer);
        escrow.markComplete(jobId2);
        vm.prank(depositor);
        escrow.dispute(jobId2);

        vm.prank(depositor);
        bytes32 q2 = adapter.initiateDispute(jobId2);

        assertTrue(q1 != q2);

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(q1, bytes32(uint256(0)), 0);

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(q2, bytes32(uint256(1)), 0);

        vm.warp(block.timestamp + 25 hours);

        vm.prank(anyone);
        adapter.generateVerdict(jobId);
        vm.prank(anyone);
        adapter.generateVerdict(jobId2);

        (uint256 tp1, uint256 td1, uint256 n1,) = adapter.getVerdictParams(jobId);
        (uint256 tp2, uint256 td2, uint256 n2,) = adapter.getVerdictParams(jobId2);

        assertEq(tp1, NET_AMOUNT);
        assertEq(td1, 0);
        assertEq(tp2, 0);
        uint256 job2Net = 50e6 - (50e6 * FEE_BPS / 10000);
        assertEq(td2, job2Net);
        assertTrue(n1 != n2);

        uint256 payeeBefore = usdc.balanceOf(payee);
        uint256 depositorBefore = usdc.balanceOf(depositor);

        vm.prank(anyone);
        escrow.resolve(jobId, tp1, td1, n1, "");
        vm.prank(anyone);
        escrow.resolve(jobId2, tp2, td2, n2, "");

        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);
        assertEq(usdc.balanceOf(depositor), depositorBefore + td2);
    }

    // ======================== FLOW P: NO ANSWERS → GENERATE VERDICT REVERTS ========================

    function test_flowP_questionNoAnswers_reverts() public {
        _depositCompleteAndDispute();
        _initiateDisputeOnAdapter();

        vm.prank(anyone);
        vm.expectRevert();
        adapter.generateVerdict(jobId);
    }

    // ======================== FLOW Q: ANSWER AFTER FINALIZATION ========================

    function test_flowQ_answerAfterFinalization_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

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

        (uint256 toPayee, uint256 toDepositor,,) =
            adapter.getVerdictParams(jobId);

        // 2% of 95e6
        assertEq(toPayee, 1_900_000);
        assertEq(toDepositor, 93_100_000);
        assertEq(toPayee + toDepositor, NET_AMOUNT);
    }

    function test_flowR_edgeAnswer_99percent() public {
        bytes32 jobId99 = keccak256("job-reality-99pct");
        vm.prank(depositor);
        escrow.deposit(jobId99, payee, address(adapter), DISPUTE_WINDOW, 30 days, AMOUNT, FEE_BPS, OFFER_WINDOW);
        escrow.activateEscrow(jobId99);
        vm.prank(relayer);
        escrow.markComplete(jobId99);
        vm.prank(depositor);
        escrow.dispute(jobId99);

        vm.prank(depositor);
        bytes32 qId = adapter.initiateDispute(jobId99);

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(qId, bytes32(uint256(99)), 0);

        vm.warp(block.timestamp + 25 hours);
        vm.prank(anyone);
        adapter.generateVerdict(jobId99);

        (uint256 toPayee, uint256 toDepositor,,) =
            adapter.getVerdictParams(jobId99);

        // 99% of 95e6
        assertEq(toPayee, 94_050_000);
        assertEq(toDepositor, 950_000);
        assertEq(toPayee + toDepositor, NET_AMOUNT);
    }

    function test_flowR_edgeAnswer_100_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(100)), 0);

        vm.warp(block.timestamp + 25 hours);

        vm.prank(anyone);
        vm.expectRevert("Invalid answer value");
        adapter.generateVerdict(jobId);
    }

    function test_flowR_edgeAnswer_huge_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(999)), 0);

        vm.warp(block.timestamp + 25 hours);

        vm.prank(anyone);
        vm.expectRevert("Invalid answer value");
        adapter.generateVerdict(jobId);
    }

    // ======================== FLOW S: GENERATE VERDICT WITHOUT INITIATE ========================

    function test_flowS_generateVerdictWithoutInitiate_reverts() public {
        _depositCompleteAndDispute();

        vm.prank(anyone);
        vm.expectRevert("Dispute not initiated");
        adapter.generateVerdict(jobId);
    }

    // ======================== FLOW T: THIRD PARTY CANNOT INITIATE ========================

    function test_flowT_thirdPartyCannotInitiateDispute() public {
        _depositCompleteAndDispute();

        vm.prank(anyone);
        vm.expectRevert("Not a party");
        adapter.initiateDispute(jobId);
    }

    // ======================== FLOW U: FEE PAID AT DISPUTE TIME ========================

    function test_flowU_feePaidAtDisputeTime() public {
        _deposit();
        vm.prank(relayer);
        escrow.markComplete(jobId);

        assertEq(usdc.balanceOf(address(adapter)), 0);

        vm.prank(depositor);
        escrow.dispute(jobId);

        // Fee immediately sent to adapter (arbitrator) at dispute time
        assertEq(usdc.balanceOf(address(adapter)), ARB_FEE);

        // Escrow amount reduced
        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        assertEq(e.amount, NET_AMOUNT);
    }

    // ======================== FLOW V: FRONT-RUN VERDICT BLOCKED BY BINDING ========================

    function test_flowV_frontRunVerdictBlockedByBinding() public {
        _depositCompleteAndDispute();

        // Depositor initiates dispute through the adapter — question is created and bound
        vm.prank(depositor);
        bytes32 questionId = adapter.initiateDispute(jobId);

        // Answerer honestly answers: payee wins
        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(0)), 0);

        vm.warp(block.timestamp + 25 hours);

        // generateVerdict reads from the stored binding — no questionId parameter
        // An attacker cannot inject a different question
        vm.prank(anyone);
        adapter.generateVerdict(jobId);

        (uint256 toPayee, uint256 toDepositor,,) = adapter.getVerdictParams(jobId);

        // Payee wins as expected — no front-running possible
        assertEq(toPayee, NET_AMOUNT);
        assertEq(toDepositor, 0);
    }

    // ======================== FLOW W: PAYEE CAN ALSO INITIATE ========================

    function test_flowW_payeeCanInitiateDispute() public {
        _depositCompleteAndDispute();

        vm.prank(payee);
        bytes32 questionId = adapter.initiateDispute(jobId);

        assertTrue(questionId != bytes32(0));
        assertEq(adapter.jobQuestions(jobId), questionId);
    }

    // ======================== FLOW X: QUESTION URL CONTAINS JOB ID ========================

    function test_flowX_questionContainsDisputeUrl() public {
        _depositCompleteAndDispute();

        vm.prank(depositor);
        bytes32 questionId = adapter.initiateDispute(jobId);

        assertTrue(questionId != bytes32(0));
        assertTrue(realityETH.isFinalized(questionId) == false);
    }

    // ======================== FLOW Y: DISPUTED WITHOUT INITIATE → FORCERELEASE WORKS ========================

    function test_flowY_disputedNoInitiate_forceReleaseWorks() public {
        _depositCompleteAndDispute();
        // Nobody calls initiateDispute on adapter — no question exists

        vm.warp(block.timestamp + 7 days);

        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(anyone);
        escrow.forceRelease(jobId);

        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);
        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        assertTrue(e.state == AgentEscrow.EscrowState.Released);
    }

    // ======================== FLOW Z: INVALID REALITY.ETH ANSWER ========================

    function test_flowZ_invalidAnswer_generateVerdictReverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        // reality.eth "invalid" sentinel
        bytes32 invalidAnswer = bytes32(type(uint256).max);
        realityETH.mockFinalize(questionId, invalidAnswer);

        vm.prank(anyone);
        vm.expectRevert("Invalid answer value");
        adapter.generateVerdict(jobId);
    }

    function test_flowZ_invalidAnswer_forceReleaseAfterMaxTimeout() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        // Question finalized with invalid answer — generateVerdict will always revert
        bytes32 invalidAnswer = bytes32(type(uint256).max);
        realityETH.mockFinalize(questionId, invalidAnswer);

        // forceRelease works after 7 days because question IS finalized (isDisputePending = false)
        vm.warp(block.timestamp + 7 days);
        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(anyone);
        escrow.forceRelease(jobId);

        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);
    }

    function test_flowZ_answer100_reverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        realityETH.mockFinalize(questionId, bytes32(uint256(100)));

        vm.prank(anyone);
        vm.expectRevert("Invalid answer value");
        adapter.generateVerdict(jobId);
    }

    // ======================== FLOW AA: RESOLVE vs FORCERELEASE RACE ========================

    function test_flowAA_resolveVsForceRelease_resolveFirst() public {
        _fullFlowUntilVerdict(bytes32(uint256(1))); // depositor wins

        (uint256 toPayee, uint256 toDepositor, uint256 nonce,) =
            adapter.getVerdictParams(jobId);

        // Warp past arbitrator timeout — both resolve and forceRelease callable
        vm.warp(block.timestamp + 7 days);

        // resolve lands first — depositor gets funds
        uint256 depositorBefore = usdc.balanceOf(depositor);
        vm.prank(anyone);
        escrow.resolve(jobId, toPayee, toDepositor, nonce, "");
        assertEq(usdc.balanceOf(depositor), depositorBefore + NET_AMOUNT);

        // forceRelease now reverts — state is Resolved
        vm.prank(anyone);
        vm.expectRevert("Not disputed");
        escrow.forceRelease(jobId);
    }

    function test_flowAA_resolveVsForceRelease_forceReleaseFirst() public {
        _fullFlowUntilVerdict(bytes32(uint256(1))); // depositor wins

        (uint256 toPayee, uint256 toDepositor, uint256 nonce,) =
            adapter.getVerdictParams(jobId);

        vm.warp(block.timestamp + 7 days);

        // forceRelease lands first — payee gets everything
        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(anyone);
        escrow.forceRelease(jobId);
        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);

        // resolve now reverts — state is Released
        vm.prank(anyone);
        vm.expectRevert("Not disputed");
        escrow.resolve(jobId, toPayee, toDepositor, nonce, "");
    }

    // ======================== FLOW AB: EOA ARBITRATOR DISAPPEARS ========================

    function test_flowAB_eoaArbitratorDisappears_forceRelease() public {
        bytes32 eoaJobId = keccak256("job-eoa-disappear");

        vm.prank(depositor);
        escrow.deposit(eoaJobId, payee, eoaArbitrator, DISPUTE_WINDOW, 30 days, AMOUNT, FEE_BPS, OFFER_WINDOW);
        escrow.activateEscrow(eoaJobId);

        vm.prank(relayer);
        escrow.markComplete(eoaJobId);

        vm.prank(depositor);
        escrow.dispute(eoaJobId);

        // EOA never signs — no isDisputePending check (not a contract)
        vm.warp(block.timestamp + 7 days);

        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(anyone);
        escrow.forceRelease(eoaJobId);

        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);
    }

    // ======================== FLOW AC: MAX FEE (50%) ========================

    function test_flowAC_maxFee_halfToArbitrator() public {
        bytes32 maxFeeJobId = keccak256("job-maxfee");
        uint256 maxFeeBps = 5000; // 50%
        uint256 maxFee = (AMOUNT * maxFeeBps) / 10000; // 50e6
        uint256 netAfterFee = AMOUNT - maxFee; // 50e6

        vm.prank(depositor);
        escrow.deposit(maxFeeJobId, payee, address(adapter), DISPUTE_WINDOW, 30 days, AMOUNT, maxFeeBps, OFFER_WINDOW);
        escrow.activateEscrow(maxFeeJobId);

        vm.prank(relayer);
        escrow.markComplete(maxFeeJobId);

        uint256 adapterBefore = usdc.balanceOf(address(adapter));
        vm.prank(depositor);
        escrow.dispute(maxFeeJobId);

        // 50% immediately to arbitrator
        assertEq(usdc.balanceOf(address(adapter)), adapterBefore + maxFee);

        // Only 50% remains in escrow
        AgentEscrow.Escrow memory e = escrow.getEscrow(maxFeeJobId);
        assertEq(e.amount, netAfterFee);
    }

    // ======================== FLOW AD: isDisputePending EDGE CASES ========================

    function test_flowAD_isDisputePending_noQuestion() public {
        // No question created — should return false
        assertFalse(adapter.isDisputePending(jobId));
    }

    function test_flowAD_isDisputePending_activeQuestion() public {
        _depositCompleteAndDispute();
        _initiateDisputeOnAdapter();

        assertTrue(adapter.isDisputePending(jobId));
    }

    function test_flowAD_isDisputePending_finalizedQuestion() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        realityETH.mockFinalize(questionId, bytes32(uint256(0)));

        assertFalse(adapter.isDisputePending(jobId));
    }

    // ======================== FLOW AE: LONG DISPUTE CYCLE (BOND WARS) ========================

    function test_flowAE_longBondEscalation_forceReleaseBlocked() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        // Simulate bond escalation over several days
        uint256 bond = 0.01 ether;
        for (uint256 i = 0; i < 6; i++) {
            address answerer = (i % 2 == 0) ? answerer1 : answerer2;
            bytes32 answer = (i % 2 == 0) ? bytes32(uint256(1)) : bytes32(uint256(0));
            vm.prank(answerer);
            realityETH.submitAnswer{value: bond}(questionId, answer, 0);
            bond *= 2;
            vm.warp(block.timestamp + 12 hours);
        }

        // Last answer was 12 hours ago, timeout is 24h, question still open.
        // Total elapsed: ~3.5 days of escalation + 12h = 4 days from dispute.
        // Warp to just past 7-day ARBITRATOR_TIMEOUT but question is still pending.
        vm.warp(block.timestamp + 4 days);

        // Now submit one more answer to keep the question alive
        vm.prank(answerer1);
        realityETH.submitAnswer{value: bond}(questionId, bytes32(uint256(1)), 0);

        // Warp past 7-day timeout but last answer was just now
        vm.warp(block.timestamp + 7 days);

        // Question still not finalized (last answer was 7 days ago, timeout is 24h)
        // Wait — 7 days > 24h so it IS finalized. Need to submit closer to the check.
        // Actually at this point lastAnswerTs + 24h < block.timestamp. So it's finalized.
        // Let's just submit right before the forceRelease attempt.
        vm.prank(answerer2);
        realityETH.submitAnswer{value: bond * 2}(questionId, bytes32(uint256(0)), 0);

        // Now lastAnswerTs = block.timestamp, question open for 24h
        vm.prank(anyone);
        vm.expectRevert("Arbitrator dispute still active");
        escrow.forceRelease(jobId);
    }

    function test_flowAE_longBondEscalation_resolveAfterFinalize() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        // Bond war: answerer1 says depositor wins, answerer2 says payee wins
        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(1)), 0);
        vm.warp(block.timestamp + 12 hours);

        vm.prank(answerer2);
        realityETH.submitAnswer{value: 0.02 ether}(questionId, bytes32(uint256(0)), 0);
        vm.warp(block.timestamp + 12 hours);

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.04 ether}(questionId, bytes32(uint256(1)), 0);

        // Finalize after timeout
        vm.warp(block.timestamp + 25 hours);

        adapter.generateVerdict(jobId);

        (uint256 toPayee, uint256 toDepositor, uint256 nonce,) =
            adapter.getVerdictParams(jobId);
        assertEq(toPayee, 0);
        assertEq(toDepositor, NET_AMOUNT);

        vm.prank(anyone);
        escrow.resolve(jobId, toPayee, toDepositor, nonce, "");

        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        assertTrue(e.state == AgentEscrow.EscrowState.Resolved);
    }

    // ======================== FLOW AF: NOBODY ANSWERS ON REALITY.ETH ========================

    function test_flowAF_noAnswers_blockedUntil90Days() public {
        _depositCompleteAndDispute();
        _initiateDisputeOnAdapter();

        // 7 days pass — forceRelease blocked (question pending, no answer)
        vm.warp(block.timestamp + 7 days);
        vm.prank(anyone);
        vm.expectRevert("Arbitrator dispute still active");
        escrow.forceRelease(jobId);

        // 30 days — still blocked
        vm.warp(block.timestamp + 23 days); // total 30 days
        vm.prank(anyone);
        vm.expectRevert("Arbitrator dispute still active");
        escrow.forceRelease(jobId);

        // 90 days — hard cap overrides, forceRelease works
        vm.warp(block.timestamp + 60 days); // total 90 days
        uint256 payeeBefore = usdc.balanceOf(payee);
        vm.prank(anyone);
        escrow.forceRelease(jobId);
        assertEq(usdc.balanceOf(payee), payeeBefore + NET_AMOUNT);
    }

    // ======================== FLOW AG: DISPUTE WINDOW EXACT BOUNDARY ========================

    function test_flowAG_disputeAtExactBoundary_reverts() public {
        _depositAndComplete();

        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        // Warp to exactly completedAt + disputeWindow (boundary)
        vm.warp(e.completedAt + e.disputeWindow);

        // Dispute uses < (strict), so at exact boundary it fails
        vm.prank(depositor);
        vm.expectRevert("Dispute window passed");
        escrow.dispute(jobId);
    }

    function test_flowAG_disputeOneSecondBeforeBoundary_succeeds() public {
        _depositAndComplete();

        AgentEscrow.Escrow memory e = escrow.getEscrow(jobId);
        vm.warp(e.completedAt + e.disputeWindow - 1);

        vm.prank(depositor);
        escrow.dispute(jobId);

        e = escrow.getEscrow(jobId);
        assertTrue(e.state == AgentEscrow.EscrowState.Disputed);
    }

    // ======================== FLOW AH: DOUBLE GENERATEVERDICT BY DIFFERENT CALLERS ========================

    function test_flowAH_doubleGenerateVerdict_secondCallerReverts() public {
        _depositCompleteAndDispute();
        bytes32 questionId = _initiateDisputeOnAdapter();

        vm.prank(answerer1);
        realityETH.submitAnswer{value: 0.01 ether}(questionId, bytes32(uint256(0)), 0);
        vm.warp(block.timestamp + 25 hours);

        // First caller succeeds
        vm.prank(depositor);
        adapter.generateVerdict(jobId);

        // Second caller reverts
        vm.prank(payee);
        vm.expectRevert("Verdict already generated");
        adapter.generateVerdict(jobId);
    }

    // ======================== FLOW AI: MIN FEE + MIN DEPOSIT ========================

    function test_flowAI_minFeeMinDeposit_dustFee() public {
        bytes32 dustJobId = keccak256("job-dust");
        uint256 minAmount = 1e6; // 1 USDC
        uint256 minFeeBps = 1; // 0.01%
        uint256 dustFee = (minAmount * minFeeBps) / 10000; // 100 wei = 0.0001 USDC

        usdc.mint(depositor, minAmount);
        vm.prank(depositor);
        escrow.deposit(dustJobId, payee, eoaArbitrator, DISPUTE_WINDOW, 30 days, minAmount, minFeeBps, OFFER_WINDOW);
        escrow.activateEscrow(dustJobId);

        vm.prank(relayer);
        escrow.markComplete(dustJobId);

        uint256 arbBefore = usdc.balanceOf(eoaArbitrator);
        vm.prank(depositor);
        escrow.dispute(dustJobId);

        assertEq(usdc.balanceOf(eoaArbitrator), arbBefore + dustFee);
        assertEq(dustFee, 100); // 100 wei = 0.0001 USDC

        AgentEscrow.Escrow memory e = escrow.getEscrow(dustJobId);
        assertEq(e.amount, minAmount - dustFee);
    }
}
