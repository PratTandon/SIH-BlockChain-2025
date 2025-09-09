// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";

/**
 * @title BatchManagement
 * @dev Batch operations and relationships management
 * @author AgriTrace Team
 */
contract BatchManagement is AgriAccessControl {

    // ============ EVENTS ============
    event BatchCreated(
        uint256 indexed batchId,
        string batchCode,
        address indexed creator,
        uint256 timestamp
    );

    event ProductAddedToBatch(
        uint256 indexed batchId,
        uint256 indexed productId,
        uint256 timestamp
    );

    event BatchSplit(
        uint256 indexed originalBatchId,
        uint256[] newBatchIds,
        uint256[] quantities,
        uint256 timestamp
    );

    event BatchMerged(
        uint256[] sourceBatchIds,
        uint256 indexed newBatchId,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct Batch {
        uint256 batchId;
        string batchCode;
        uint256[] productIds;
        uint256 totalQuantity;
        address creator;
        uint256 createdAt;
        bool isActive;
        bytes32 batchDataHash;
    }

    struct BatchRelationship {
        uint256 parentBatchId;
        uint256[] childBatchIds;
        string relationshipType; // "SPLIT", "MERGE"
        uint256 timestamp;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => Batch) private _batches;
    mapping(string => uint256) private _batchCodeToId;
    mapping(uint256 => uint256) private _productToBatch;
    mapping(uint256 => BatchRelationship) private _relationships;
    
    uint256 private _batchCounter;

    // ============ MODIFIERS ============
    modifier batchExists(uint256 batchId) {
        require(_batches[batchId].batchId != 0, "BatchManagement: Batch not found");
        _;
    }

    modifier validBatchCode(string calldata batchCode) {
        require(bytes(batchCode).length > 0, "BatchManagement: Invalid batch code");
        require(_batchCodeToId[batchCode] == 0, "BatchManagement: Batch code exists");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _batchCounter = 0;
    }

    // ============ BATCH FUNCTIONS ============
    function createBatch(
        string calldata batchCode,
        bytes32 batchDataHash
    ) external validBatchCode(batchCode) returns (uint256 batchId) {
        require(batchDataHash != bytes32(0), "BatchManagement: Batch data hash required");

        _batchCounter++;
        batchId = _batchCounter;

        _batches[batchId] = Batch({
            batchId: batchId,
            batchCode: batchCode,
            productIds: new uint256[](0),
            totalQuantity: 0,
            creator: msg.sender,
            createdAt: block.timestamp,
            isActive: true,
            batchDataHash: batchDataHash
        });

        _batchCodeToId[batchCode] = batchId;

        emit BatchCreated(batchId, batchCode, msg.sender, block.timestamp);
        return batchId;
    }

    function addProductToBatch(
        uint256 batchId,
        uint256 productId,
        uint256 quantity
    ) external batchExists(batchId) {
        require(productId > 0, "BatchManagement: Invalid product ID");
        require(quantity > 0, "BatchManagement: Invalid quantity");
        require(_productToBatch[productId] == 0, "BatchManagement: Product already in batch");

        Batch storage batch = _batches[batchId];
        batch.productIds.push(productId);
        batch.totalQuantity += quantity;
        
        _productToBatch[productId] = batchId;

        emit ProductAddedToBatch(batchId, productId, block.timestamp);
    }

    function splitBatch(
        uint256 batchId,
        uint256[] calldata quantities,
        string[] calldata newBatchCodes
    ) external batchExists(batchId) returns (uint256[] memory newBatchIds) {
        require(quantities.length == newBatchCodes.length, "BatchManagement: Array length mismatch");
        require(quantities.length > 1, "BatchManagement: Need at least 2 splits");

        Batch storage originalBatch = _batches[batchId];
        uint256 totalSplitQuantity = 0;
        
        for (uint256 i = 0; i < quantities.length; i++) {
            totalSplitQuantity += quantities[i];
        }
        require(totalSplitQuantity <= originalBatch.totalQuantity, "BatchManagement: Split exceeds total");

        newBatchIds = new uint256[](quantities.length);
        
        for (uint256 i = 0; i < quantities.length; i++) {
            bytes32 newBatchHash = keccak256(abi.encodePacked(batchId, i, block.timestamp));
            newBatchIds[i] = this.createBatch(newBatchCodes[i], newBatchHash);
            _batches[newBatchIds[i]].totalQuantity = quantities[i];
        }

        _relationships[batchId] = BatchRelationship({
            parentBatchId: batchId,
            childBatchIds: newBatchIds,
            relationshipType: "SPLIT",
            timestamp: block.timestamp
        });

        originalBatch.isActive = false;

        emit BatchSplit(batchId, newBatchIds, quantities, block.timestamp);
        return newBatchIds;
    }

    function mergeBatches(
        uint256[] calldata batchIds,
        string calldata newBatchCode
    ) external validBatchCode(newBatchCode) returns (uint256 newBatchId) {
        require(batchIds.length > 1, "BatchManagement: Need at least 2 batches to merge");

        uint256 totalQuantity = 0;
        for (uint256 i = 0; i < batchIds.length; i++) {
            require(_batches[batchIds[i]].isActive, "BatchManagement: Inactive batch");
            totalQuantity += _batches[batchIds[i]].totalQuantity;
            _batches[batchIds[i]].isActive = false;
        }

        bytes32 mergedHash = keccak256(abi.encodePacked(batchIds, block.timestamp));
        newBatchId = this.createBatch(newBatchCode, mergedHash);
        _batches[newBatchId].totalQuantity = totalQuantity;

        emit BatchMerged(batchIds, newBatchId, block.timestamp);
        return newBatchId;
    }

    // ============ VIEW FUNCTIONS ============
    function getBatch(uint256 batchId) external view batchExists(batchId) returns (Batch memory) {
        return _batches[batchId];
    }

    function getBatchByCode(string calldata batchCode) external view returns (Batch memory) {
        uint256 batchId = _batchCodeToId[batchCode];
        require(batchId != 0, "BatchManagement: Batch code not found");
        return _batches[batchId];
    }

    function getProductBatch(uint256 productId) external view returns (uint256) {
        return _productToBatch[productId];
    }

    function getBatchRelationship(uint256 batchId) external view returns (BatchRelationship memory) {
        return _relationships[batchId];
    }

    function verifyBatchIntegrity(uint256 batchId, bytes32 currentHash) external view returns (bool) {
        return _batches[batchId].batchDataHash == currentHash;
    }
}
