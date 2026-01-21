// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract WhistleblowerEscrow is Ownable, ReentrancyGuard {
    struct Submission {
        address whistleblower;
        string ipfsHash;
        uint256 accessFee;
        uint256 createdAt;
        address journalist;
        bool exists;
        bool isEvaluated;
        uint8 evaluationScore;
        bool isResolved;
        EscrowState state;
        uint256 fundedAt;
        uint256 stakeAmount;
    }

    struct JournalistProfile {
        bool exists;
        bool approved;
        string metadata; // IPFS hash or JSON (name, outlet, proof)
    }

    // other of functions:
    // submit, grantAccess, withdrawPending, cancelSubmission, timeoutRefund, getSubmission, updateAgent
    //

    uint8 evaluationScore; // 0–100 scoring
    bool isEvaluated;
    address public authorizedAgent; // unique ID to each submission
    uint256 public submissionCount;
    uint8 public constant PASS_SCORE = 70; // minimum score to release funds to whistleblower
    uint256 public constant TIMEOUT = 7 days; // to avoid stale submissions
    uint256 public constant MAX_SUBMISSIONS_PER_ADDRESS = 10; // this is to prevent spam submissions
    uint256 public constant MIN_STAKE = 0.1 ether; // minimum stake required

    mapping(uint256 => Submission) public submissions; // mapping submission ID to Submission struct
    mapping(address => uint256) public submissionCountByAddress; // to track number of submissions per whistleblower
    mapping(address => uint256) public pendingWithdrawals; // to track pending withdrawals for whistleblowers
    mapping(address => JournalistProfile) public journalists; // to track registered journalists

    event SubmissionCreated(
        uint256 indexed id,
        address indexed whistleblower,
        uint256 fee
    );
    event AccessGranted(
        uint256 indexed id,
        address indexed journalist,
        uint256 amount
    );
    event SubmissionCancelled(uint256 indexed id);
    event SubmissionTimedOut(uint256 indexed id);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event Withdrawal(address indexed whistleblower, uint256 amount);
    event SubmissionEvaluated(
        uint256 indexed id,
        uint8 score,
        address indexed agent
    );
    event FundsLocked(uint256 indexed id, uint256 amount);
    event FundsReleased(uint256 indexed id, address indexed to);
    event FundsRefunded(uint256 indexed id);
    event JournalistRegistered(address indexed journalist, string metadata);
    event JournalistApprovedUpdated(address indexed journalist, bool approved);

    enum EscrowState {
        Submitted,
        Funded,
        Evaluated,
        Released,
        Cancelled,
        Refunded
    }

    constructor(address _agent) Ownable(msg.sender) {
        require(_agent != address(0), "Invalid agent agent");
        authorizedAgent = _agent;
        // the trusted agent is the middleman who facilitates access
    }

    modifier onlyAgent() {
        require(msg.sender == authorizedAgent, "Unauthorized agent");
        _;
        // only the authorized agent can call functions with this modifier and not the whistleblower or journalist directly
    }

    function submit(
        // this is the entry point for the whistleblower to submit their info
        // so at the frontend, they will provide the IPFS hash and the access fee
        // this function validates the whitlesblowers input, creates new submisson, stores it onchain , returns a sumbmission ID
        // for each submission made, would each whitleblower have different submision IDs?or one uinque ID will be tied to that address? no, each submisson comes with its ID
        string memory _ipfsHash,
        uint256 _accessFee
    ) external payable returns (uint256) {
        require(msg.value >= MIN_STAKE, "Insufficient funds");
        require(bytes(_ipfsHash).length > 0, "Empty IPFS hash");
        // whwere would they get the IPFS hash from? they would upload their info to IPFS first, get the hash, then call this function with that hash
        require(_accessFee > 0, "Fee must be positive");
        require(
            submissionCountByAddress[msg.sender] < MAX_SUBMISSIONS_PER_ADDRESS,
            "Submission limit reached"
        );

        // EFFECTS
        submissionCount++;
        uint256 submissionId = submissionCount;

        submissions[submissionId] = Submission({
            whistleblower: msg.sender,
            ipfsHash: _ipfsHash,
            accessFee: _accessFee,
            journalist: address(0),
            createdAt: block.timestamp,
            exists: true,
            isResolved: false,
            evaluationScore: 0,
            isEvaluated: false,
            state: EscrowState.Submitted,
            fundedAt: 0,
            stakeAmount: msg.value
        });

        emit SubmissionCreated(submissionId, msg.sender, _accessFee);
        return submissionId;
    }

    function registeredJournalist(string calldata _metadata) external {
        require(!journalists[msg.sender].exists, "already registered bruvh");

        journalists[msg.sender] = JournalistProfile({
            exists: true,
            approved: false,
            metadata: _metadata
        });

        emit JournalistRegistered(msg.sender, _metadata);
    }

    function approveJournalist(
        address _journalist,
        bool _approved
    ) external onlyAgent {
        require(journalists[_journalist].exists, "Journalist not registered");

        journalists[_journalist].approved = _approved;

        emit JournalistApprovedUpdated(_journalist, _approved);
    }

    function assignJournalist(
        uint256 _submissionId,
        address _journalist
    ) external onlyAgent {
        Submission storage sub = submissions[_submissionId];

        require(sub.exists, "Submission does not exist");
        require(sub.state == EscrowState.Submitted, "Invalid state");
        require(sub.journalist == address(0), "Joyrnalist already assigned");
        require(journalists[_journalist].approved, "Journalist not approved");

        sub.journalist = _journalist;
    }

    function evaluteSubmission(
        uint256 _submissionId,
        uint8 _score
    ) external onlyAgent {
        require(_score <= 100, "Score must be 0 - 100");

        Submission storage submission = submissions[_submissionId];
        require(submission.exists, "Submission does not exits");
        require(!submission.isEvaluated, "Already evalauted");

        submission.evaluationScore = _score;
        submission.isEvaluated = true;

        emit SubmissionEvaluated(_submissionId, _score, msg.sender);
    }

    function grantAccess(
        uint256 _submissionId,
        address _journalist
    ) external payable onlyAgent nonReentrant {
        // CHECKS
        Submission storage submission = submissions[_submissionId];
        require(submission.exists, "Submission does not exist"); // make sure the submission exits
        require(!submission.isResolved, "Already resolved"); // ← CRITICAL FIX to prevent re-entrancy attacks
        require(msg.value >= submission.accessFee, "Insufficient payment"); // that funds sent is greater than or equal to the required submisson fee stated by the whistleblower
        require(_journalist != address(0), "Invalid journalist"); //

        // EFFECTS
        submission.isResolved = true;
        submission.journalist = _journalist;

        // INTERACTIONS
        submission.state = EscrowState.Funded;
        submission.fundedAt = block.timestamp;

        emit AccessGranted(_submissionId, _journalist, submission.accessFee);

        // Refund excess to agent
        if (msg.value > submission.accessFee) {
            (bool refundSuccess, ) = payable(msg.sender).call{
                value: msg.value - submission.accessFee
            }("");
            require(refundSuccess, "Refund failed");
        }
    }

    function withdrawPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");

        // EFFECTS
        pendingWithdrawals[msg.sender] = 0;

        // INTERACTIONS
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdraw failed");

        emit Withdrawal(msg.sender, amount);
    }

    receive() external payable {
        revert("Use protocol functions");
    }

    fallback() external payable {
        revert("Invalid call");
    }

    function cancelSubmission(uint256 _id) external {
        Submission storage sub = submissions[_id];
        // gives whistleblower ability to cancel their submission if it hasn't been resolved yet

        require(sub.exists, "Submission not found");
        require(msg.sender == sub.whistleblower, "Not your submission");
        require(!sub.isResolved, "Already resolved");

        sub.isResolved = true;

        emit SubmissionCancelled(_id);
    }

    function releaseFunds(uint256 _id) external onlyAgent nonReentrant {
        Submission storage sub = submissions[_id];

        require(sub.exists, "Submission doesnt exist");
        require(sub.state == EscrowState.Funded, "Not funded");
        require(sub.isEvaluated, "Not Evaluated");
        require(sub.evaluationScore >= PASS_SCORE, "evaluation score too low");

        sub.state = EscrowState.Released;

        pendingWithdrawals[sub.whistleblower] += sub.accessFee;
    }

    function withdrawFunds() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");

        pendingWithdrawals[msg.sender] = 0;

        (bool allGood, ) = payable(msg.sender).call{value: amount}("");
        require(allGood, "Withdrawal failed");
    }

    function timeoutRefund(uint256 _id) external {
        Submission storage sub = submissions[_id];

        require(sub.state == EscrowState.Funded, "Not refundable");
        require(
            block.timestamp >= sub.createdAt + TIMEOUT,
            "Timeout not reached"
        );
        sub.state = EscrowState.Refunded;

        pendingWithdrawals[authorizedAgent] += sub.accessFee;

        sub.isResolved = true;

        emit SubmissionTimedOut(_id);
    }

    function getSubmission(
        uint256 _id // makes it read-only
    )
        external
        view
        returns (
            string memory ipfsHash,
            uint256 accessFee,
            bool isResolved,
            address journalist
        )
    {
        Submission storage sub = submissions[_id];
        require(sub.exists, "Submission not found");

        require(
            msg.sender == sub.whistleblower ||
                msg.sender == authorizedAgent ||
                msg.sender == sub.journalist,
            "Unauthorized"
        );
        return (sub.ipfsHash, sub.accessFee, sub.isResolved, sub.journalist);
    }

    function slashStake(uint256 _id) external onlyAgent {
        Submission storage sub = submissions[_id];

        require(sub.exists, "Submission doesnt exist");
        require(sub.state == EscrowState.Funded, "Not funded");
        require(sub.isEvaluated, "Not evaluated");
        require(
            sub.evaluationScore < PASS_SCORE,
            "Cannot slash, score too high"
        );

        uint256 stake = sub.stakeAmount;
        sub.stakeAmount = 0;

        pendingWithdrawals[authorizedAgent] += stake;

        emit FundsRefunded(_id);
    }

    function updateAgent(address _newAgent) external onlyOwner {
        require(_newAgent != address(0), "Invalid address");

        address oldAgent = authorizedAgent;
        authorizedAgent = _newAgent;

        emit AgentUpdated(oldAgent, _newAgent);
    }
}
