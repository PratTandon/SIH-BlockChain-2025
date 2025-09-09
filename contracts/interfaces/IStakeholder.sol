// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IStakeholder
 * @dev Interface for stakeholder hash-based identity verification
 * @author AgriTrace Team
 */
interface IStakeholder {
    // ============ EVENTS ============
    event StakeholderHashRegistered(
        address indexed stakeholder, 
        StakeholderType indexed stakeholderType,
        bytes32 indexed profileHash,
        uint256 timestamp
    );
    
    event VerificationHashUpdated(
        address indexed stakeholder, 
        VerificationStatus indexed newStatus,
        bytes32 verificationHash,
        uint256 timestamp
    );
    
    event ReputationHashUpdated(
        address indexed stakeholder, 
        uint256 newReputation,
        bytes32 reputationHash,
        uint256 timestamp
    );
    
    event CredentialHashAdded(
        address indexed stakeholder, 
        bytes32 indexed credentialHash,
        string credentialType,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum StakeholderType {
        FARMER,       // 0
        PROCESSOR,    // 1
        DISTRIBUTOR,  // 2
        RETAILER,     // 3
        CONSUMER,     // 4
        AUDITOR,      // 5
        ADMIN         // 6
    }

    enum VerificationStatus {
        PENDING,      // 0
        VERIFIED,     // 1
        REJECTED,     // 2
        SUSPENDED     // 3
    }

    // ============ STRUCTS ============
    struct StakeholderHashRecord {
        StakeholderType stakeholderType;
        bytes32 profileDataHash;
        VerificationStatus status;
        bytes32 verificationHash;
        uint256 reputation;
        bytes32 reputationHash;
        uint256 joinDate;
        uint256 lastActivity;
        bool isActive;
        uint256 totalTransactions;
    }

    struct CredentialHashRecord {
        bytes32 credentialHash;
        string credentialType;
        uint256 issueDate;
        uint256 expiryDate;
        address issuer;
        bool isValid;
    }

    // ============ CORE FUNCTIONS ============
    function registerStakeholderHash(StakeholderType stakeholderType, bytes32 profileDataHash) external;
    function updateVerificationHash(address stakeholder, VerificationStatus status, bytes32 verificationDataHash) external;
    function updateReputationHash(address stakeholder, uint256 newReputation, bytes32 reputationDataHash) external;
    function addCredentialHash(address stakeholder, string calldata credentialType, bytes32 credentialHash, uint256 expiryDate) external;
    function verifyStakeholderIntegrity(address stakeholder, bytes32 profileDataHash) external view returns (bool isValid);
    function getStakeholderHashRecord(address stakeholder) external view returns (StakeholderHashRecord memory);
    function getCredentialHashes(address stakeholder) external view returns (CredentialHashRecord[] memory);
    function isVerifiedAndIntact(address stakeholder) external view returns (bool);
    function verifyCredentialIntegrity(address stakeholder, string calldata credentialType, bytes32 credentialHash) external view returns (bool isValid);
    
    // ============ REPUTATION FUNCTIONS ============
    function getReputation(address stakeholder) external view returns (uint256);
}