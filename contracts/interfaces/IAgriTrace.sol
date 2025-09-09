// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IAgriTrace
 * @dev Main interface for hash-based agricultural supply chain verification
 * @author AgriTrace Team
 */
interface IAgriTrace {
    // ============ EVENTS ============
    event ProductHashRegistered(
        uint256 indexed productId, 
        address indexed farmer, 
        bytes32 indexed dataHash,
        string batchId,
        uint256 timestamp
    );
    
    event StageHashAdded(
        uint256 indexed productId, 
        uint8 indexed stage, 
        bytes32 indexed stageHash,
        bytes32 previousHash,
        address stakeholder,
        uint256 timestamp
    );
    
    event QualityHashUpdated(
        uint256 indexed productId, 
        bytes32 indexed qualityHash,
        uint256 score,
        uint256 timestamp
    );
    
    event OwnershipTransferHash(
        uint256 indexed productId, 
        address indexed from, 
        address indexed to,
        bytes32 transferHash,
        uint256 timestamp
    );
    
    event DataIntegrityViolation(
        uint256 indexed productId,
        uint8 stage,
        bytes32 expectedHash,
        bytes32 actualHash,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum ProductStage {
        PLANTED,      // 0
        GROWING,      // 1 
        HARVESTED,    // 2
        PROCESSED,    // 3
        PACKAGED,     // 4
        SHIPPED,      // 5
        DELIVERED,    // 6
        SOLD          // 7
    }

    // ============ STRUCTS ============
    struct ProductHashRecord {
        uint256 id;
        string batchId;
        address farmer;
        address currentOwner;
        bytes32 initialDataHash;
        ProductStage currentStage;
        uint256 createdAt;
        uint256 lastUpdated;
        bool isActive;
    }

    struct StageHashRecord {
        bytes32 stageDataHash;
        bytes32 previousStageHash;
        address stakeholder;
        ProductStage stage;
        uint256 timestamp;
        bool isVerified;
    }

    // ============ CORE FUNCTIONS ============
    function registerProductHash(string calldata batchId, bytes32 dataHash) external returns (uint256 productId);
    function addStageHash(uint256 productId, ProductStage stage, bytes32 stageDataHash) external returns (bool success);
    function updateQualityHash(uint256 productId, bytes32 qualityHash, uint256 score) external;
    function transferOwnershipWithHash(uint256 productId, address newOwner, bytes32 transferDataHash) external;
    function verifyDataIntegrity(uint256 productId, ProductStage stage, bytes32 dataHash) external view returns (bool isValid);
    function getProductHashRecord(uint256 productId) external view returns (ProductHashRecord memory);
    function getStageHashChain(uint256 productId) external view returns (StageHashRecord[] memory);
    function getCompleteHashChain(uint256 productId) external view returns (bytes32[] memory);
    function flagIntegrityViolation(uint256 productId, ProductStage stage, bytes32 expectedHash, bytes32 actualHash) external;
    function isHashChainIntact(uint256 productId) external view returns (bool isIntact);
}
