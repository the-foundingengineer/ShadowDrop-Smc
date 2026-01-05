// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13 <0.9.0;

contract WhistleblowerEscrow {
    
    struct Submission {
        address whistleblower;
        string ipfsHash;
        uint256 accessFee;
        address journalist;
        bool exists;
        bool isResolved;
    }

    address public authorizedAgent;
    address public owner;

    mapping(uint256 => Submission) public submissions;
    uint256 public submissionCount;

    event SubmissionCreated(uint256 indexed id, address indexed whistleblower, uint256 fee);
    event AccessGranted(uint256 indexed id, address indexed journalist, uint256 amount);

    constructor(address _agent) {
        authorizedAgent = _agent;
        owner = msg.sender;
    }

    modifier onlyAgent() {
        require(msg.sender == authorizedAgent, "Unauthorized agent");
        _;
    }

    function submit(string memory _ipfsHash, uint256 _accessFee) 
        external 
        returns (uint256) 
    {
        // CHECKS
        require(bytes(_ipfsHash).length > 0, "Empty IPFS hash");
        require(_accessFee > 0, "Fee must be positive");

        // EFFECTS
        submissionCount++;
        uint256 submissionId = submissionCount;

        submissions[submissionId] = Submission({
            whistleblower: msg.sender,
            ipfsHash: _ipfsHash,
            accessFee: _accessFee,
            journalist: address(0),
            exists: true,
            isResolved: false
        });

        // INTERACTIONS
        emit SubmissionCreated(submissionId, msg.sender, _accessFee);
        
        return submissionId;
    }

    function grantAccess(uint256 _submissionId, address _journalist) 
        external 
        payable 
        onlyAgent 
    {
        // CHECKS
        Submission storage submission = submissions[_submissionId];
        require(submission.exists, "Submission does not exist");
        require(!submission.isResolved, "Already resolved");  // ← CRITICAL FIX
        require(msg.value >= submission.accessFee, "Insufficient payment");
        require(_journalist != address(0), "Invalid journalist");

        // EFFECTS
        submission.isResolved = true;
        submission.journalist = _journalist;
        
        // INTERACTIONS
        (bool success, ) = payable(submission.whistleblower).call{value: submission.accessFee}("");
        require(success, "Payment failed");

        emit AccessGranted(_submissionId, _journalist, submission.accessFee);

        // Refund excess to agent
        if (msg.value > submission.accessFee) {
            (bool refundSuccess, ) = payable(msg.sender).call{value: msg.value - submission.accessFee}("");
            require(refundSuccess, "Refund failed");
        }
    }

    function getSubmission(uint256 _id) 
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

    function updateAgent(address _newAgent) external {
        require(msg.sender == owner, "Only owner");
        require(_newAgent != address(0), "Invalid address");
        authorizedAgent = _newAgent;
    }
}