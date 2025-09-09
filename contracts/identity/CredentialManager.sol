// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IStakeholder.sol";
import "../core/AgriAccessControl.sol";
import "../libraries/DateTimeLib.sol";

/**
 * @title CredentialManager
 * @dev Manages certifications and licenses for stakeholders (hash-based storage)
 * @author AgriTrace Team
 */
contract CredentialManager is AgriAccessControl {
    using DateTimeLib for uint256;

    // ============ EVENTS ============
    event CredentialHashIssued(
        address indexed holder,
        bytes32 indexed credentialId,
        string credentialType,
        address indexed issuer,
        bytes32 documentHash,
        uint256 expiryDate,
        uint256 timestamp
    );

    event CredentialRevoked(
        address indexed holder,
        bytes32 indexed credentialId,
        address indexed revoker,
        string reason,
        uint256 timestamp
    );

    event CredentialRenewed(
        address indexed holder,
        bytes32 indexed credentialId,
        uint256 newExpiryDate,
        uint256 timestamp
    );

    event IssuerAuthorized(
        address indexed issuer,
        string organizationName,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct CredentialHash {
        bytes32 id;
        string credentialType;
        bytes32 documentHash;
        address holder;
        address issuer;
        uint256 issueDate;
        uint256 expiryDate;
        bool isActive;
        bool isVerified;
    }

    struct AuthorizedIssuer {
        address issuerAddress;
        bytes32 organizationHash;
        bool isActive;
        uint256 authorizedDate;
        uint256 totalIssued;
    }

    // ============ STATE VARIABLES ============
    mapping(bytes32 => CredentialHash) private _credentials;
    mapping(address => bytes32[]) private _holderCredentials;
    mapping(address => AuthorizedIssuer) private _authorizedIssuers;
    mapping(string => uint256) private _credentialValidityPeriods;
    
    IStakeholder public stakeholderContract;
    
    uint256 private _credentialCounter;

    // Default validity periods (in seconds)
    uint256 public constant DEFAULT_VALIDITY = 365 days;
    uint256 public constant ORGANIC_CERT_VALIDITY = 365 days;
    uint256 public constant QUALITY_CERT_VALIDITY = 180 days;

    // ============ MODIFIERS ============
    modifier onlyAuthorizedIssuer() {
        require(_authorizedIssuers[msg.sender].isActive, "CredentialManager: Not authorized issuer");
        _;
    }

    modifier credentialExists(bytes32 credentialId) {
        require(_credentials[credentialId].id != bytes32(0), "CredentialManager: Credential not found");
        _;
    }

    modifier validExpiryDate(uint256 expiryDate) {
        require(expiryDate > block.timestamp, "CredentialManager: Invalid expiry date");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _credentialCounter = 0;
        
        // Set default validity periods
        _credentialValidityPeriods["ORGANIC"] = ORGANIC_CERT_VALIDITY;
        _credentialValidityPeriods["QUALITY"] = QUALITY_CERT_VALIDITY;
        _credentialValidityPeriods["SAFETY"] = DEFAULT_VALIDITY;
        _credentialValidityPeriods["LAND_OWNERSHIP"] = DEFAULT_VALIDITY * 10; // 10 years
    }

    // ============ SETUP FUNCTIONS ============
    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakeholderContract != address(0), "CredentialManager: Invalid stakeholder contract");
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    // ============ ISSUER MANAGEMENT ============
    /**
     * @notice Authorize credential issuer
     */
    function authorizeIssuer(
        address issuer,
        bytes32 organizationHash
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(issuer != address(0), "CredentialManager: Invalid issuer address");
        require(organizationHash != bytes32(0), "CredentialManager: Organization hash required");
        require(!_authorizedIssuers[issuer].isActive, "CredentialManager: Issuer already authorized");

        _authorizedIssuers[issuer] = AuthorizedIssuer({
            issuerAddress: issuer,
            organizationHash: organizationHash,
            isActive: true,
            authorizedDate: block.timestamp,
            totalIssued: 0
        });

        emit IssuerAuthorized(issuer, "", block.timestamp);
    }

    /**
     * @notice Revoke issuer authorization
     */
    function revokeIssuer(address issuer, string calldata reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_authorizedIssuers[issuer].isActive, "CredentialManager: Issuer not authorized");
        require(bytes(reason).length > 0, "CredentialManager: Reason required");

        _authorizedIssuers[issuer].isActive = false;
    }

    // ============ CREDENTIAL MANAGEMENT ============
    /**
     * @notice Issue new credential
     */
    function issueCredential(
        address holder,
        string calldata credentialType,
        bytes32 documentHash,
        uint256 customExpiryDate
    ) external onlyAuthorizedIssuer validExpiryDate(customExpiryDate) returns (bytes32 credentialId) {
        require(holder != address(0), "CredentialManager: Invalid holder address");
        require(bytes(credentialType).length > 0, "CredentialManager: Credential type required");
        require(documentHash != bytes32(0), "CredentialManager: Document hash required");
        
        // Verify holder is registered stakeholder
        if (address(stakeholderContract) != address(0)) {
            require(stakeholderContract.isVerifiedAndIntact(holder), "CredentialManager: Holder not verified");
        }

        _credentialCounter++;
        credentialId = keccak256(abi.encodePacked(
            holder,
            credentialType,
            msg.sender,
            block.timestamp,
            _credentialCounter
        ));

        uint256 expiryDate = customExpiryDate;
        if (expiryDate == 0) {
            uint256 validityPeriod = _credentialValidityPeriods[credentialType];
            if (validityPeriod == 0) validityPeriod = DEFAULT_VALIDITY;
            expiryDate = block.timestamp + validityPeriod;
        }

        _credentials[credentialId] = CredentialHash({
            id: credentialId,
            credentialType: credentialType,
            documentHash: documentHash,
            holder: holder,
            issuer: msg.sender,
            issueDate: block.timestamp,
            expiryDate: expiryDate,
            isActive: true,
            isVerified: false
        });

        _holderCredentials[holder].push(credentialId);
        _authorizedIssuers[msg.sender].totalIssued++;

        // Add to stakeholder contract
        if (address(stakeholderContract) != address(0)) {
            stakeholderContract.addCredentialHash(holder, credentialType, documentHash, expiryDate);
        }

        emit CredentialHashIssued(holder, credentialId, credentialType, msg.sender, documentHash, expiryDate, block.timestamp);
        
        return credentialId;
    }

    /**
     * @notice Verify credential
     */
    function verifyCredential(bytes32 credentialId) external onlyRole(AUDITOR_ROLE) credentialExists(credentialId) {
        _credentials[credentialId].isVerified = true;
    }

    /**
     * @notice Revoke credential
     */
    function revokeCredential(
        bytes32 credentialId,
        string calldata reason
    ) external credentialExists(credentialId) {
        CredentialHash storage credential = _credentials[credentialId];
        
        require(
            msg.sender == credential.issuer || 
            hasRole(AUDITOR_ROLE, msg.sender) || 
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "CredentialManager: Not authorized to revoke"
        );
        require(bytes(reason).length > 0, "CredentialManager: Reason required");

        credential.isActive = false;

        emit CredentialRevoked(credential.holder, credentialId, msg.sender, reason, block.timestamp);
    }

    /**
     * @notice Renew credential
     */
    function renewCredential(
        bytes32 credentialId,
        bytes32 newDocumentHash,
        uint256 newExpiryDate
    ) external onlyAuthorizedIssuer credentialExists(credentialId) validExpiryDate(newExpiryDate) {
        CredentialHash storage credential = _credentials[credentialId];
        
        require(msg.sender == credential.issuer, "CredentialManager: Only issuer can renew");
        require(newDocumentHash != bytes32(0), "CredentialManager: Document hash required");

        credential.documentHash = newDocumentHash;
        credential.expiryDate = newExpiryDate;
        credential.isActive = true;

        emit CredentialRenewed(credential.holder, credentialId, newExpiryDate, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get credential by ID
     */
    function getCredential(bytes32 credentialId) external view credentialExists(credentialId) returns (CredentialHash memory) {
        return _credentials[credentialId];
    }

    /**
     * @notice Get holder's credentials
     */
    function getHolderCredentials(address holder) external view returns (bytes32[] memory) {
        return _holderCredentials[holder];
    }

    /**
     * @notice Check if credential is valid
     */
    function isCredentialValid(bytes32 credentialId) external view returns (bool) {
        CredentialHash memory credential = _credentials[credentialId];
        return credential.isActive && block.timestamp <= credential.expiryDate;
    }

    /**
     * @notice Verify credential integrity
     */
    function verifyCredentialIntegrity(
        bytes32 credentialId,
        bytes32 currentDocumentHash
    ) external view credentialExists(credentialId) returns (bool) {
        return _credentials[credentialId].documentHash == currentDocumentHash;
    }

    /**
     * @notice Check if holder has valid credential type
     */
    function hasValidCredentialType(address holder, string calldata credentialType) external view returns (bool) {
        bytes32[] memory credentials = _holderCredentials[holder];
        
        for (uint256 i = 0; i < credentials.length; i++) {
            CredentialHash memory credential = _credentials[credentials[i]];
            if (keccak256(bytes(credential.credentialType)) == keccak256(bytes(credentialType))) {
                if (credential.isActive && block.timestamp <= credential.expiryDate) {
                    return true;
                }
            }
        }
        
        return false;
    }

    /**
     * @notice Get authorized issuer info
     */
    function getAuthorizedIssuer(address issuer) external view returns (AuthorizedIssuer memory) {
        return _authorizedIssuers[issuer];
    }

    /**
     * @notice Get expiring credentials
     */
    function getExpiringCredentials(uint256 daysUntilExpiry) external view returns (bytes32[] memory) {
        uint256 expiryThreshold = block.timestamp + (daysUntilExpiry * 1 days);
        bytes32[] memory tempCredentials = new bytes32[](_credentialCounter);
        uint256 count = 0;

        // Note: In production, this should be optimized with better indexing
        // This is a simplified implementation for demonstration
        for (uint256 i = 1; i <= _credentialCounter; i++) {
            // This is a simplified approach - in production, maintain a mapping
        }

        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = tempCredentials[i];
        }

        return result;
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Set credential validity period
     */
    function setCredentialValidityPeriod(
        string calldata credentialType,
        uint256 validityPeriod
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bytes(credentialType).length > 0, "CredentialManager: Credential type required");
        require(validityPeriod >= 30 days && validityPeriod <= 3650 days, "CredentialManager: Invalid validity period");

        _credentialValidityPeriods[credentialType] = validityPeriod;
    }

    /**
     * @notice Batch revoke credentials
     */
    function batchRevokeCredentials(
        bytes32[] calldata credentialIds,
        string calldata reason
    ) external onlyRole(AUDITOR_ROLE) {
        require(bytes(reason).length > 0, "CredentialManager: Reason required");

        for (uint256 i = 0; i < credentialIds.length; i++) {
            if (_credentials[credentialIds[i]].id != bytes32(0)) {
                _credentials[credentialIds[i]].isActive = false;
                emit CredentialRevoked(_credentials[credentialIds[i]].holder, credentialIds[i], msg.sender, reason, block.timestamp);
            }
        }
    }

    /**
     * @notice Emergency credential suspension
     */
    function emergencyRevokeCredential(bytes32 credentialId, string calldata reason) 
        external 
        onlyRole(EMERGENCY_ROLE) 
        credentialExists(credentialId) {
        
        _credentials[credentialId].isActive = false;
        emit CredentialRevoked(_credentials[credentialId].holder, credentialId, msg.sender, string(abi.encodePacked("EMERGENCY: ", reason)), block.timestamp);
    }
}
