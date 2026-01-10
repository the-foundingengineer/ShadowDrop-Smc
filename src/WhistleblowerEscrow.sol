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
        bool isResolved;
    }

    address public authorizedAgent;
    // unique ID to each submission
    uint256 public submissionCount;
    uint256 public constant TIMEOUT = 7 days; // to avoid stale submissions
    uint256 public constant MAX_SUBMISSIONS_PER_ADDRESS = 10; // this is to prevent spam submissions

    mapping(uint256 => Submission) public submissions; // mapping submission ID to Submission struct
    mapping(address => uint256) public submissionCountByAddress; // to track number of submissions per whistleblower
    mapping(address => uint256) public pendingWithdrawals; // to track pending withdrawals for whistleblowers

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
    ) external returns (uint256) {
        // CHECKS
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
            isResolved: false
        });

        submissionCountByAddress[msg.sender]++;

        // INTERACTIONS
        emit SubmissionCreated(submissionId, msg.sender, _accessFee);
        return submissionId;
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
        (bool success, ) = payable(submission.whistleblower).call{
            value: submission.accessFee
        }("");
        require(success, "Payment failed");
        // Send the access fee to the whistleblower. If it doesn’t go through, cancel the transaction.

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
        // more like a safty mechanism to allow whistleblowers to withdraw their funds if something goes wrong with direct payment

        pendingWithdrawals[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdraw failed");

        emit Withdrawal(msg.sender, amount);
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

    function timeoutRefund(uint256 _id) external {
        Submission storage sub = submissions[_id];

        require(sub.exists, "Submission not found");
        require(!sub.isResolved, "Already resolved");
        require(msg.sender == sub.whistleblower, "Not your submission");
        require(
            block.timestamp >= sub.createdAt + TIMEOUT,
            "Timeout not reached"
        );

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
        Submission memory sub = submissions[_id];
        return (sub.ipfsHash, sub.accessFee, sub.isResolved, sub.journalist);
    }

    function updateAgent(address _newAgent) external onlyOwner {
        require(_newAgent != address(0), "Invalid address");

        address oldAgent = authorizedAgent;
        authorizedAgent = _newAgent;

        emit AgentUpdated(oldAgent, _newAgent);
    }
}
