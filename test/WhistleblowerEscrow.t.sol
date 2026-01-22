// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {WhistleblowerEscrow} from "../src/WhistleblowerEscrow.sol";

contract WhistleblowerEscrowTest is Test {
    WhistleblowerEscrow public escrow;

    address public owner = address(0x1);
    address public agent = address(0x2);
    address public whistleblower = address(0x3);
    address public journalist = address(0x4);
    address public otherUser = address(0x5);

    bytes32 public ipfsCIDHash = keccak256("QmTestHash123");
    bytes32 public categoryHash = keccak256("corruption");

    uint256 public constant MIN_STAKE = 0.1 ether;
    uint256 public constant MAX_ACCESS_FEE = 100 ether;
    uint256 public constant TIMEOUT = 7 days;

    event SubmissionCreated(
        uint256 indexed id,
        address indexed whistleblower,
        bytes32 ipfsCIDHash,
        uint256 accessFee,
        uint256 timestamp
    );

    event SubmissionEvaluated(
        uint256 indexed id,
        uint8 finalScore,
        string recommendedAction
    );

    event SubmissionAccessed(
        uint256 indexed id,
        address indexed journalist,
        uint256 amount,
        uint256 timestamp
    );

    event FundsWithdrawn(address indexed to, uint256 amount);
    event SubmissionCancelled(uint256 indexed id);
    event SubmissionTimedOut(uint256 indexed id);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event StakeSlashed(uint256 indexed id, uint256 amount);
    event JournalistRegistered(address indexed journalist, string metadata);
    event JournalistApprovalUpdated(address indexed journalist, bool approved);

    function setUp() public {
        vm.prank(owner);
        escrow = new WhistleblowerEscrow(agent);
        
        // Fund test accounts
        vm.deal(whistleblower, 10 ether);
        vm.deal(journalist, 10 ether);
        vm.deal(agent, 10 ether);
        vm.deal(otherUser, 10 ether);
    }

    // ============ Constructor Tests ============

    function testConstructor_SetsOwnerAndAgent() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.authorizedAgent(), agent);
    }

    function testConstructor_RevertsOnZeroAgent() public {
        vm.prank(owner);
        vm.expectRevert("Invalid agent address");
        new WhistleblowerEscrow(address(0));
    }

    // ============ Whistleblower: createSubmission Tests ============

    function testCreateSubmission_Success() public {
        uint256 accessFee = 1 ether;
        
        vm.prank(whistleblower);
        vm.expectEmit(true, true, false, true);
        emit SubmissionCreated(1, whistleblower, ipfsCIDHash, accessFee, block.timestamp);
        
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            accessFee,
            false
        );

        assertEq(id, 1);
        
        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(1);
        assertEq(sub.id, 1);
        assertEq(sub.ipfsCIDHash, ipfsCIDHash);
        assertEq(sub.categoryHash, categoryHash);
        assertEq(sub.source, whistleblower);
        assertEq(sub.accessFee, accessFee);
        assertEq(sub.stakeAmount, MIN_STAKE);
        assertEq(uint8(sub.status), uint8(WhistleblowerEscrow.SubmissionStatus.Pending));
        assertTrue(sub.exists);
    }

    function testCreateSubmission_Anonymous() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            true // anonymous
        );

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        assertEq(sub.source, address(0));
    }

    function testCreateSubmission_InsufficientStake() public {
        vm.prank(whistleblower);
        vm.expectRevert("Insufficient stake");
        escrow.createSubmission{value: MIN_STAKE - 1}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );
    }

    function testCreateSubmission_EmptyIPFSHash() public {
        vm.prank(whistleblower);
        vm.expectRevert("Empty IPFS hash");
        escrow.createSubmission{value: MIN_STAKE}(
            bytes32(0),
            categoryHash,
            1 ether,
            false
        );
    }

    function testCreateSubmission_ZeroFee() public {
        vm.prank(whistleblower);
        vm.expectRevert("Fee must be positive");
        escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            0,
            false
        );
    }

    function testCreateSubmission_ExcessiveFee() public {
        vm.prank(whistleblower);
        vm.expectRevert("Fee exceeds maximum");
        escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            MAX_ACCESS_FEE + 1,
            false
        );
    }

    function testCreateSubmission_LimitReached() public {
        vm.startPrank(whistleblower);
        
        // Create 10 submissions (the max)
        for (uint256 i = 0; i < 10; i++) {
            escrow.createSubmission{value: MIN_STAKE}(
                keccak256(abi.encodePacked("hash", i)),
                categoryHash,
                1 ether,
                false
            );
        }
        
        // 11th should fail
        vm.expectRevert("Submission limit reached");
        escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );
        
        vm.stopPrank();
    }

    function testCreateSubmission_WhenPaused() public {
        vm.prank(owner);
        escrow.pause();
        
        vm.prank(whistleblower);
        vm.expectRevert();
        escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );
    }

    // ============ Whistleblower: cancelSubmission Tests ============

    function testCancelSubmission_Success() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(whistleblower);
        vm.expectEmit(true, false, false, false);
        emit SubmissionCancelled(id);
        escrow.cancelSubmission(id);

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        assertEq(uint8(sub.status), uint8(WhistleblowerEscrow.SubmissionStatus.Cancelled));
        
        // Check stake credited to pending withdrawals
        assertEq(escrow.pendingWithdrawals(whistleblower), MIN_STAKE);
    }

    function testCancelSubmission_NotOwner() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(otherUser);
        vm.expectRevert("Not your submission");
        escrow.cancelSubmission(id);
    }

    function testCancelSubmission_NotPending() public {
        // Create and verify a submission
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(agent);
        escrow.recordEvaluation(id, 80, "grant_access");

        vm.prank(whistleblower);
        vm.expectRevert("Cannot cancel: not pending");
        escrow.cancelSubmission(id);
    }

    function testCancelSubmission_NotFound() public {
        vm.prank(whistleblower);
        vm.expectRevert("Submission not found");
        escrow.cancelSubmission(999);
    }

    // ============ Whistleblower: withdrawFunds Tests ============

    function testWithdrawFunds_Success() public {
        // Create and cancel to get stake in pending
        vm.startPrank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );
        escrow.cancelSubmission(id);
        
        uint256 balanceBefore = whistleblower.balance;
        
        vm.expectEmit(true, false, false, true);
        emit FundsWithdrawn(whistleblower, MIN_STAKE);
        escrow.withdrawFunds();
        
        assertEq(whistleblower.balance, balanceBefore + MIN_STAKE);
        assertEq(escrow.pendingWithdrawals(whistleblower), 0);
        vm.stopPrank();
    }

    function testWithdrawFunds_NothingToWithdraw() public {
        vm.prank(whistleblower);
        vm.expectRevert("Nothing to withdraw");
        escrow.withdrawFunds();
    }

    // ============ Journalist: registerJournalist Tests ============

    function testRegisterJournalist_Success() public {
        string memory metadata = "ipfs://journalist-credentials";
        
        vm.prank(journalist);
        vm.expectEmit(true, false, false, true);
        emit JournalistRegistered(journalist, metadata);
        escrow.registerJournalist(metadata);

        (bool exists, bool approved, string memory storedMetadata) = escrow.journalists(journalist);
        assertTrue(exists);
        assertFalse(approved);
        assertEq(storedMetadata, metadata);
    }

    function testRegisterJournalist_AlreadyRegistered() public {
        vm.startPrank(journalist);
        escrow.registerJournalist("metadata1");
        
        vm.expectRevert("Already registered");
        escrow.registerJournalist("metadata2");
        vm.stopPrank();
    }

    // ============ Journalist: accessSubmission Tests ============

    function _setupVerifiedSubmission() internal returns (uint256) {
        // Create submission
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        // Verify it
        vm.prank(agent);
        escrow.recordEvaluation(id, 80, "grant_access");

        // Register and approve journalist
        vm.prank(journalist);
        escrow.registerJournalist("credentials");
        
        vm.prank(agent);
        escrow.approveJournalist(journalist, true);

        return id;
    }

    function testAccessSubmission_Success() public {
        uint256 id = _setupVerifiedSubmission();
        uint256 accessFee = escrow.getSubmission(id).accessFee;

        vm.prank(journalist);
        vm.expectEmit(true, true, false, false);
        emit SubmissionAccessed(id, journalist, accessFee, block.timestamp);
        bytes32 token = escrow.accessSubmission{value: accessFee}(id);

        assertTrue(token != bytes32(0));
        
        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        assertEq(uint8(sub.status), uint8(WhistleblowerEscrow.SubmissionStatus.Accessed));
        assertEq(sub.journalist, journalist);
        
        // Check whistleblower credited with fee + stake
        assertEq(escrow.pendingWithdrawals(whistleblower), accessFee + MIN_STAKE);
    }

    function testAccessSubmission_RefundsExcess() public {
        uint256 id = _setupVerifiedSubmission();
        uint256 accessFee = escrow.getSubmission(id).accessFee;
        uint256 overpayment = 0.5 ether;

        uint256 journalistBalanceBefore = journalist.balance;

        vm.prank(journalist);
        escrow.accessSubmission{value: accessFee + overpayment}(id);

        // Journalist should get overpayment refunded
        assertEq(journalist.balance, journalistBalanceBefore - accessFee);
    }

    function testAccessSubmission_NotVerified() public {
        // Create but don't verify
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(journalist);
        escrow.registerJournalist("credentials");
        
        vm.prank(agent);
        escrow.approveJournalist(journalist, true);

        vm.prank(journalist);
        vm.expectRevert("Not verified for access");
        escrow.accessSubmission{value: 1 ether}(id);
    }

    function testAccessSubmission_InsufficientPayment() public {
        uint256 id = _setupVerifiedSubmission();
        uint256 accessFee = escrow.getSubmission(id).accessFee;

        vm.prank(journalist);
        vm.expectRevert("Insufficient payment");
        escrow.accessSubmission{value: accessFee - 1}(id);
    }

    function testAccessSubmission_JournalistNotApproved() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(agent);
        escrow.recordEvaluation(id, 80, "grant_access");

        // Register but don't approve
        vm.prank(journalist);
        escrow.registerJournalist("credentials");

        vm.prank(journalist);
        vm.expectRevert("Journalist not approved");
        escrow.accessSubmission{value: 1 ether}(id);
    }

    function testAccessSubmission_NotExists() public {
        vm.prank(journalist);
        vm.expectRevert("Submission does not exist");
        escrow.accessSubmission{value: 1 ether}(999);
    }

    // ============ Agent: recordEvaluation Tests ============

    function testRecordEvaluation_Verifies() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(agent);
        vm.expectEmit(true, false, false, true);
        emit SubmissionEvaluated(id, 80, "grant_access");
        escrow.recordEvaluation(id, 80, "grant_access");

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        assertEq(uint8(sub.status), uint8(WhistleblowerEscrow.SubmissionStatus.Verified));

        (uint256 subId, uint8 score, string memory action, uint256 evaluatedAt) = escrow.evaluations(id);
        assertEq(subId, id);
        assertEq(score, 80);
        assertEq(action, "grant_access");
        assertTrue(evaluatedAt > 0);
    }

    function testRecordEvaluation_StaysPendingBelowThreshold() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(agent);
        escrow.recordEvaluation(id, 69, "manual_review");

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        // Status stays Pending when score < 70
        assertEq(uint8(sub.status), uint8(WhistleblowerEscrow.SubmissionStatus.Pending));
    }

    function testRecordEvaluation_ExactThreshold() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(agent);
        escrow.recordEvaluation(id, 70, "grant_access");

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        assertEq(uint8(sub.status), uint8(WhistleblowerEscrow.SubmissionStatus.Verified));
    }

    function testRecordEvaluation_OnlyAgent() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(otherUser);
        vm.expectRevert("Unauthorized: not agent");
        escrow.recordEvaluation(id, 80, "grant_access");
    }

    function testRecordEvaluation_InvalidScore() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(agent);
        vm.expectRevert("Score must be 0-100");
        escrow.recordEvaluation(id, 101, "invalid");
    }

    function testRecordEvaluation_AlreadyEvaluated() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(agent);
        escrow.recordEvaluation(id, 80, "grant_access");

        vm.prank(agent);
        vm.expectRevert("Already evaluated");
        escrow.recordEvaluation(id, 90, "another");
    }

    // ============ Agent: approveJournalist Tests ============

    function testApproveJournalist_Success() public {
        vm.prank(journalist);
        escrow.registerJournalist("credentials");

        vm.prank(agent);
        vm.expectEmit(true, false, false, true);
        emit JournalistApprovalUpdated(journalist, true);
        escrow.approveJournalist(journalist, true);

        (, bool approved,) = escrow.journalists(journalist);
        assertTrue(approved);
    }

    function testApproveJournalist_Revoke() public {
        vm.prank(journalist);
        escrow.registerJournalist("credentials");

        vm.prank(agent);
        escrow.approveJournalist(journalist, true);

        vm.prank(agent);
        escrow.approveJournalist(journalist, false);

        (, bool approved,) = escrow.journalists(journalist);
        assertFalse(approved);
    }

    function testApproveJournalist_NotRegistered() public {
        vm.prank(agent);
        vm.expectRevert("Journalist not registered");
        escrow.approveJournalist(journalist, true);
    }

    function testApproveJournalist_OnlyAgent() public {
        vm.prank(journalist);
        escrow.registerJournalist("credentials");

        vm.prank(otherUser);
        vm.expectRevert("Unauthorized: not agent");
        escrow.approveJournalist(journalist, true);
    }

    // ============ Agent: slashStake Tests ============

    function testSlashStake_Success() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        // Evaluate with low score
        vm.prank(agent);
        escrow.recordEvaluation(id, 30, "defer");

        vm.prank(agent);
        vm.expectEmit(true, false, false, true);
        emit StakeSlashed(id, MIN_STAKE);
        escrow.slashStake(id);

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        assertEq(sub.stakeAmount, 0);
        assertEq(uint8(sub.status), uint8(WhistleblowerEscrow.SubmissionStatus.Disputed));
        
        // Stake goes to agent
        assertEq(escrow.pendingWithdrawals(agent), MIN_STAKE);
    }

    function testSlashStake_HighScore() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(agent);
        escrow.recordEvaluation(id, 80, "grant_access");

        vm.prank(agent);
        vm.expectRevert("Cannot slash: score too high");
        escrow.slashStake(id);
    }

    function testSlashStake_NotEvaluated() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(agent);
        vm.expectRevert("Not evaluated");
        escrow.slashStake(id);
    }

    // ============ Admin: setAgent Tests ============

    function testSetAgent_Success() public {
        address newAgent = address(0x999);
        
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit AgentUpdated(agent, newAgent);
        escrow.setAgent(newAgent);

        assertEq(escrow.authorizedAgent(), newAgent);
    }

    function testSetAgent_NotOwner() public {
        vm.prank(otherUser);
        vm.expectRevert();
        escrow.setAgent(address(0x999));
    }

    function testSetAgent_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid address");
        escrow.setAgent(address(0));
    }

    // ============ Admin: pause/unpause Tests ============

    function testPause_Success() public {
        vm.prank(owner);
        escrow.pause();
        assertTrue(escrow.paused());
    }

    function testUnpause_Success() public {
        vm.prank(owner);
        escrow.pause();
        
        vm.prank(owner);
        escrow.unpause();
        assertFalse(escrow.paused());
    }

    function testPause_NotOwner() public {
        vm.prank(otherUser);
        vm.expectRevert();
        escrow.pause();
    }

    // ============ Timeout Refund Tests ============

    function testTimeoutRefund_Success() public {
        uint256 id = _setupVerifiedSubmission();
        uint256 accessFee = escrow.getSubmission(id).accessFee;

        // Journalist accesses
        vm.prank(journalist);
        escrow.accessSubmission{value: accessFee}(id);

        // Warp past timeout
        vm.warp(block.timestamp + TIMEOUT + 1);

        vm.expectEmit(true, false, false, false);
        emit SubmissionTimedOut(id);
        escrow.timeoutRefund(id);

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        assertEq(uint8(sub.status), uint8(WhistleblowerEscrow.SubmissionStatus.Refunded));
        
        // Access fee goes back to journalist
        assertEq(escrow.pendingWithdrawals(journalist), accessFee);
    }

    function testTimeoutRefund_TooEarly() public {
        uint256 id = _setupVerifiedSubmission();
        uint256 accessFee = escrow.getSubmission(id).accessFee;

        vm.prank(journalist);
        escrow.accessSubmission{value: accessFee}(id);

        // Warp to just before timeout
        vm.warp(block.timestamp + TIMEOUT - 1);

        vm.expectRevert("Timeout not reached");
        escrow.timeoutRefund(id);
    }

    function testTimeoutRefund_NotAccessed() public {
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsCIDHash,
            categoryHash,
            1 ether,
            false
        );

        vm.expectRevert("Not refundable");
        escrow.timeoutRefund(id);
    }

    // ============ Fallback Tests ============

    function testReceive_Reverts() public {
        vm.deal(otherUser, 2 ether);
        vm.prank(otherUser);
        (bool success,) = address(escrow).call{value: 1 ether}("");
        assertFalse(success);
    }

    function testFallback_Reverts() public {
        vm.deal(otherUser, 2 ether);
        vm.prank(otherUser);
        (bool success,) = address(escrow).call{value: 1 ether}(hex"12345678");
        assertFalse(success);
    }

    // ============ View Function Tests ============

    function testGetSubmission_NotFound() public {
        vm.expectRevert("Submission not found");
        escrow.getSubmission(999);
    }
}
