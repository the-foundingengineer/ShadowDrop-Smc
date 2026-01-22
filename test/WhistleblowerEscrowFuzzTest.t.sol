// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WhistleblowerEscrow} from "../src/WhistleblowerEscrow.sol";

contract WhistleblowerEscrowFuzzTest is Test {
    WhistleblowerEscrow public escrow;

    address public owner = address(0x1);
    address public agent = address(0x2);
    address public whistleblower = address(0x3);
    address public journalist = address(0x4);

    uint256 public constant MIN_STAKE = 0.1 ether;
    uint256 public constant MAX_ACCESS_FEE = 100 ether;

    function setUp() public {
        vm.prank(owner);
        escrow = new WhistleblowerEscrow(agent);
        
        vm.deal(whistleblower, 1000 ether);
        vm.deal(journalist, 1000 ether);
    }

    /// @notice Fuzz test createSubmission with random valid parameters
    function testFuzz_CreateSubmission_ValidFee(uint256 accessFee) public {
        // Bound fee to valid range
        accessFee = bound(accessFee, 1, MAX_ACCESS_FEE);
        
        bytes32 ipfsHash = keccak256(abi.encodePacked("test", accessFee));
        bytes32 categoryHash = keccak256("test-category");

        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsHash,
            categoryHash,
            accessFee,
            false
        );

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        assertEq(sub.accessFee, accessFee);
        assertEq(sub.stakeAmount, MIN_STAKE);
        assertTrue(sub.exists);
    }

    /// @notice Fuzz test with variable stake amounts above minimum
    function testFuzz_CreateSubmission_ValidStake(uint256 stakeAmount) public {
        // Bound stake to valid range (min stake to 10 ether)
        stakeAmount = bound(stakeAmount, MIN_STAKE, 10 ether);
        
        bytes32 ipfsHash = keccak256(abi.encodePacked("test", stakeAmount));
        bytes32 categoryHash = keccak256("test-category");

        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: stakeAmount}(
            ipfsHash,
            categoryHash,
            1 ether,
            false
        );

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        assertEq(sub.stakeAmount, stakeAmount);
    }

    /// @notice Fuzz test recordEvaluation with valid scores
    function testFuzz_RecordEvaluation_ValidScore(uint8 score) public {
        // Bound score to valid range
        score = uint8(bound(score, 0, 100));
        
        bytes32 ipfsHash = keccak256(abi.encodePacked("test", score));
        bytes32 categoryHash = keccak256("test-category");

        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsHash,
            categoryHash,
            1 ether,
            false
        );

        vm.prank(agent);
        escrow.recordEvaluation(id, score, "test_action");

        (uint256 subId, uint8 storedScore, , uint256 evaluatedAt) = escrow.evaluations(id);
        assertEq(subId, id);
        assertEq(storedScore, score);
        assertTrue(evaluatedAt > 0);

        // Verify status based on threshold
        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        if (score >= 70) {
            assertEq(uint8(sub.status), uint8(WhistleblowerEscrow.SubmissionStatus.Verified));
        } else {
            assertEq(uint8(sub.status), uint8(WhistleblowerEscrow.SubmissionStatus.Pending));
        }
    }

    /// @notice Fuzz test accessSubmission with various payment amounts
    function testFuzz_AccessSubmission_Overpayment(uint256 extraPayment) public {
        // Bound extra payment to reasonable range
        extraPayment = bound(extraPayment, 0, 10 ether);
        
        uint256 accessFee = 1 ether;
        bytes32 ipfsHash = keccak256("test-fuzz-access");
        bytes32 categoryHash = keccak256("test-category");

        // Create verified submission
        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsHash,
            categoryHash,
            accessFee,
            false
        );

        vm.prank(agent);
        escrow.recordEvaluation(id, 80, "grant_access");

        // Register and approve journalist
        vm.prank(journalist);
        escrow.registerJournalist("credentials");
        
        vm.prank(agent);
        escrow.approveJournalist(journalist, true);

        uint256 journalistBalanceBefore = journalist.balance;
        uint256 totalPayment = accessFee + extraPayment;

        vm.prank(journalist);
        escrow.accessSubmission{value: totalPayment}(id);

        // Verify excess was refunded
        assertEq(journalist.balance, journalistBalanceBefore - accessFee);
        
        // Verify whistleblower credited
        assertEq(escrow.pendingWithdrawals(whistleblower), accessFee + MIN_STAKE);
    }

    /// @notice Fuzz test with random IPFS hashes
    function testFuzz_CreateSubmission_RandomHashes(bytes32 ipfsHash) public {
        // Skip zero hash (invalid)
        vm.assume(ipfsHash != bytes32(0));
        
        bytes32 categoryHash = keccak256("test-category");

        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsHash,
            categoryHash,
            1 ether,
            false
        );

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        assertEq(sub.ipfsCIDHash, ipfsHash);
    }

    /// @notice Fuzz test anonymous flag consistency
    function testFuzz_CreateSubmission_AnonymousFlag(bool isAnonymous) public {
        bytes32 ipfsHash = keccak256(abi.encodePacked("test", isAnonymous));
        bytes32 categoryHash = keccak256("test-category");

        vm.prank(whistleblower);
        uint256 id = escrow.createSubmission{value: MIN_STAKE}(
            ipfsHash,
            categoryHash,
            1 ether,
            isAnonymous
        );

        WhistleblowerEscrow.Submission memory sub = escrow.getSubmission(id);
        
        if (isAnonymous) {
            assertEq(sub.source, address(0));
        } else {
            assertEq(sub.source, whistleblower);
        }
    }

    /// @notice Test invariant: submission count always increases
    function testFuzz_SubmissionCount_AlwaysIncreases(uint8 numSubmissions) public {
        // Bound to reasonable number
        numSubmissions = uint8(bound(numSubmissions, 1, 10));
        
        vm.startPrank(whistleblower);
        
        for (uint8 i = 0; i < numSubmissions; i++) {
            bytes32 ipfsHash = keccak256(abi.encodePacked("test", i));
            uint256 id = escrow.createSubmission{value: MIN_STAKE}(
                ipfsHash,
                keccak256("category"),
                1 ether,
                false
            );
            assertEq(id, i + 1);
        }
        
        assertEq(escrow.submissionCount(), numSubmissions);
        vm.stopPrank();
    }
}
