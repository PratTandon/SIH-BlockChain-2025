// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";
import "../interfaces/IStakeholder.sol";

/**
 * @title ProductHistory
 * @dev Public product information and traceability
 * @author AgriTrace Team
 */
contract ProductHistory is AgriAccessControl {

    // ============ EVENTS ============
    event ProductHistoryRecorded(
        uint256 indexed productId,
        uint8 indexed stage,
        bytes32 indexed historyHash,
        address recorder,
        uint256 timestamp
    );

    event PublicInfoUpdated(
        uint256 indexed productId,
        bytes32 publicDataHash,
        uint256 timestamp
    );

    event VerificationAdded(
        uint256 indexed productId,
        bytes32 verificationHash,
        address verifier,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct HistoryEntry {
        uint256 productId;
        uint8 stage;
        bytes32 dataHash;
        bytes32 locationHash;
        address stakeholder;
        uint256 timestamp;
        string stageDescription;
        bool isPublic;
        bool isVerified;
    }

    struct PublicProductInfo {
        uint256 productId;
        string productName;
        string productType;
        bytes32 originHash;
        bytes32 certificationHash;
        bytes32 qualityHash;
        uint256 harvestDate;
        uint256 expiryDate;
        bool isOrganic;
        bool isLocal;
        uint256 lastUpdated;
    }

    struct TraceabilityPath {
        address farmer;
        address processor;
        address distributor;
        address retailer;
        uint256[] timestamps;
        bytes32[] locationHashes;
        bytes32[] verificationHashes;
    }

    struct VerificationRecord {
        bytes32 verificationHash;
        address verifier;
        string verificationType;
        uint256 timestamp;
        bool isValid;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => HistoryEntry[]) private _productHistory;
    mapping(uint256 => PublicProductInfo) private _publicInfo;
    mapping(uint256 => TraceabilityPath) private _traceabilityPaths;
    mapping(uint256 => VerificationRecord[]) private _verifications;
    mapping(uint256 => mapping(uint8 => bool)) private _stageCompleted;
    
    // Contract references
    IStakeholder public stakeholderContract;
    address public productLifecycleContract;
    address public qualityAssuranceContract;

    // ============ MODIFIERS ============
    modifier validProductId(uint256 productId) {
        require(productId > 0, "ProductHistory: Invalid product ID");
        _;
    }

    modifier validStage(uint8 stage) {
        require(stage <= 7, "ProductHistory: Invalid stage");
        _;
    }

    modifier onlyAuthorizedRecorder() {
        require(
            hasRole(FARMER_ROLE, msg.sender) ||
            hasRole(PROCESSOR_ROLE, msg.sender) ||
            hasRole(DISTRIBUTOR_ROLE, msg.sender) ||
            hasRole(RETAILER_ROLE, msg.sender) ||
            hasRole(AUDITOR_ROLE, msg.sender),
            "ProductHistory: Not authorized to record history"
        );
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============ SETUP FUNCTIONS ============
    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    function setProductLifecycleContract(address _productLifecycleContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        productLifecycleContract = _productLifecycleContract;
    }

    function setQualityAssuranceContract(address _qualityAssuranceContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        qualityAssuranceContract = _qualityAssuranceContract;
    }

    // ============ HISTORY FUNCTIONS ============
    /**
     * @notice Record product history entry
     */
    function recordHistory(
        uint256 productId,
        uint8 stage,
        bytes32 dataHash,
        bytes32 locationHash,
        string calldata stageDescription,
        bool isPublic
    ) external 
      validProductId(productId) 
      validStage(stage) 
      onlyAuthorizedRecorder {
        
        require(dataHash != bytes32(0), "ProductHistory: Data hash required");
        require(bytes(stageDescription).length > 0, "ProductHistory: Stage description required");

        HistoryEntry memory entry = HistoryEntry({
            productId: productId,
            stage: stage,
            dataHash: dataHash,
            locationHash: locationHash,
            stakeholder: msg.sender,
            timestamp: block.timestamp,
            stageDescription: stageDescription,
            isPublic: isPublic,
            isVerified: false
        });

        _productHistory[productId].push(entry);
        _stageCompleted[productId][stage] = true;

        // Update traceability path
        _updateTraceabilityPath(productId, stage, msg.sender, locationHash);

        emit ProductHistoryRecorded(productId, stage, dataHash, msg.sender, block.timestamp);
    }

    /**
     * @notice Update public product information
     */
    function updatePublicInfo(
        uint256 productId,
        string calldata productName,
        string calldata productType,
        bytes32 originHash,
        bytes32 certificationHash,
        bytes32 qualityHash,
        uint256 harvestDate,
        uint256 expiryDate,
        bool isOrganic,
        bool isLocal
    ) external validProductId(productId) onlyAuthorizedRecorder {
        require(bytes(productName).length > 0, "ProductHistory: Product name required");
        require(originHash != bytes32(0), "ProductHistory: Origin hash required");

        bytes32 publicDataHash = keccak256(abi.encodePacked(
            productName,
            productType,
            originHash,
            harvestDate,
            isOrganic,
            isLocal
        ));

        _publicInfo[productId] = PublicProductInfo({
            productId: productId,
            productName: productName,
            productType: productType,
            originHash: originHash,
            certificationHash: certificationHash,
            qualityHash: qualityHash,
            harvestDate: harvestDate,
            expiryDate: expiryDate,
            isOrganic: isOrganic,
            isLocal: isLocal,
            lastUpdated: block.timestamp
        });

        emit PublicInfoUpdated(productId, publicDataHash, block.timestamp);
    }

    /**
     * @notice Add verification record
     */
    function addVerification(
        uint256 productId,
        bytes32 verificationHash,
        string calldata verificationType
    ) external onlyRole(AUDITOR_ROLE) validProductId(productId) {
        require(verificationHash != bytes32(0), "ProductHistory: Verification hash required");
        require(bytes(verificationType).length > 0, "ProductHistory: Verification type required");

        VerificationRecord memory verification = VerificationRecord({
            verificationHash: verificationHash,
            verifier: msg.sender,
            verificationType: verificationType,
            timestamp: block.timestamp,
            isValid: true
        });

        _verifications[productId].push(verification);

        emit VerificationAdded(productId, verificationHash, msg.sender, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get public product history
     */
    function getPublicHistory(uint256 productId) external view validProductId(productId) returns (HistoryEntry[] memory) {
        HistoryEntry[] memory allHistory = _productHistory[productId];
        HistoryEntry[] memory temp = new HistoryEntry[](allHistory.length);
        uint256 count = 0;

        for (uint256 i = 0; i < allHistory.length; i++) {
            if (allHistory[i].isPublic) {
                temp[count] = allHistory[i];
                count++;
            }
        }

        HistoryEntry[] memory result = new HistoryEntry[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }

        return result;
    }

    /**
     * @notice Get complete product history (authorized users only)
     */
    function getCompleteHistory(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (HistoryEntry[] memory) {
        
        require(
            hasRole(AUDITOR_ROLE, msg.sender) ||
            (address(stakeholderContract) != address(0) && stakeholderContract.isVerifiedAndIntact(msg.sender)),
            "ProductHistory: Not authorized for complete history"
        );

        return _productHistory[productId];
    }

    /**
     * @notice Get public product information
     */
    function getPublicProductInfo(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (PublicProductInfo memory) {
        return _publicInfo[productId];
    }

    /**
     * @notice Get traceability path
     */
    function getTraceabilityPath(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (TraceabilityPath memory) {
        return _traceabilityPaths[productId];
    }

    /**
     * @notice Get verification records
     */
    function getVerifications(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (VerificationRecord[] memory) {
        return _verifications[productId];
    }

    /**
     * @notice Check if stage is completed
     */
    function isStageCompleted(uint256 productId, uint8 stage) 
        external view 
        validProductId(productId) 
        validStage(stage) 
        returns (bool) {
        return _stageCompleted[productId][stage];
    }

    /**
     * @notice Get product progress percentage
     */
    function getProductProgress(uint256 productId) external view validProductId(productId) returns (uint256) {
        uint256 completedStages = 0;
        for (uint8 i = 0; i <= 7; i++) {
            if (_stageCompleted[productId][i]) {
                completedStages++;
            }
        }
        return (completedStages * 100) / 8; // 8 total stages
    }

    /**
     * @notice Verify history integrity
     */
    function verifyHistoryIntegrity(
        uint256 productId,
        uint256 historyIndex,
        bytes32 currentDataHash
    ) external view returns (bool) {
        HistoryEntry[] memory history = _productHistory[productId];
        if (historyIndex >= history.length) return false;
        
        return history[historyIndex].dataHash == currentDataHash;
    }

    /**
     * @notice Get stakeholder journey
     */
    function getStakeholderJourney(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (address[] memory stakeholders, uint8[] memory stages) {
        
        HistoryEntry[] memory history = _productHistory[productId];
        address[] memory tempStakeholders = new address[](history.length);
        uint8[] memory tempStages = new uint8[](history.length);
        
        for (uint256 i = 0; i < history.length; i++) {
            tempStakeholders[i] = history[i].stakeholder;
            tempStages[i] = history[i].stage;
        }
        
        return (tempStakeholders, tempStages);
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Verify history entry
     */
    function verifyHistoryEntry(uint256 productId, uint256 historyIndex) 
        external 
        onlyRole(AUDITOR_ROLE) 
        validProductId(productId) {
        
        require(historyIndex < _productHistory[productId].length, "ProductHistory: Invalid history index");
        _productHistory[productId][historyIndex].isVerified = true;
    }

    /**
     * @notice Invalidate verification
     */
    function invalidateVerification(uint256 productId, uint256 verificationIndex) 
        external 
        onlyRole(AUDITOR_ROLE) 
        validProductId(productId) {
        
        require(verificationIndex < _verifications[productId].length, "ProductHistory: Invalid verification index");
        _verifications[productId][verificationIndex].isValid = false;
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Update traceability path
     */
    function _updateTraceabilityPath(
        uint256 productId,
        uint8 stage,
        address stakeholder,
        bytes32 locationHash
    ) internal {
        TraceabilityPath storage path = _traceabilityPaths[productId];
        
        if (stage <= 2 && path.farmer == address(0)) {
            path.farmer = stakeholder;
        } else if (stage == 3 && path.processor == address(0)) {
            path.processor = stakeholder;
        } else if ((stage == 4 || stage == 5) && path.distributor == address(0)) {
            path.distributor = stakeholder;
        } else if ((stage == 6 || stage == 7) && path.retailer == address(0)) {
            path.retailer = stakeholder;
        }
        
        path.timestamps.push(block.timestamp);
        path.locationHashes.push(locationHash);
    }
}