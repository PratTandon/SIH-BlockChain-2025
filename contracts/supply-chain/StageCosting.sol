// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";
import "../libraries/CostCalculator.sol";

/**
 * @title StageCosting
 * @dev Individual stage cost tracking with hash verification
 * @author AgriTrace Team
 */
contract StageCosting is AgriAccessControl {
    using CostCalculator for CostCalculator.CostBreakdown;

    // ============ EVENTS ============
    event StageCostRecorded(
        uint256 indexed productId,
        uint8 indexed stage,
        bytes32 indexed costHash,
        uint256 totalCost,
        address recorder,
        uint256 timestamp
    );

    event CostBreakdownUpdated(
        uint256 indexed productId,
        uint8 indexed stage,
        bytes32 costDataHash,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct StageCost {
        uint256 productId;
        uint8 stage;
        uint256 laborCost;
        uint256 materialCost;
        uint256 equipmentCost;
        uint256 energyCost;
        uint256 overheadCost;
        uint256 totalCost;
        bytes32 costDataHash;
        address recorder;
        uint256 timestamp;
        bool isVerified;
    }

    struct CostSummary {
        uint256 totalLaborCost;
        uint256 totalMaterialCost;
        uint256 totalEquipmentCost;
        uint256 totalEnergyCost;
        uint256 totalOverheadCost;
        uint256 grandTotal;
        uint256 lastUpdated;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => mapping(uint8 => StageCost)) private _stageCosts;
    mapping(uint256 => CostSummary) private _costSummaries;
    mapping(uint256 => uint256) private _totalProductCosts;

    // ============ MODIFIERS ============
    modifier validProductId(uint256 productId) {
        require(productId > 0, "StageCosting: Invalid product ID");
        _;
    }

    modifier validStage(uint8 stage) {
        require(stage <= 7, "StageCosting: Invalid stage");
        _;
    }

    modifier canRecordCost(uint8 stage) {
        require(_canRecordForStage(msg.sender, stage), "StageCosting: Not authorized for this stage");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============ COST FUNCTIONS ============
    function recordStageCost(
        uint256 productId,
        uint8 stage,
        uint256 laborCost,
        uint256 materialCost,
        uint256 equipmentCost,
        uint256 energyCost,
        uint256 overheadCost,
        bytes32 costDataHash
    ) external 
      validProductId(productId) 
      validStage(stage) 
      canRecordCost(stage) {
        
        require(costDataHash != bytes32(0), "StageCosting: Cost data hash required");
        
        uint256 totalCost = laborCost + materialCost + equipmentCost + energyCost + overheadCost;
        require(totalCost > 0, "StageCosting: Total cost must be greater than zero");

        StageCost storage stageCost = _stageCosts[productId][stage];
        
        // Update or create stage cost
        stageCost.productId = productId;
        stageCost.stage = stage;
        stageCost.laborCost = laborCost;
        stageCost.materialCost = materialCost;
        stageCost.equipmentCost = equipmentCost;
        stageCost.energyCost = energyCost;
        stageCost.overheadCost = overheadCost;
        stageCost.totalCost = totalCost;
        stageCost.costDataHash = costDataHash;
        stageCost.recorder = msg.sender;
        stageCost.timestamp = block.timestamp;
        stageCost.isVerified = false;

        // Update summary
        _updateCostSummary(productId);

        emit StageCostRecorded(productId, stage, costDataHash, totalCost, msg.sender, block.timestamp);
    }

    function updateCostBreakdown(
        uint256 productId,
        uint8 stage,
        bytes32 newCostDataHash
    ) external validProductId(productId) validStage(stage) {
        require(newCostDataHash != bytes32(0), "StageCosting: Cost data hash required");
        
        StageCost storage stageCost = _stageCosts[productId][stage];
        require(stageCost.recorder == msg.sender || hasRole(AUDITOR_ROLE, msg.sender), "StageCosting: Not authorized");
        
        stageCost.costDataHash = newCostDataHash;
        stageCost.timestamp = block.timestamp;

        emit CostBreakdownUpdated(productId, stage, newCostDataHash, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    function getStageCost(uint256 productId, uint8 stage) 
        external view 
        validProductId(productId) 
        validStage(stage) 
        returns (StageCost memory) {
        return _stageCosts[productId][stage];
    }

    function getCostSummary(uint256 productId) external view returns (CostSummary memory) {
        return _costSummaries[productId];
    }

    function getTotalProductCost(uint256 productId) external view returns (uint256) {
        return _totalProductCosts[productId];
    }

    function getCostBreakdownPercentages(uint256 productId) external view returns (
        uint256 laborPercent,
        uint256 materialPercent,
        uint256 equipmentPercent,
        uint256 energyPercent,
        uint256 overheadPercent
    ) {
        CostSummary memory summary = _costSummaries[productId];
        if (summary.grandTotal == 0) return (0, 0, 0, 0, 0);

        laborPercent = (summary.totalLaborCost * 10000) / summary.grandTotal;
        materialPercent = (summary.totalMaterialCost * 10000) / summary.grandTotal;
        equipmentPercent = (summary.totalEquipmentCost * 10000) / summary.grandTotal;
        energyPercent = (summary.totalEnergyCost * 10000) / summary.grandTotal;
        overheadPercent = (summary.totalOverheadCost * 10000) / summary.grandTotal;
    }

    function verifyStageCostIntegrity(
        uint256 productId,
        uint8 stage,
        bytes32 currentCostHash
    ) external view returns (bool) {
        return _stageCosts[productId][stage].costDataHash == currentCostHash;
    }

    // ============ ADMIN FUNCTIONS ============
    function verifyStageCost(uint256 productId, uint8 stage) 
        external 
        onlyRole(AUDITOR_ROLE) 
        validProductId(productId) 
        validStage(stage) {
        
        require(_stageCosts[productId][stage].totalCost > 0, "StageCosting: No cost recorded");
        _stageCosts[productId][stage].isVerified = true;
    }

    // ============ INTERNAL FUNCTIONS ============
    function _updateCostSummary(uint256 productId) internal {
        CostSummary storage summary = _costSummaries[productId];
        
        summary.totalLaborCost = 0;
        summary.totalMaterialCost = 0;
        summary.totalEquipmentCost = 0;
        summary.totalEnergyCost = 0;
        summary.totalOverheadCost = 0;
        summary.grandTotal = 0;

        for (uint8 i = 0; i <= 7; i++) {
            StageCost storage stageCost = _stageCosts[productId][i];
            if (stageCost.totalCost > 0) {
                summary.totalLaborCost += stageCost.laborCost;
                summary.totalMaterialCost += stageCost.materialCost;
                summary.totalEquipmentCost += stageCost.equipmentCost;
                summary.totalEnergyCost += stageCost.energyCost;
                summary.totalOverheadCost += stageCost.overheadCost;
                summary.grandTotal += stageCost.totalCost;
            }
        }

        summary.lastUpdated = block.timestamp;
        _totalProductCosts[productId] = summary.grandTotal;
    }

    function _canRecordForStage(address recorder, uint8 stage) internal view returns (bool) {
        if (hasRole(AUDITOR_ROLE, recorder)) return true;
        
        if (stage <= 2 && hasRole(FARMER_ROLE, recorder)) return true;
        if (stage == 3 && hasRole(PROCESSOR_ROLE, recorder)) return true;
        if (stage >= 4 && stage <= 6 && hasRole(DISTRIBUTOR_ROLE, recorder)) return true;
        if (stage == 7 && hasRole(RETAILER_ROLE, recorder)) return true;
        
        return false;
    }
}
