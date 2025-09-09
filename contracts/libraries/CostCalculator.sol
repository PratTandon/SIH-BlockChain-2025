// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title CostCalculator
 * @dev Library for calculating stage-wise costs and generating cost hashes
 * @author AgriTrace Team
 */
library CostCalculator {
    struct CostBreakdown {
        uint256 laborCost;
        uint256 materialCost;
        uint256 equipmentCost;
        uint256 energyCost;
        uint256 overheadCost;
        uint256 transportCost;
        uint256 totalCost;
    }

    struct StageMetrics {
        uint8 stage;
        uint256 quantity;
        uint256 duration; // in hours
        uint256 laborHours;
        uint256 fuelUsed; // in liters
    }

    /**
     * @dev Calculate total cost for a stage
     * @param breakdown Cost breakdown structure
     * @return Total calculated cost
     */
    function calculateTotalCost(CostBreakdown memory breakdown) internal pure returns (uint256) {
        return breakdown.laborCost + 
               breakdown.materialCost + 
               breakdown.equipmentCost + 
               breakdown.energyCost + 
               breakdown.overheadCost + 
               breakdown.transportCost;
    }

    /**
     * @dev Generate hash for cost data
     * @param breakdown Cost breakdown structure
     * @param metrics Stage metrics
     * @param timestamp When cost was recorded
     * @return Cost data hash
     */
    function generateCostHash(
        CostBreakdown memory breakdown,
        StageMetrics memory metrics,
        uint256 timestamp
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            breakdown.laborCost,
            breakdown.materialCost,
            breakdown.equipmentCost,
            breakdown.energyCost,
            breakdown.overheadCost,
            breakdown.transportCost,
            metrics.stage,
            metrics.quantity,
            metrics.duration,
            metrics.laborHours,
            metrics.fuelUsed,
            timestamp
        ));
    }

    /**
     * @dev Calculate cost per unit
     * @param totalCost Total cost for the batch
     * @param quantity Total quantity in kg
     * @return Cost per kg
     */
    function calculateCostPerUnit(uint256 totalCost, uint256 quantity) internal pure returns (uint256) {
        require(quantity > 0, "CostCalculator: Quantity must be greater than zero");
        return totalCost / quantity;
    }

   /**
 * @dev Calculate percentage breakdown
 * @param breakdown Cost breakdown structure
 * @return percentages Array of percentages [labor%, material%, equipment%, energy%, overhead%, transport%]
 */

    function calculatePercentageBreakdown(CostBreakdown memory breakdown) 
        internal 
        pure 
        returns (uint256[6] memory percentages) 
    {
        uint256 total = calculateTotalCost(breakdown);
        require(total > 0, "CostCalculator: Total cost must be greater than zero");
        
        percentages[0] = (breakdown.laborCost * 10000) / total; // Labor %
        percentages[1] = (breakdown.materialCost * 10000) / total; // Material %
        percentages[2] = (breakdown.equipmentCost * 10000) / total; // Equipment %
        percentages[3] = (breakdown.energyCost * 10000) / total; // Energy %
        percentages[4] = (breakdown.overheadCost * 10000) / total; // Overhead %
        percentages[5] = (breakdown.transportCost * 10000) / total; // Transport %
    }

    /**
     * @dev Validate cost breakdown integrity
     * @param breakdown Cost breakdown to validate
     * @return isValid True if cost breakdown is valid
     */
    function validateCostBreakdown(CostBreakdown memory breakdown) internal pure returns (bool isValid) {
        // Check if individual costs are reasonable (not exceeding total)
        uint256 calculatedTotal = calculateTotalCost(breakdown);
        return (calculatedTotal == breakdown.totalCost && calculatedTotal > 0);
    }

    /**
     * @dev Estimate carbon footprint cost
     * @param fuelUsed Fuel consumed in liters
     * @param electricityUsed Electricity in kWh
     * @param carbonPricePerTon Price per ton of CO2
     * @return Estimated carbon cost
     */
    function calculateCarbonCost(
        uint256 fuelUsed,
        uint256 electricityUsed,
        uint256 carbonPricePerTon
    ) internal pure returns (uint256) {
        // Diesel: ~2.7 kg CO2 per liter
        // Electricity: ~0.5 kg CO2 per kWh (grid average)
        uint256 co2FromFuel = fuelUsed * 27; // 2.7 * 10 for decimal precision
        uint256 co2FromElectricity = electricityUsed * 5; // 0.5 * 10 for decimal precision
        uint256 totalCO2 = (co2FromFuel + co2FromElectricity) / 10000; // Convert back to tons
        
        return totalCO2 * carbonPricePerTon;
    }
}
