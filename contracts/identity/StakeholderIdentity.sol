// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IStakeholder.sol";
import "../libraries/DateTimeLib.sol";
import "../core/AgriAccessControl.sol";

/**
 * @title StakeholderIdentity
 * @dev Universal identity management for all platform participants
 * @author AgriTrace Team
 */
contract StakeholderIdentity is IStakeholder, AgriAccessControl {
    using DateTimeLib for uint256;

    // ============ STATE VARIABLES ============
    mapping(address => StakeholderHashRecord) private _stakeholders;
    mapping(address => CredentialHashRecord[]) private _credentials;
    mapping(address => uint256[]) private _transactionHistory;
    mapping(StakeholderType => address[]) private _stakeholdersByType;
    mapping(bytes32 => address) private _profileHashToAddress;
    
    address[] private _allStakeholders;
    uint256 private _totalStakeholders;
    
    // Contract references
    address public reputationSystemContract;
    address public credentialManagerContract;

    // ============ MODIFIERS ============
    modifier stakeholderExists(address stakeholder) {
        require(_stakeholders[stakeholder].joinDate != 0, "StakeholderIdentity: Stakeholder not registered");
        _;
    }

    modifier validStakeholderType(StakeholderType stakeholderType) {
        require(uint8(stakeholderType) <= 6, "StakeholderIdentity: Invalid stakeholder type");
        _;
    }

    modifier uniqueProfileHash(bytes32 profileHash) {
        require(_profileHashToAddress[profileHash] == address(0), "StakeholderIdentity: Profile hash already used");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _totalStakeholders = 0;
    }

    // ============ SETUP FUNCTIONS ============
    function setReputationSystemContract(address _reputationSystemContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_reputationSystemContract != address(0), "StakeholderIdentity: Invalid reputation contract");
        reputationSystemContract = _reputationSystemContract;
    }

    function setCredentialManagerContract(address _credentialManagerContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_credentialManagerContract != address(0), "StakeholderIdentity: Invalid credential contract");
        credentialManagerContract = _credentialManagerContract;
    }

    // ============ CORE FUNCTIONS ============
    /**
     * @notice Register new stakeholder
     */
    function registerStakeholderHash(
        StakeholderType stakeholderType,
        bytes32 profileDataHash
    ) external override validStakeholderType(stakeholderType) uniqueProfileHash(profileDataHash) {
        require(profileDataHash != bytes32(0), "StakeholderIdentity: Profile hash required");
        require(_stakeholders[msg.sender].joinDate == 0, "StakeholderIdentity: Already registered");

        _stakeholders[msg.sender] = StakeholderHashRecord({
            stakeholderType: stakeholderType,
            profileDataHash: profileDataHash,
            status: VerificationStatus.PENDING,
            verificationHash: bytes32(0),
            reputation: 500, // Start with neutral reputation
            reputationHash: keccak256(abi.encodePacked(msg.sender, block.timestamp, uint256(500))),
            joinDate: block.timestamp,
            lastActivity: block.timestamp,
            isActive: true,
            totalTransactions: 0
        });

        _stakeholdersByType[stakeholderType].push(msg.sender);
        _allStakeholders.push(msg.sender);
        _profileHashToAddress[profileDataHash] = msg.sender;
        _totalStakeholders++;

        emit StakeholderHashRegistered(msg.sender, stakeholderType, profileDataHash, block.timestamp);
    }

    /**
     * @notice Update verification status
     */
    function updateVerificationHash(
        address stakeholder,
        VerificationStatus status,
        bytes32 verificationDataHash
    ) external override onlyRole(AUDITOR_ROLE) stakeholderExists(stakeholder) {
        require(verificationDataHash != bytes32(0), "StakeholderIdentity: Verification hash required");

        StakeholderHashRecord storage record = _stakeholders[stakeholder];
        
        record.status = status;
        record.verificationHash = verificationDataHash;
        record.lastActivity = block.timestamp;

        // Grant appropriate role based on stakeholder type and verification
        if (status == VerificationStatus.VERIFIED) {
            bytes32 role = _getStakeholderRole(record.stakeholderType);
            grantRole(role, stakeholder);
        } else if (status == VerificationStatus.SUSPENDED || status == VerificationStatus.REJECTED) {
            // Revoke all roles except basic stakeholder access
            _revokeAllStakeholderRoles(stakeholder, record.stakeholderType);
        }

        // Fix: Match interface - only 4 parameters expected
        emit VerificationHashUpdated(stakeholder, status, verificationDataHash, block.timestamp);
    }

    /**
     * @notice Update reputation
     */
    function updateReputationHash(
        address stakeholder,
        uint256 newReputation,
        bytes32 reputationDataHash
    ) external override stakeholderExists(stakeholder) {
        require(
            msg.sender == reputationSystemContract || 
            hasRole(AUDITOR_ROLE, msg.sender) || 
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "StakeholderIdentity: Not authorized to update reputation"
        );
        require(newReputation <= 1000, "StakeholderIdentity: Reputation must be <= 1000");
        require(reputationDataHash != bytes32(0), "StakeholderIdentity: Reputation hash required");

        StakeholderHashRecord storage record = _stakeholders[stakeholder];
        
        record.reputation = newReputation;
        record.reputationHash = reputationDataHash;
        record.lastActivity = block.timestamp;

        // Fix: Already corrected to match interface
        emit ReputationHashUpdated(stakeholder, newReputation, reputationDataHash, block.timestamp);
    }

    /**
     * @notice Add credential
     */
    function addCredentialHash(
        address stakeholder,
        string calldata credentialType,
        bytes32 credentialHash,
        uint256 expiryDate
    ) external override stakeholderExists(stakeholder) {
        require(
            msg.sender == credentialManagerContract || 
            hasRole(AUDITOR_ROLE, msg.sender) || 
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "StakeholderIdentity: Not authorized to add credentials"
        );
        require(bytes(credentialType).length > 0, "StakeholderIdentity: Credential type required");
        require(credentialHash != bytes32(0), "StakeholderIdentity: Credential hash required");
        require(expiryDate > block.timestamp, "StakeholderIdentity: Invalid expiry date");

        CredentialHashRecord memory credential = CredentialHashRecord({
            credentialHash: credentialHash,
            credentialType: credentialType,
            issueDate: block.timestamp,
            expiryDate: expiryDate,
            issuer: msg.sender,
            isValid: true
        });

        _credentials[stakeholder].push(credential);
        _stakeholders[stakeholder].lastActivity = block.timestamp;

        emit CredentialHashAdded(stakeholder, credentialHash, credentialType, block.timestamp);
    }

    /**
     * @notice Record transaction activity
     */
    function recordTransaction(address stakeholder, uint256 transactionId) external {
        require(_stakeholders[stakeholder].joinDate != 0, "StakeholderIdentity: Stakeholder not registered");
        require(
            hasRole(FARMER_ROLE, msg.sender) || 
            hasRole(PROCESSOR_ROLE, msg.sender) || 
            hasRole(DISTRIBUTOR_ROLE, msg.sender) || 
            hasRole(RETAILER_ROLE, msg.sender) ||
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "StakeholderIdentity: Not authorized to record transactions"
        );

        _transactionHistory[stakeholder].push(transactionId);
        _stakeholders[stakeholder].totalTransactions++;
        _stakeholders[stakeholder].lastActivity = block.timestamp;
    }

    // ============ VERIFICATION FUNCTIONS ============
    /**
     * @notice Verify stakeholder profile integrity
     */
    function verifyStakeholderIntegrity(
        address stakeholder,
        bytes32 profileDataHash
    ) external view override stakeholderExists(stakeholder) returns (bool isValid) {
        return _stakeholders[stakeholder].profileDataHash == profileDataHash;
    }

    /**
     * @notice Check if stakeholder is verified and data is intact
     */
    function isVerifiedAndIntact(address stakeholder) external view override returns (bool) {
        if (_stakeholders[stakeholder].joinDate == 0) return false;
        return _stakeholders[stakeholder].status == VerificationStatus.VERIFIED && 
               _stakeholders[stakeholder].isActive;
    }

    /**
     * @notice Verify credential integrity
     */
    function verifyCredentialIntegrity(
        address stakeholder,
        string calldata credentialType,
        bytes32 credentialHash
    ) external view override stakeholderExists(stakeholder) returns (bool isValid) {
        CredentialHashRecord[] memory credentials = _credentials[stakeholder];
        
        for (uint256 i = 0; i < credentials.length; i++) {
            if (keccak256(bytes(credentials[i].credentialType)) == keccak256(bytes(credentialType))) {
                if (credentials[i].credentialHash == credentialHash && 
                    credentials[i].isValid && 
                    block.timestamp <= credentials[i].expiryDate) {
                    return true;
                }
            }
        }
        
        return false;
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get stakeholder hash record
     */
    function getStakeholderHashRecord(address stakeholder) 
        external view override 
        stakeholderExists(stakeholder) 
        returns (StakeholderHashRecord memory) {
        return _stakeholders[stakeholder];
    }

    /**
     * @notice Get credential hashes
     */
    function getCredentialHashes(address stakeholder) 
        external view override 
        stakeholderExists(stakeholder) 
        returns (CredentialHashRecord[] memory) {
        return _credentials[stakeholder];
    }

    /**
     * @notice Get reputation score
     */
    function getReputation(address stakeholder) external view override returns (uint256) {
        return _stakeholders[stakeholder].reputation;
    }

    /**
     * @notice Get stakeholders by type
     */
    function getStakeholdersByType(StakeholderType stakeholderType) 
        external view 
        validStakeholderType(stakeholderType) 
        returns (address[] memory) {
        return _stakeholdersByType[stakeholderType];
    }

    /**
     * @notice Get all stakeholders
     */
    function getAllStakeholders() external view returns (address[] memory) {
        return _allStakeholders;
    }

    /**
     * @notice Get stakeholder statistics
     */
    function getStakeholderStats() external view returns (
        uint256 total,
        uint256 verified,
        uint256 pending,
        uint256 active
    ) {
        total = _totalStakeholders;
        
        for (uint256 i = 0; i < _allStakeholders.length; i++) {
            address stakeholder = _allStakeholders[i];
            StakeholderHashRecord memory record = _stakeholders[stakeholder];
            
            if (record.status == VerificationStatus.VERIFIED) verified++;
            if (record.status == VerificationStatus.PENDING) pending++;
            if (record.isActive) active++;
        }
    }

    /**
     * @notice Get transaction history
     */
    function getTransactionHistory(address stakeholder) 
        external view 
        stakeholderExists(stakeholder) 
        returns (uint256[] memory) {
        return _transactionHistory[stakeholder];
    }

    /**
     * @notice Check if stakeholder has specific credential
     */
    function hasValidCredential(address stakeholder, string calldata credentialType) 
        external view 
        returns (bool) {
        CredentialHashRecord[] memory credentials = _credentials[stakeholder];
        
        for (uint256 i = 0; i < credentials.length; i++) {
            if (keccak256(bytes(credentials[i].credentialType)) == keccak256(bytes(credentialType))) {
                if (credentials[i].isValid && block.timestamp <= credentials[i].expiryDate) {
                    return true;
                }
            }
        }
        
        return false;
    }

    /**
     * @notice Get verified stakeholders
     */
    function getVerifiedStakeholders() external view returns (address[] memory) {
        address[] memory tempArray = new address[](_allStakeholders.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < _allStakeholders.length; i++) {
            if (_stakeholders[_allStakeholders[i]].status == VerificationStatus.VERIFIED) {
                tempArray[count] = _allStakeholders[i];
                count++;
            }
        }
        
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = tempArray[i];
        }
        
        return result;
    }

    /**
     * @notice Get stakeholders needing verification
     */
    function getPendingVerifications() external view returns (address[] memory) {
        address[] memory tempArray = new address[](_allStakeholders.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < _allStakeholders.length; i++) {
            if (_stakeholders[_allStakeholders[i]].status == VerificationStatus.PENDING) {
                tempArray[count] = _allStakeholders[i];
                count++;
            }
        }
        
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = tempArray[i];
        }
        
        return result;
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Suspend stakeholder
     */
    function suspendStakeholder(address stakeholder, string calldata reason) 
        external 
        onlyRole(AUDITOR_ROLE) 
        stakeholderExists(stakeholder) {
        require(bytes(reason).length > 0, "StakeholderIdentity: Reason required");

        _stakeholders[stakeholder].isActive = false;
        _stakeholders[stakeholder].status = VerificationStatus.SUSPENDED;
        
        // Revoke all stakeholder roles
        _revokeAllStakeholderRoles(stakeholder, _stakeholders[stakeholder].stakeholderType);
    }

    /**
     * @notice Reactivate stakeholder
     */
    function reactivateStakeholder(address stakeholder) 
        external 
        onlyRole(AUDITOR_ROLE) 
        stakeholderExists(stakeholder) {
        
        _stakeholders[stakeholder].isActive = true;
        _stakeholders[stakeholder].status = VerificationStatus.VERIFIED;
        
        // Re-grant appropriate role
        bytes32 role = _getStakeholderRole(_stakeholders[stakeholder].stakeholderType);
        grantRole(role, stakeholder);
    }

    /**
     * @notice Invalidate credential
     */
    function invalidateCredential(
        address stakeholder,
        uint256 credentialIndex,
        string calldata reason
    ) external onlyRole(AUDITOR_ROLE) stakeholderExists(stakeholder) {
        require(credentialIndex < _credentials[stakeholder].length, "StakeholderIdentity: Invalid credential index");
        require(bytes(reason).length > 0, "StakeholderIdentity: Reason required");

        _credentials[stakeholder][credentialIndex].isValid = false;
    }

    /**
     * @notice Batch update verification status
     */
    function batchUpdateVerification(
        address[] calldata stakeholders,
        VerificationStatus[] calldata statuses,
        bytes32[] calldata verificationHashes
    ) external onlyRole(AUDITOR_ROLE) {
        require(stakeholders.length == statuses.length, "StakeholderIdentity: Array length mismatch");
        require(stakeholders.length == verificationHashes.length, "StakeholderIdentity: Array length mismatch");

        for (uint256 i = 0; i < stakeholders.length; i++) {
            if (_stakeholders[stakeholders[i]].joinDate != 0) {
                this.updateVerificationHash(stakeholders[i], statuses[i], verificationHashes[i]);
            }
        }
    }

    /**
     * @notice Emergency deactivate stakeholder
     */
    function emergencyDeactivate(address stakeholder, string calldata reason) 
        external 
        onlyRole(EMERGENCY_ROLE) 
        stakeholderExists(stakeholder) {
        
        _stakeholders[stakeholder].isActive = false;
        _stakeholders[stakeholder].status = VerificationStatus.SUSPENDED;
        
        _revokeAllStakeholderRoles(stakeholder, _stakeholders[stakeholder].stakeholderType);
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Get role for stakeholder type
     */
    function _getStakeholderRole(StakeholderType stakeholderType) internal pure returns (bytes32) {
        if (stakeholderType == StakeholderType.FARMER) return FARMER_ROLE;
        if (stakeholderType == StakeholderType.PROCESSOR) return PROCESSOR_ROLE;
        if (stakeholderType == StakeholderType.DISTRIBUTOR) return DISTRIBUTOR_ROLE;
        if (stakeholderType == StakeholderType.RETAILER) return RETAILER_ROLE;
        if (stakeholderType == StakeholderType.CONSUMER) return CONSUMER_ROLE;
        if (stakeholderType == StakeholderType.AUDITOR) return AUDITOR_ROLE;
        if (stakeholderType == StakeholderType.ADMIN) return DEFAULT_ADMIN_ROLE;
        revert("StakeholderIdentity: Invalid stakeholder type");
    }

    /**
     * @dev Revoke all roles for stakeholder type
     */
    function _revokeAllStakeholderRoles(address stakeholder, StakeholderType stakeholderType) internal {
        bytes32 role = _getStakeholderRole(stakeholderType);
        if (hasRole(role, stakeholder)) {
            revokeRole(role, stakeholder);
        }
    }
}