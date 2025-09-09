// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title QualityMetrics
 * @dev Library for quality assessment calculations and hash generation
 * @author AgriTrace Team
 */
library QualityMetrics {
    struct QualityData {
        uint256 visualScore; // 0-1000
        uint256 sizeScore; // 0-1000
        uint256 colorScore; // 0-1000
        uint256 textureScore; // 0-1000
        uint256 freshnessScore; // 0-1000
        uint256 damageScore; // 0-1000 (1000 = no damage)
    }

    struct WeatherImpact {
        uint256 temperature; // Celsius * 100
        uint256 humidity; // Percentage * 100
        uint256 rainfall; // mm * 100
        uint256 sunlight; // hours * 100
        bool extremeWeatherFlag;
    }

    struct DamageAssessment {
        string damageType;
        uint8 severity; // 1-10 scale
        uint256 affectedArea; // Percentage * 100
        bool isRepairable;
    }

    /**
     * @dev Calculate composite quality score
     * @param quality Quality data structure
     * @return Weighted average quality score (0-1000)
     */
    function calculateCompositeScore(QualityData memory quality) internal pure returns (uint256) {
        // Weighted scoring: visual(25%), size(15%), color(15%), texture(15%), freshness(20%), damage(10%)
        uint256 weightedScore = (
            quality.visualScore * 25 +
            quality.sizeScore * 15 +
            quality.colorScore * 15 +
            quality.textureScore * 15 +
            quality.freshnessScore * 20 +
            quality.damageScore * 10
        ) / 100;
        
        return weightedScore > 1000 ? 1000 : weightedScore;
    }

    /**
     * @dev Adjust quality score based on weather impact
     * @param baseScore Base quality score
     * @param weather Weather impact data
     * @return Adjusted quality score
     */
    function adjustForWeatherImpact(uint256 baseScore, WeatherImpact memory weather) 
        internal 
        pure 
        returns (uint256) 
    {
        if (weather.extremeWeatherFlag) {
            return baseScore * 80 / 100; // 20% reduction for extreme weather
        }

        uint256 adjustment = 100; // Start with 100% (no adjustment)
        
        // Temperature impact (optimal range: 15-25°C)
        if (weather.temperature < 1500 || weather.temperature > 2500) {
            adjustment -= 5; // 5% reduction
        }
        
        // Humidity impact (optimal range: 60-80%)
        if (weather.humidity < 6000 || weather.humidity > 8000) {
            adjustment -= 3; // 3% reduction
        }
        
        // Rainfall impact (excessive rainfall reduces quality)
        if (weather.rainfall > 5000) { // > 50mm
            adjustment -= 7; // 7% reduction
        }
        
        return baseScore * adjustment / 100;
    }

    /**
     * @dev Calculate damage impact on quality
     * @param baseScore Base quality score
     * @param damage Damage assessment data
     * @return Quality score after damage impact
     */
    function calculateDamageImpact(uint256 baseScore, DamageAssessment memory damage) 
        internal 
        pure 
        returns (uint256) 
    {
        if (damage.severity == 0) {
            return baseScore; // No damage
        }
        
        // Calculate reduction based on severity and affected area
        uint256 reduction = (damage.severity * damage.affectedArea) / 100;
        
        // Cap maximum reduction at 50%
        if (reduction > 5000) {
            reduction = 5000;
        }
        
        uint256 adjustedScore = baseScore * (10000 - reduction) / 10000;
        return adjustedScore;
    }

    /**
     * @dev Generate quality assessment hash
     * @param quality Quality data
     * @param weather Weather impact
     * @param damage Damage assessment
     * @param timestamp Assessment timestamp
     * @param assessor Address of assessor
     * @return Quality data hash
     */
    function generateQualityHash(
        QualityData memory quality,
        WeatherImpact memory weather,
        DamageAssessment memory damage,
        uint256 timestamp,
        address assessor
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            quality.visualScore,
            quality.sizeScore,
            quality.colorScore,
            quality.textureScore,
            quality.freshnessScore,
            quality.damageScore,
            weather.temperature,
            weather.humidity,
            weather.rainfall,
            weather.sunlight,
            weather.extremeWeatherFlag,
            damage.damageType,
            damage.severity,
            damage.affectedArea,
            damage.isRepairable,
            timestamp,
            assessor
        ));
    }

    /**
     * @dev Validate quality scores
     * @param quality Quality data to validate
     * @return isValid True if all scores are within valid range
     */
    function validateQualityScores(QualityData memory quality) internal pure returns (bool isValid) {
        return (
            quality.visualScore <= 1000 &&
            quality.sizeScore <= 1000 &&
            quality.colorScore <= 1000 &&
            quality.textureScore <= 1000 &&
            quality.freshnessScore <= 1000 &&
            quality.damageScore <= 1000
        );
    }

    /**
     * @dev Calculate confidence level based on assessment completeness
     * @param quality Quality data
     * @param hasPhoto Whether photo evidence exists
     * @param hasWeatherData Whether weather data is available
     * @return confidence Confidence level (0-100)
     */
    function calculateConfidenceLevel(
        QualityData memory quality,
        bool hasPhoto,
        bool hasWeatherData
    ) internal pure returns (uint256 confidence) {
        confidence = 60; // Base confidence
        
        // Add confidence for complete quality data
        if (validateQualityScores(quality)) {
            confidence += 20;
        }
        
        // Add confidence for photo evidence
        if (hasPhoto) {
            confidence += 15;
        }
        
        // Add confidence for weather data
        if (hasWeatherData) {
            confidence += 5;
        }
        
        return confidence > 100 ? 100 : confidence;
    }
}
