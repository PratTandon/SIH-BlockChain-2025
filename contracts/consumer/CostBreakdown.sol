// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";

/**
 * @title CostBreakdown
 * @dev Display cost breakdown to consumers
 * @author AgriTrace Team
 */
contract CostBreakdown is AgriAccessControl {

    // ============ EVENTS ============
    event CostBreakdownPublished(
        uint256 indexed productId,
        bytes32 indexed costDataHash,
        uint256 totalCost,
        uint256 timestamp
    );

    event ConsumerPriceSet(
        uint256 indexed productId,
        uint256 consumerPrice,
        uint256 marginPercentage,
        uint256 timestamp
    );

    event CostTransparencyUpdated(
        uint256 indexed productId,
        bool isTransparent,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct CostBreakdown {
        uint256 productId;
        uint256 farmingCost;
        uint256 processingCost;
        uint256 distributionCost;
        uint256 retailCost;
        uint256 totalSupplyChainCost;
        uint256 consumerPrice;
        uint256 margin;
        bytes32 costDataHash;
        uint256 lastUpdated;
        bool isPublic;
        bool isVerified;
    }

    struct CostComponent {
        string componentName;
        uint256 amount;
        uint256 percentage;
        string description;
        bool isVisible;
    }

    struct PriceHistory {
        uint256 timestamp;
        uint256 price;
        uint256 totalCost;
        string priceChangeReason;
    }

    struct MarginAnalysis {
        uint256 farmerMargin;
        uint256 processorMargin;
        uint256 distributorMargin;
        uint256 retailerMargin;
        uint256 totalMargin;
        uint256 valueAddPercentage;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => CostBreakdown) private _costBreakdowns;
    mapping(uint256 => CostComponent[]) private _costComponents;
    mapping(uint256 => PriceHistory[]) private _priceHistory;
    mapping(uint256 => MarginAnalysis) private _marginAnalysis;
    mapping(uint256 => bool) private _transparencyEnabled;
    
    // Contract references
    address public stageCostingContract;
    address public stakeholderContract;
    
    // Cost parameters
    uint256 public constant MAX_MARGIN_PERCENTAGE = 5000; // 50%
    uint256 public constant MIN_TRANSPARENCY_THRESHOLD = 1000; // Minimum cost for transparency

    // ============ MODIFIERS ============
    modifier validProductId(uint256 productId) {
        require(productId > 0, "CostBreakdown: Invalid product ID");
        _;
    }

    modifier costBreakdownExists(uint256 productId) {
        require(_costBreakdowns[productId].productId != 0, "CostBreakdown: Cost breakdown not found");
        _;
    }

    modifier onlyAuthorizedPublisher() {
        require(
            hasRole(RETAILER_ROLE, msg.sender) ||
            hasRole(AUDITOR_ROLE, msg.sender) ||
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "CostBreakdown: Not authorized to publish costs"
        );
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============ SETUP FUNCTIONS ============
    function setStageCostingContract(address _stageCostingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stageCostingContract != address(0), "CostBreakdown: Invalid stage costing contract");
        stageCostingContract = _stageCostingContract;
    }

    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakeholderContract = _stakeholderContract;
    }

    // ============ COST BREAKDOWN FUNCTIONS ============
    /**
     * @notice Publish cost breakdown for consumers
     */
    function publishCostBreakdown(
        uint256 productId,
        uint256 farmingCost,
        uint256 processingCost,
        uint256 distributionCost,
        uint256 retailCost,
        uint256 consumerPrice,
        bytes32 costDataHash,
        bool isPublic
    ) external validProductId(productId) onlyAuthorizedPublisher {
        require(costDataHash != bytes32(0), "CostBreakdown: Cost data hash required");
        require(consumerPrice > 0, "CostBreakdown: Consumer price must be greater than zero");

        uint256 totalSupplyChainCost = farmingCost + processingCost + distributionCost + retailCost;
        require(consumerPrice >= totalSupplyChainCost, "CostBreakdown: Consumer price below total cost");

        uint256 margin = consumerPrice - totalSupplyChainCost;
        uint256 marginPercentage = totalSupplyChainCost > 0 ? (margin * 10000) / totalSupplyChainCost : 0;

        _costBreakdowns[productId] = CostBreakdown({
            productId: productId,
            farmingCost: farmingCost,
            processingCost: processingCost,
            distributionCost: distributionCost,
            retailCost: retailCost,
            totalSupplyChainCost: totalSupplyChainCost,
            consumerPrice: consumerPrice,
            margin: margin,
            costDataHash: costDataHash,
            lastUpdated: block.timestamp,
            isPublic: isPublic,
            isVerified: false
        });

        // Record price history
        _priceHistory[productId].push(PriceHistory({
            timestamp: block.timestamp,
            price: consumerPrice,
            totalCost: totalSupplyChainCost,
            priceChangeReason: "Initial price setting"
        }));

        // Calculate margin analysis
        _calculateMarginAnalysis(productId);

        emit CostBreakdownPublished(productId, costDataHash, totalSupplyChainCost, block.timestamp);
        emit ConsumerPriceSet(productId, consumerPrice, marginPercentage, block.timestamp);
    }

    /**
     * @notice Add cost component details
     */
    function addCostComponent(
        uint256 productId,
        string calldata componentName,
        uint256 amount,
        string calldata description,
        bool isVisible
    ) external validProductId(productId) onlyAuthorizedPublisher {
        require(bytes(componentName).length > 0, "CostBreakdown: Component name required");
        require(amount > 0, "CostBreakdown: Component amount must be greater than zero");

        CostBreakdown memory breakdown = _costBreakdowns[productId];
        uint256 percentage = breakdown.totalSupplyChainCost > 0 ? 
            (amount * 10000) / breakdown.totalSupplyChainCost : 0;

        CostComponent memory component = CostComponent({
            componentName: componentName,
            amount: amount,
            percentage: percentage,
            description: description,
            isVisible: isVisible
        });

        _costComponents[productId].push(component);
    }

    /**
     * @notice Update consumer price
     */
    function updateConsumerPrice(
        uint256 productId,
        uint256 newPrice,
        string calldata reason
    ) external validProductId(productId) costBreakdownExists(productId) onlyAuthorizedPublisher {
        require(newPrice > 0, "CostBreakdown: Price must be greater than zero");
        require(bytes(reason).length > 0, "CostBreakdown: Reason required");

        CostBreakdown storage breakdown = _costBreakdowns[productId];
        require(newPrice >= breakdown.totalSupplyChainCost, "CostBreakdown: Price below total cost");

        uint256 oldPrice = breakdown.consumerPrice;
        breakdown.consumerPrice = newPrice;
        breakdown.margin = newPrice - breakdown.totalSupplyChainCost;
        breakdown.lastUpdated = block.timestamp;

        // Record price history
        _priceHistory[productId].push(PriceHistory({
            timestamp: block.timestamp,
            price: newPrice,
            totalCost: breakdown.totalSupplyChainCost,
            priceChangeReason: reason
        }));

        // Recalculate margin analysis
        _calculateMarginAnalysis(productId);

        uint256 marginPercentage = breakdown.totalSupplyChainCost > 0 ? 
            (breakdown.margin * 10000) / breakdown.totalSupplyChainCost : 0;

        emit ConsumerPriceSet(productId, newPrice, marginPercentage, block.timestamp);
    }

    /**
     * @notice Toggle cost transparency
     */
    function toggleTransparency(uint256 productId, bool isTransparent) 
        external 
        validProductId(productId) 
        costBreakdownExists(productId) 
        onlyAuthorizedPublisher {
        
        _transparencyEnabled[productId] = isTransparent;
        _costBreakdowns[productId].isPublic = isTransparent;

        emit CostTransparencyUpdated(productId, isTransparent, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get public cost breakdown
     */
    function getPublicCostBreakdown(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (CostBreakdown memory) {
        
        CostBreakdown memory breakdown = _costBreakdowns[productId];
        require(breakdown.isPublic, "CostBreakdown: Cost breakdown not public");
        
        return breakdown;
    }

    /**
     * @notice Get detailed cost breakdown (authorized users)
     */
    function getDetailedCostBreakdown(uint256 productId) 
        external view 
        validProductId(productId) 
        costBreakdownExists(productId) 
        returns (CostBreakdown memory) {
        
        require(
            hasRole(AUDITOR_ROLE, msg.sender) ||
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
            _costBreakdowns[productId].isPublic,
            "CostBreakdown: Not authorized for detailed breakdown"
        );

        return _costBreakdowns[productId];
    }

    /**
     * @notice Get cost components
     */
    function getCostComponents(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (CostComponent[] memory) {
        
        CostComponent[] memory allComponents = _costComponents[productId];
        
        // If not authorized, filter only visible components
        if (!hasRole(AUDITOR_ROLE, msg.sender) && !_costBreakdowns[productId].isPublic) {
            CostComponent[] memory temp = new CostComponent[](allComponents.length);
            uint256 count = 0;
            
            for (uint256 i = 0; i < allComponents.length; i++) {
                if (allComponents[i].isVisible) {
                    temp[count] = allComponents[i];
                    count++;
                }
            }
            
            CostComponent[] memory result = new CostComponent[](count);
            for (uint256 i = 0; i < count; i++) {
                result[i] = temp[i];
            }
            
            return result;
        }
        
        return allComponents;
    }

    /**
     * @notice Get price history
     */
    function getPriceHistory(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (PriceHistory[] memory) {
        return _priceHistory[productId];
    }

    /**
     * @notice Get margin analysis
     */
    function getMarginAnalysis(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (MarginAnalysis memory) {
        return _marginAnalysis[productId];
    }

    /**
     * @notice Calculate price transparency score
     */
    function getPriceTransparencyScore(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (uint256 score) {
        
        CostBreakdown memory breakdown = _costBreakdowns[productId];
        if (!breakdown.isPublic) return 0;
        
        score = 20; // Base score for public breakdown
        
        // Add points for detailed components
        CostComponent[] memory components = _costComponents[productId];
        uint256 visibleComponents = 0;
        for (uint256 i = 0; i < components.length; i++) {
            if (components[i].isVisible) visibleComponents++;
        }
        
        score += (visibleComponents * 10); // 10 points per visible component
        
        // Add points for margin reasonableness
        uint256 marginPercentage = breakdown.totalSupplyChainCost > 0 ? 
            (breakdown.margin * 10000) / breakdown.totalSupplyChainCost : 0;
        
        if (marginPercentage <= 2000) score += 30; // 20% or less margin
        else if (marginPercentage <= 3000) score += 20; // 30% or less margin
        else if (marginPercentage <= 4000) score += 10; // 40% or less margin
        
        // Cap at 100
        return score > 100 ? 100 : score;
    }

    /**
     * @notice Verify cost breakdown integrity
     */
    function verifyCostIntegrity(
        uint256 productId,
        bytes32 currentCostDataHash
    ) external view costBreakdownExists(productId) returns (bool) {
        return _costBreakdowns[productId].costDataHash == currentCostDataHash;
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Verify cost breakdown
     */
    function verifyCostBreakdown(uint256 productId) 
        external 
        onlyRole(AUDITOR_ROLE) 
        costBreakdownExists(productId) {
        
        _costBreakdowns[productId].isVerified = true;
    }

    /**
     * @notice Set component visibility
     */
    function setComponentVisibility(
        uint256 productId,
        uint256 componentIndex,
        bool isVisible
    ) external onlyRole(AUDITOR_ROLE) validProductId(productId) {
        require(componentIndex < _costComponents[productId].length, "CostBreakdown: Invalid component index");
        _costComponents[productId][componentIndex].isVisible = isVisible;
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Calculate margin analysis
     */
    function _calculateMarginAnalysis(uint256 productId) internal {
        CostBreakdown memory breakdown = _costBreakdowns[productId];
        
        if (breakdown.totalSupplyChainCost == 0) return;
        
        uint256 totalCost = breakdown.totalSupplyChainCost;
        
        _marginAnalysis[productId] = MarginAnalysis({
            farmerMargin: (breakdown.farmingCost * 10000) / totalCost,
            processorMargin: (breakdown.processingCost * 10000) / totalCost,
            distributorMargin: (breakdown.distributionCost * 10000) / totalCost,
            retailerMargin: (breakdown.retailCost * 10000) / totalCost,
            totalMargin: (breakdown.margin * 10000) / totalCost,
            valueAddPercentage: breakdown.consumerPrice > 0 ? 
                ((breakdown.consumerPrice - breakdown.farmingCost) * 10000) / breakdown.consumerPrice : 0
        });
    }
}