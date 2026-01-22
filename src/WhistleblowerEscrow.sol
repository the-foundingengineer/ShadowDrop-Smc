// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title WhistleblowerEscrow
 * @notice Handles anonymous submissions, encrypted evidence storage via IPFS, 
 *         and payment flows between whistleblowers and journalists.
 * @dev Uses pull pattern for withdrawals and ReentrancyGuard for payment security.
 */
contract WhistleblowerEscrow is Ownable, ReentrancyGuard, Pausable {
    
    // ============ Enums ============
    
    enum SubmissionStatus {
        Pending,      // Awaiting agent evaluation
        Verified,     // Agent scored >= 70
        Accessed,     // Journalist paid and accessed
        Disputed,     // Under review / slashed
        Cancelled,    // Whistleblower cancelled
        Refunded      // Timeout refund issued
    }

    // ============ Structs ============

    struct Submission {
        uint256 id;
        bytes32 ipfsCIDHash;        // keccak256 of encrypted IPFS CID
        bytes32 categoryHash;       // keccak256 of category string
        address payable source;     // whistleblower address (zero for anonymous)
        uint256 accessFee;          // in wei
        uint256 createdAt;
        uint256 fundedAt;           // timestamp when journalist paid
        uint256 stakeAmount;        // whistleblower's stake
        SubmissionStatus status;
        address journalist;         // assigned journalist
        bool exists;
    }

    struct Evaluation {
        uint256 submissionId;
        uint8 finalScore;           // 0-100
        string recommendedAction;   // "grant_access" | "manual_review" | "defer"
        uint256 evaluatedAt;
    }

    struct JournalistProfile {
        bool exists;
        bool approved;
        string metadata;            // IPFS hash or JSON (name, outlet, proof)
    }

    // ============ Constants ============

    uint8 public constant PASS_SCORE = 70;
    uint256 public constant TIMEOUT = 7 days;
    uint256 public constant MAX_SUBMISSIONS_PER_ADDRESS = 10;
    uint256 public constant MIN_STAKE = 0.1 ether;
    uint256 public constant MAX_ACCESS_FEE = 100 ether;

    // ============ State Variables ============

    address public authorizedAgent;
    uint256 public submissionCount;

    mapping(uint256 => Submission) public submissions;
    mapping(uint256 => Evaluation) public evaluations;
    mapping(address => uint256) public submissionCountByAddress;
    mapping(address => uint256) public pendingWithdrawals;
    mapping(address => JournalistProfile) public journalists;
    mapping(uint256 => bytes32) public accessTokens;

    // ============ Events ============

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

    event FundsWithdrawn(
        address indexed to,
        uint256 amount
    );

    event SubmissionCancelled(uint256 indexed id);
    event SubmissionTimedOut(uint256 indexed id);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event StakeSlashed(uint256 indexed id, uint256 amount);
    event JournalistRegistered(address indexed journalist, string metadata);
    event JournalistApprovalUpdated(address indexed journalist, bool approved);

    // ============ Constructor ============

    constructor(address _agent) Ownable(msg.sender) {
        require(_agent != address(0), "Invalid agent address");
        authorizedAgent = _agent;
    }

    // ============ Modifiers ============

    modifier onlyAgent() {
        require(msg.sender == authorizedAgent, "Unauthorized: not agent");
        _;
    }

    // ============ Whistleblower Functions ============

    /**
     * @notice Create a new submission with encrypted evidence
     * @param _ipfsCIDHash keccak256 hash of the encrypted IPFS CID
     * @param _categoryHash keccak256 hash of the category string
     * @param _accessFee Fee required for journalists to access (in wei)
     * @param _anonymous If true, source address is set to zero for anonymity
     * @return submissionId The unique ID of the created submission
     */
    function createSubmission(
        bytes32 _ipfsCIDHash,
        bytes32 _categoryHash,
        uint256 _accessFee,
        bool _anonymous
    ) external payable whenNotPaused returns (uint256) {
        require(msg.value >= MIN_STAKE, "Insufficient stake");
        require(_ipfsCIDHash != bytes32(0), "Empty IPFS hash");
        require(_accessFee > 0, "Fee must be positive");
        require(_accessFee <= MAX_ACCESS_FEE, "Fee exceeds maximum");
        require(
            submissionCountByAddress[msg.sender] < MAX_SUBMISSIONS_PER_ADDRESS,
            "Submission limit reached"
        );

        submissionCount++;
        uint256 submissionId = submissionCount;
        submissionCountByAddress[msg.sender]++;

        submissions[submissionId] = Submission({
            id: submissionId,
            ipfsCIDHash: _ipfsCIDHash,
            categoryHash: _categoryHash,
            source: _anonymous ? payable(address(0)) : payable(msg.sender),
            accessFee: _accessFee,
            createdAt: block.timestamp,
            fundedAt: 0,
            stakeAmount: msg.value,
            status: SubmissionStatus.Pending,
            journalist: address(0),
            exists: true
        });

        emit SubmissionCreated(
            submissionId,
            _anonymous ? address(0) : msg.sender,
            _ipfsCIDHash,
            _accessFee,
            block.timestamp
        );

        return submissionId;
    }

    /**
     * @notice Cancel a pending submission and reclaim stake
     * @param _submissionId The ID of the submission to cancel
     */
    function cancelSubmission(uint256 _submissionId) external nonReentrant whenNotPaused {
        Submission storage sub = submissions[_submissionId];
        
        require(sub.exists, "Submission not found");
        require(msg.sender == sub.source, "Not your submission");
        require(sub.status == SubmissionStatus.Pending, "Cannot cancel: not pending");

        sub.status = SubmissionStatus.Cancelled;

        // Refund stake to whistleblower
        if (sub.stakeAmount > 0) {
            uint256 refund = sub.stakeAmount;
            sub.stakeAmount = 0;
            pendingWithdrawals[msg.sender] += refund;
        }

        emit SubmissionCancelled(_submissionId);
    }

    /**
     * @notice Withdraw accumulated funds (earnings + refunded stakes)
     */
    function withdrawFunds() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");

        pendingWithdrawals[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdrawal failed");

        emit FundsWithdrawn(msg.sender, amount);
    }

    // ============ Journalist Functions ============

    /**
     * @notice Register as a journalist
     * @param _metadata IPFS hash or JSON containing journalist credentials
     */
    function registerJournalist(string calldata _metadata) external {
        require(!journalists[msg.sender].exists, "Already registered");

        journalists[msg.sender] = JournalistProfile({
            exists: true,
            approved: false,
            metadata: _metadata
        });

        emit JournalistRegistered(msg.sender, _metadata);
    }

    /**
     * @notice Pay to access a verified submission
     * @param _submissionId The ID of the submission to access
     * @return accessToken Unique token for claiming decryption key
     */
    function accessSubmission(uint256 _submissionId) 
        external 
        payable 
        nonReentrant 
        whenNotPaused
        returns (bytes32 accessToken) 
    {
        Submission storage sub = submissions[_submissionId];
        
        require(sub.exists, "Submission does not exist");
        require(sub.status == SubmissionStatus.Verified, "Not verified for access");
        require(msg.value >= sub.accessFee, "Insufficient payment");
        require(journalists[msg.sender].approved, "Journalist not approved");

        sub.status = SubmissionStatus.Accessed;
        sub.journalist = msg.sender;
        sub.fundedAt = block.timestamp;

        // Generate deterministic access token
        accessToken = keccak256(abi.encodePacked(
            _submissionId,
            msg.sender,
            block.timestamp,
            blockhash(block.number - 1)
        ));
        accessTokens[_submissionId] = accessToken;

        // Credit whistleblower (or contract if anonymous)
        if (sub.source != address(0)) {
            pendingWithdrawals[sub.source] += sub.accessFee;
        } else {
            // Anonymous submission: funds held in contract for manual claim
            pendingWithdrawals[address(this)] += sub.accessFee;
        }

        // Also credit whistleblower's stake back
        if (sub.stakeAmount > 0) {
            pendingWithdrawals[sub.source] += sub.stakeAmount;
            sub.stakeAmount = 0;
        }

        emit SubmissionAccessed(_submissionId, msg.sender, msg.value, block.timestamp);

        // Refund excess payment
        if (msg.value > sub.accessFee) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - sub.accessFee}("");
            require(success, "Refund failed");
        }

        return accessToken;
    }

    /**
     * @notice Get submission metadata (public view)
     * @param _submissionId The ID of the submission
     */
    function getSubmission(uint256 _submissionId)
        external
        view
        returns (Submission memory)
    {
        require(submissions[_submissionId].exists, "Submission not found");
        return submissions[_submissionId];
    }

    // ============ Agent Functions ============

    /**
     * @notice Record evaluation result from AI agent
     * @param _submissionId The ID of the submission to evaluate
     * @param _finalScore Score from 0-100
     * @param _recommendedAction Action recommendation string
     */
    function recordEvaluation(
        uint256 _submissionId,
        uint8 _finalScore,
        string calldata _recommendedAction
    ) external onlyAgent {
        require(_finalScore <= 100, "Score must be 0-100");
        
        Submission storage sub = submissions[_submissionId];
        require(sub.exists, "Submission does not exist");
        require(sub.status == SubmissionStatus.Pending, "Already evaluated");

        evaluations[_submissionId] = Evaluation({
            submissionId: _submissionId,
            finalScore: _finalScore,
            recommendedAction: _recommendedAction,
            evaluatedAt: block.timestamp
        });

        // Auto-verify if score meets threshold
        if (_finalScore >= PASS_SCORE) {
            sub.status = SubmissionStatus.Verified;
        }

        emit SubmissionEvaluated(_submissionId, _finalScore, _recommendedAction);
    }

    /**
     * @notice Approve or reject a journalist
     * @param _journalist Address of the journalist
     * @param _approved Whether to approve or reject
     */
    function approveJournalist(
        address _journalist,
        bool _approved
    ) external onlyAgent {
        require(journalists[_journalist].exists, "Journalist not registered");
        journalists[_journalist].approved = _approved;
        emit JournalistApprovalUpdated(_journalist, _approved);
    }

    /**
     * @notice Slash stake for low-scoring or fraudulent submissions
     * @param _submissionId The ID of the submission
     */
    function slashStake(uint256 _submissionId) external onlyAgent {
        Submission storage sub = submissions[_submissionId];

        require(sub.exists, "Submission does not exist");
        require(sub.status == SubmissionStatus.Pending || sub.status == SubmissionStatus.Verified, "Invalid state for slash");
        require(evaluations[_submissionId].evaluatedAt > 0, "Not evaluated");
        require(evaluations[_submissionId].finalScore < PASS_SCORE, "Cannot slash: score too high");

        uint256 stake = sub.stakeAmount;
        require(stake > 0, "No stake to slash");
        
        sub.stakeAmount = 0;
        sub.status = SubmissionStatus.Disputed;

        pendingWithdrawals[authorizedAgent] += stake;

        emit StakeSlashed(_submissionId, stake);
    }

    /**
     * @notice Claim timeout refund for stale submissions
     * @param _submissionId The ID of the submission
     */
    function timeoutRefund(uint256 _submissionId) external nonReentrant {
        Submission storage sub = submissions[_submissionId];

        require(sub.exists, "Submission does not exist");
        require(sub.status == SubmissionStatus.Accessed, "Not refundable");
        require(sub.fundedAt > 0, "Not funded");
        require(block.timestamp >= sub.fundedAt + TIMEOUT, "Timeout not reached");

        sub.status = SubmissionStatus.Refunded;

        // Return access fee to journalist (something went wrong)
        pendingWithdrawals[sub.journalist] += sub.accessFee;

        emit SubmissionTimedOut(_submissionId);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update the authorized agent address
     * @param _newAgent New agent address
     */
    function setAgent(address _newAgent) external onlyOwner {
        require(_newAgent != address(0), "Invalid address");

        address oldAgent = authorizedAgent;
        authorizedAgent = _newAgent;

        emit AgentUpdated(oldAgent, _newAgent);
    }

    /**
     * @notice Pause all state-changing operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Fallback ============

    receive() external payable {
        revert("Use protocol functions");
    }

    fallback() external payable {
        revert("Invalid call");
    }
}
