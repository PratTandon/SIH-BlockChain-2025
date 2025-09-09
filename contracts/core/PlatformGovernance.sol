// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./AgriAccessControl.sol";
import "../interfaces/IStakeholder.sol";

/**
 * @title PlatformGovernance
 * @dev Basic governance for platform decisions with reputation-weighted voting
 * @author AgriTrace Team
 */
contract PlatformGovernance is AgriAccessControl {
    // ============ EVENTS ============
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        bytes32 descriptionHash,
        uint256 votingDeadline,
        uint256 timestamp
    );

    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 weight,
        string reason,
        uint256 timestamp
    );

    event ProposalExecuted(
        uint256 indexed proposalId,
        bool passed,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 timestamp
    );

    event ProposalCancelled(
        uint256 indexed proposalId,
        address indexed canceller,
        string reason,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum ProposalState {
        PENDING,    // 0 - Waiting for voting period
        ACTIVE,     // 1 - Currently accepting votes
        CANCELLED,  // 2 - Cancelled by proposer or admin
        DEFEATED,   // 3 - Failed to pass
        SUCCEEDED,  // 4 - Passed and ready for execution
        EXECUTED    // 5 - Successfully executed
    }

    enum ProposalType {
        PARAMETER_UPDATE,   // 0 - Update platform parameters
        ROLE_MANAGEMENT,    // 1 - Add/remove roles
        EMERGENCY_ACTION,   // 2 - Emergency governance actions
        FEATURE_TOGGLE,     // 3 - Enable/disable features
        CONTRACT_UPGRADE    // 4 - Contract upgrade proposals
    }

    // ============ STRUCTS ============
    struct Proposal {
        uint256 id;
        string title;
        bytes32 descriptionHash;
        address proposer;
        ProposalType proposalType;
        uint256 createdAt;
        uint256 votingStartTime;
        uint256 votingEndTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 totalVotes;
        ProposalState state;
        bool executed;
        bytes executionData;
        mapping(address => bool) hasVoted;
        mapping(address => Vote) votes;
    }

    struct Vote {
        bool support;
        uint256 weight;
        string reason;
        uint256 timestamp;
    }

    struct ProposalInfo {
        uint256 id;
        string title;
        bytes32 descriptionHash;
        address proposer;
        ProposalType proposalType;
        uint256 createdAt;
        uint256 votingStartTime;
        uint256 votingEndTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 totalVotes;
        ProposalState state;
        bool executed;
    }

    // ============ STATE VARIABLES ============
    uint256 private _proposalCounter;
    mapping(uint256 => Proposal) private _proposals;
    mapping(address => uint256[]) private _userProposals;
    
    IStakeholder public stakeholderContract;
    
    // Governance parameters
    uint256 public votingDelay = 1 days;           // Delay before voting starts
    uint256 public votingPeriod = 7 days;          // Duration of voting period
    uint256 public proposalThreshold = 100;        // Minimum reputation to propose
    uint256 public quorumNumerator = 4;           // 4% quorum requirement
    uint256 public quorumDenominator = 100;
    uint256 public executionDelay = 2 days;        // Delay before execution

    // ============ MODIFIERS ============
    modifier proposalExists(uint256 proposalId) {
        require(_proposals[proposalId].id != 0, "PlatformGovernance: Proposal does not exist");
        _;
    }

    modifier onlyProposer(uint256 proposalId) {
        require(_proposals[proposalId].proposer == msg.sender, "PlatformGovernance: Not proposer");
        _;
    }

    modifier canPropose() {
        require(address(stakeholderContract) != address(0), "PlatformGovernance: Stakeholder contract not set");
        require(stakeholderContract.getReputation(msg.sender) >= proposalThreshold, "PlatformGovernance: Insufficient reputation");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _proposalCounter = 0;
    }

    // ============ SETUP FUNCTIONS ============
    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakeholderContract != address(0), "PlatformGovernance: Invalid stakeholder contract");
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    // ============ PROPOSAL FUNCTIONS ============
    /**
     * @notice Create new governance proposal
     */
    function createProposal(
        string calldata title,
        bytes32 descriptionHash,
        ProposalType proposalType,
        bytes calldata executionData
    ) external canPropose returns (uint256 proposalId) {
        require(bytes(title).length > 0, "PlatformGovernance: Title cannot be empty");
        require(descriptionHash != bytes32(0), "PlatformGovernance: Description hash required");

        _proposalCounter++;
        proposalId = _proposalCounter;

        Proposal storage proposal = _proposals[proposalId];
        proposal.id = proposalId;
        proposal.title = title;
        proposal.descriptionHash = descriptionHash;
        proposal.proposer = msg.sender;
        proposal.proposalType = proposalType;
        proposal.createdAt = block.timestamp;
        proposal.votingStartTime = block.timestamp + votingDelay;
        proposal.votingEndTime = block.timestamp + votingDelay + votingPeriod;
        proposal.state = ProposalState.PENDING;
        proposal.executionData = executionData;

        _userProposals[msg.sender].push(proposalId);

        emit ProposalCreated(
            proposalId,
            msg.sender,
            title,
            descriptionHash,
            proposal.votingEndTime,
            block.timestamp
        );

        return proposalId;
    }

    /**
     * @notice Cast vote on proposal
     */
    function castVote(
        uint256 proposalId,
        bool support,
        string calldata reason
    ) external proposalExists(proposalId) {
        Proposal storage proposal = _proposals[proposalId];
        
        require(block.timestamp >= proposal.votingStartTime, "PlatformGovernance: Voting not started");
        require(block.timestamp <= proposal.votingEndTime, "PlatformGovernance: Voting ended");
        require(!proposal.hasVoted[msg.sender], "PlatformGovernance: Already voted");
        require(stakeholderContract.isVerifiedAndIntact(msg.sender), "PlatformGovernance: Voter not verified");

        uint256 weight = _getVotingWeight(msg.sender);
        require(weight > 0, "PlatformGovernance: No voting weight");

        proposal.hasVoted[msg.sender] = true;
        proposal.votes[msg.sender] = Vote({
            support: support,
            weight: weight,
            reason: reason,
            timestamp: block.timestamp
        });

        if (support) {
            proposal.forVotes += weight;
        } else {
            proposal.againstVotes += weight;
        }
        proposal.totalVotes += weight;

        emit VoteCast(proposalId, msg.sender, support, weight, reason, block.timestamp);
    }

    /**
     * @notice Execute proposal if it passed
     */
    function executeProposal(uint256 proposalId) external proposalExists(proposalId) {
        Proposal storage proposal = _proposals[proposalId];
        
        require(block.timestamp > proposal.votingEndTime, "PlatformGovernance: Voting still active");
        require(proposal.state == ProposalState.ACTIVE || proposal.state == ProposalState.SUCCEEDED, "PlatformGovernance: Invalid state");
        require(!proposal.executed, "PlatformGovernance: Already executed");

        // Update proposal state based on results
        if (_hasPassedQuorum(proposalId) && proposal.forVotes > proposal.againstVotes) {
            proposal.state = ProposalState.SUCCEEDED;
        } else {
            proposal.state = ProposalState.DEFEATED;
            emit ProposalExecuted(proposalId, false, proposal.forVotes, proposal.againstVotes, block.timestamp);
            return;
        }

        // Execute proposal if it passed
        proposal.executed = true;
        proposal.state = ProposalState.EXECUTED;

        // Execute based on proposal type
        if (proposal.proposalType == ProposalType.PARAMETER_UPDATE) {
            _executeParameterUpdate(proposal.executionData);
        }

        emit ProposalExecuted(proposalId, true, proposal.forVotes, proposal.againstVotes, block.timestamp);
    }

    /**
     * @notice Cancel proposal (proposer or admin only)
     */
    function cancelProposal(uint256 proposalId, string calldata reason) 
        external 
        proposalExists(proposalId) {
        
        Proposal storage proposal = _proposals[proposalId];
        
        require(
            msg.sender == proposal.proposer || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "PlatformGovernance: Not authorized to cancel"
        );
        require(proposal.state == ProposalState.PENDING || proposal.state == ProposalState.ACTIVE, "PlatformGovernance: Cannot cancel");

        proposal.state = ProposalState.CANCELLED;

        emit ProposalCancelled(proposalId, msg.sender, reason, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get proposal information
     */
    function getProposal(uint256 proposalId) external view proposalExists(proposalId) returns (ProposalInfo memory) {
        Proposal storage proposal = _proposals[proposalId];
        
        return ProposalInfo({
            id: proposal.id,
            title: proposal.title,
            descriptionHash: proposal.descriptionHash,
            proposer: proposal.proposer,
            proposalType: proposal.proposalType,
            createdAt: proposal.createdAt,
            votingStartTime: proposal.votingStartTime,
            votingEndTime: proposal.votingEndTime,
            forVotes: proposal.forVotes,
            againstVotes: proposal.againstVotes,
            totalVotes: proposal.totalVotes,
            state: proposal.state,
            executed: proposal.executed
        });
    }

    /**
     * @notice Get proposal state
     */
    function getProposalState(uint256 proposalId) external view proposalExists(proposalId) returns (ProposalState) {
        Proposal storage proposal = _proposals[proposalId];
        
        if (proposal.state == ProposalState.CANCELLED || 
            proposal.state == ProposalState.EXECUTED) {
            return proposal.state;
        }

        if (block.timestamp < proposal.votingStartTime) {
            return ProposalState.PENDING;
        } else if (block.timestamp <= proposal.votingEndTime) {
            return ProposalState.ACTIVE;
        } else if (_hasPassedQuorum(proposalId) && proposal.forVotes > proposal.againstVotes) {
            return ProposalState.SUCCEEDED;
        } else {
            return ProposalState.DEFEATED;
        }
    }

    /**
     * @notice Check if user has voted on proposal
     */
    function hasVoted(uint256 proposalId, address voter) external view proposalExists(proposalId) returns (bool) {
        return _proposals[proposalId].hasVoted[voter];
    }

    /**
     * @notice Get user's vote on proposal
     */
    function getVote(uint256 proposalId, address voter) external view proposalExists(proposalId) returns (Vote memory) {
        require(_proposals[proposalId].hasVoted[voter], "PlatformGovernance: User has not voted");
        return _proposals[proposalId].votes[voter];
    }

    /**
     * @notice Get user's proposals
     */
    function getUserProposals(address user) external view returns (uint256[] memory) {
        return _userProposals[user];
    }

    /**
     * @notice Get total number of proposals
     */
    function getTotalProposals() external view returns (uint256) {
        return _proposalCounter;
    }

    /**
     * @notice Get active proposals
     */
    function getActiveProposals() external view returns (uint256[] memory) {
        uint256[] memory tempProposals = new uint256[](_proposalCounter);
        uint256 count = 0;

        for (uint256 i = 1; i <= _proposalCounter; i++) {
            ProposalState state = this.getProposalState(i);
            if (state == ProposalState.ACTIVE || state == ProposalState.PENDING) {
                tempProposals[count] = i;
                count++;
            }
        }

        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = tempProposals[i];
        }

        return result;
    }

    // ============ PARAMETER FUNCTIONS ============
    function setVotingDelay(uint256 _votingDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_votingDelay <= 30 days, "PlatformGovernance: Voting delay too long");
        votingDelay = _votingDelay;
    }

    function setVotingPeriod(uint256 _votingPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_votingPeriod >= 1 days && _votingPeriod <= 30 days, "PlatformGovernance: Invalid voting period");
        votingPeriod = _votingPeriod;
    }

    function setProposalThreshold(uint256 _proposalThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_proposalThreshold >= 50 && _proposalThreshold <= 1000, "PlatformGovernance: Invalid threshold");
        proposalThreshold = _proposalThreshold;
    }

    function setQuorum(uint256 numerator, uint256 denominator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(numerator <= denominator, "PlatformGovernance: Invalid quorum");
        require(denominator > 0, "PlatformGovernance: Denominator cannot be zero");
        quorumNumerator = numerator;
        quorumDenominator = denominator;
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Get voting weight for address based on reputation and roles
     */
    function _getVotingWeight(address voter) internal view returns (uint256) {
        uint256 baseWeight = stakeholderContract.getReputation(voter);
        
        // Role-based weight multipliers
        if (hasRole(AUDITOR_ROLE, voter)) {
            baseWeight = baseWeight * 150 / 100; // 1.5x for auditors
        } else if (hasRole(FARMER_ROLE, voter)) {
            baseWeight = baseWeight * 120 / 100; // 1.2x for farmers
        }
        
        return baseWeight;
    }

    /**
     * @dev Check if proposal has passed quorum
     */
    function _hasPassedQuorum(uint256 proposalId) internal view returns (bool) {
        Proposal storage proposal = _proposals[proposalId];
        
        // Calculate total possible voting weight (simplified)
        uint256 totalPossibleWeight = 1000000; // Placeholder - should be calculated from all verified stakeholders
        uint256 requiredQuorum = (totalPossibleWeight * quorumNumerator) / quorumDenominator;
        
        return proposal.totalVotes >= requiredQuorum;
    }

    /**
     * @dev Execute parameter update proposal
     */
    function _executeParameterUpdate(bytes memory executionData) internal {
        // Decode and execute parameter updates
        // Implementation depends on specific parameter update needs
        // This is a placeholder for actual execution logic
    }
}
