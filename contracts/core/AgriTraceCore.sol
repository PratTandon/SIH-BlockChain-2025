// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IAgriTrace.sol";
import "../interfaces/IStakeholder.sol";
import "../interfaces/IHashVerification.sol";
import "../interfaces/IMLOracle.sol";
import "../libraries/CostCalculator.sol";
import "../libraries/QualityMetrics.sol";
import "../libraries/GeolocationLib.sol";
import "../libraries/DateTimeLib.sol";
import "./AgriAccessControl.sol";
import "./EmergencyController.sol";

/**
 * @title AgriTraceCore
 * @dev Main orchestrator contract for AgriTrace platform
 * @author AgriTrace Team
 */
contract AgriTraceCore is IAgriTrace, AgriAccessControl, EmergencyController {
    using CostCalculator for CostCalculator.CostBreakdown;
    using QualityMetrics for QualityMetrics.QualityData;
    using GeolocationLib for GeolocationLib.GPSCoordinate;
    using DateTimeLib for uint256;

    // ============ STATE VARIABLES ============
    uint256 private _productCounter;
    mapping(uint256 => ProductHashRecord) private _products;
    mapping(uint256 => StageHashRecord[]) private _stageChains;
    mapping(uint256 => bytes32[]) private _hashChains;
    mapping(uint256 => mapping(uint8 => bytes32)) private _stageCosts;
    mapping(uint256 => bytes32) private _qualityHashes;
    mapping(string => bool) private _usedBatchIds;

    // Contract references
    IStakeholder public stakeholderContract;
    IHashVerification public hashVerificationContract;
    IMLOracle public mlOracleContract;

    // ============ MODIFIERS ============
    modifier productExists(uint256 productId) {
        require(_products[productId].id != 0, "AgriTraceCore: Product does not exist");
        _;
    }

    modifier validBatchId(string calldata batchId) {
        require(bytes(batchId).length > 0, "AgriTraceCore: Batch ID cannot be empty");
        require(!_usedBatchIds[batchId], "AgriTraceCore: Batch ID already used");
        _;
    }

    modifier onlyProductOwner(uint256 productId) {
        require(_products[productId].currentOwner == msg.sender, "AgriTraceCore: Not product owner");
        _;
    }

    modifier validStageProgression(uint256 productId, ProductStage newStage) {
        ProductStage currentStage = _products[productId].currentStage;
        require(uint8(newStage) == uint8(currentStage) + 1, "AgriTraceCore: Invalid stage progression");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(FARMER_ROLE, msg.sender);
        _productCounter = 0;
    }

    // ============ CONTRACT SETUP ============
    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakeholderContract != address(0), "AgriTraceCore: Invalid stakeholder contract");
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    function setHashVerificationContract(address _hashVerificationContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_hashVerificationContract != address(0), "AgriTraceCore: Invalid hash verification contract");
        hashVerificationContract = IHashVerification(_hashVerificationContract);
    }

    function setMLOracleContract(address _mlOracleContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_mlOracleContract != address(0), "AgriTraceCore: Invalid ML oracle contract");
        mlOracleContract = IMLOracle(_mlOracleContract);
    }

    // ============ CORE FUNCTIONS ============
    /**
     * @notice Register new product with initial data hash
     */
    function registerProductHash(
        string calldata batchId,
        bytes32 dataHash
    ) external override 
      onlyRole(FARMER_ROLE) 
      validBatchId(batchId) 
      whenNotPaused 
      returns (uint256 productId) {
        
        require(dataHash != bytes32(0), "AgriTraceCore: Data hash cannot be empty");
        require(address(stakeholderContract) != address(0), "AgriTraceCore: Stakeholder contract not set");
        require(stakeholderContract.isVerifiedAndIntact(msg.sender), "AgriTraceCore: Farmer not verified");

        _productCounter++;
        productId = _productCounter;

        _products[productId] = ProductHashRecord({
            id: productId,
            batchId: batchId,
            farmer: msg.sender,
            currentOwner: msg.sender,
            initialDataHash: dataHash,
            currentStage: ProductStage.PLANTED,
            createdAt: block.timestamp,
            lastUpdated: block.timestamp,
            isActive: true
        });

        _usedBatchIds[batchId] = true;
        _hashChains[productId].push(dataHash);

        emit ProductHashRegistered(productId, msg.sender, dataHash, batchId, block.timestamp);
        
        return productId;
    }

    /**
     * @notice Add stage hash to product chain
     */
    function addStageHash(
        uint256 productId,
        ProductStage stage,
        bytes32 stageDataHash
    ) external override 
      productExists(productId)
      onlyProductOwner(productId)
      validStageProgression(productId, stage)
      whenNotPaused
      returns (bool success) {
        
        require(stageDataHash != bytes32(0), "AgriTraceCore: Stage data hash cannot be empty");
        
        bytes32 previousHash = _hashChains[productId].length > 0 ? 
            _hashChains[productId][_hashChains[productId].length - 1] : bytes32(0);

        StageHashRecord memory stageRecord = StageHashRecord({
            stageDataHash: stageDataHash,
            previousStageHash: previousHash,
            stakeholder: msg.sender,
            stage: stage,
            timestamp: block.timestamp,
            isVerified: true
        });

        _stageChains[productId].push(stageRecord);
        _hashChains[productId].push(stageDataHash);
        
        _products[productId].currentStage = stage;
        _products[productId].lastUpdated = block.timestamp;

        emit StageHashAdded(productId, uint8(stage), stageDataHash, previousHash, msg.sender, block.timestamp);
        
        return true;
    }

    /**
     * @notice Update quality assessment hash
     */
    function updateQualityHash(
        uint256 productId,
        bytes32 qualityHash,
        uint256 score
    ) external override 
      productExists(productId)
      onlyRole(AUDITOR_ROLE)
      whenNotPaused {
        
        require(qualityHash != bytes32(0), "AgriTraceCore: Quality hash cannot be empty");
        require(score <= 1000, "AgriTraceCore: Score must be <= 1000");

        _qualityHashes[productId] = qualityHash;
        _products[productId].lastUpdated = block.timestamp;

        emit QualityHashUpdated(productId, qualityHash, score, block.timestamp);
    }

    /**
     * @notice Transfer ownership with hash verification
     */
    function transferOwnershipWithHash(
        uint256 productId,
        address newOwner,
        bytes32 transferDataHash
    ) external override 
      productExists(productId)
      onlyProductOwner(productId)
      whenNotPaused {
        
        require(newOwner != address(0), "AgriTraceCore: Invalid new owner");
        require(newOwner != msg.sender, "AgriTraceCore: Cannot transfer to self");
        require(transferDataHash != bytes32(0), "AgriTraceCore: Transfer hash cannot be empty");
        require(stakeholderContract.isVerifiedAndIntact(newOwner), "AgriTraceCore: New owner not verified");

        address previousOwner = _products[productId].currentOwner;
        _products[productId].currentOwner = newOwner;
        _products[productId].lastUpdated = block.timestamp;

        emit OwnershipTransferHash(productId, previousOwner, newOwner, transferDataHash, block.timestamp);
    }

    /**
     * @notice Verify data integrity against stored hash
     */
    function verifyDataIntegrity(
        uint256 productId,
        ProductStage stage,
        bytes32 dataHash
    ) external view override 
      productExists(productId)
      returns (bool isValid) {
        
        uint8 stageIndex = uint8(stage);
        
        if (stageIndex == 0) {
            return _products[productId].initialDataHash == dataHash;
        }
        
        if (stageIndex <= _stageChains[productId].length) {
            return _stageChains[productId][stageIndex - 1].stageDataHash == dataHash;
        }
        
        return false;
    }

    /**
     * @notice Flag integrity violation
     */
    function flagIntegrityViolation(
        uint256 productId,
        ProductStage stage,
        bytes32 expectedHash,
        bytes32 actualHash
    ) external override 
      productExists(productId)
      onlyRole(AUDITOR_ROLE) {
        
        emit DataIntegrityViolation(productId, uint8(stage), expectedHash, actualHash, block.timestamp);
        
        // Automatically pause product if integrity is compromised
        _products[productId].isActive = false;
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get product hash record
     */
    function getProductHashRecord(uint256 productId) 
        external view override 
        productExists(productId)
        returns (ProductHashRecord memory) {
        return _products[productId];
    }

    /**
     * @notice Get stage hash chain
     */
    function getStageHashChain(uint256 productId) 
        external view override 
        productExists(productId)
        returns (StageHashRecord[] memory) {
        return _stageChains[productId];
    }

    /**
     * @notice Get complete hash chain
     */
    function getCompleteHashChain(uint256 productId) 
        external view override 
        productExists(productId)
        returns (bytes32[] memory) {
        return _hashChains[productId];
    }

    /**
     * @notice Check if hash chain is intact
     */
    function isHashChainIntact(uint256 productId) 
        external view override 
        productExists(productId)
        returns (bool isIntact) {
        
        StageHashRecord[] memory stages = _stageChains[productId];
        
        for (uint i = 1; i < stages.length; i++) {
            if (stages[i].previousStageHash != stages[i-1].stageDataHash) {
                return false;
            }
        }
        
        return true;
    }

    /**
     * @notice Get total number of products
     */
    function getTotalProducts() external view returns (uint256) {
        return _productCounter;
    }

    /**
     * @notice Check if product is active
     */
    function isProductActive(uint256 productId) external view returns (bool) {
        return _products[productId].isActive;
    }

    /**
     * @notice Get products by farmer
     */
    function getProductsByFarmer(address farmer) external view returns (uint256[] memory) {
        uint256[] memory tempProducts = new uint256[](_productCounter);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= _productCounter; i++) {
            if (_products[i].farmer == farmer) {
                tempProducts[count] = i;
                count++;
            }
        }
        
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = tempProducts[i];
        }
        
        return result;
    }

    /**
     * @notice Get products by current owner
     */
    function getProductsByOwner(address owner) external view returns (uint256[] memory) {
        uint256[] memory tempProducts = new uint256[](_productCounter);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= _productCounter; i++) {
            if (_products[i].currentOwner == owner && _products[i].isActive) {
                tempProducts[count] = i;
                count++;
            }
        }
        
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = tempProducts[i];
        }
        
        return result;
    }

    /**
     * @notice Get quality hash for product
     */
    function getQualityHash(uint256 productId) external view productExists(productId) returns (bytes32) {
        return _qualityHashes[productId];
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Deactivate product (admin only)
     */
    function deactivateProduct(uint256 productId, string calldata reason) 
        external 
        productExists(productId)
        onlyRole(DEFAULT_ADMIN_ROLE) {
        
        _products[productId].isActive = false;
        emit DataIntegrityViolation(productId, uint8(_products[productId].currentStage), bytes32(0), bytes32(0), block.timestamp);
    }

    /**
     * @notice Reactivate product (admin only)
     */
    function reactivateProduct(uint256 productId) 
        external 
        productExists(productId)
        onlyRole(DEFAULT_ADMIN_ROLE) {
        
        _products[productId].isActive = true;
    }

    /**
     * @notice Emergency batch deactivation
     */
    function emergencyBatchDeactivation(uint256[] calldata productIds, string calldata reason) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) {
        
        for (uint256 i = 0; i < productIds.length; i++) {
            if (_products[productIds[i]].id != 0) {
                _products[productIds[i]].isActive = false;
            }
        }
    }
}
