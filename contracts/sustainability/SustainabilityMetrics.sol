// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";

/**
 * @title SustainabilityMetrics
 * @dev Environmental impact tracking for agricultural products
 * @author AgriTrace Team
 */
contract SustainabilityMetrics is AgriAccessControl {

    // ============ EVENTS ============
    event SustainabilityScoreRecorded(
        uint256 indexed productId,
        uint256 score,
        bytes32 indexed metricsHash,
        uint256 timestamp
    );

    event EnvironmentalImpactRecorded(
        uint256 indexed productId,
        bytes32 indexed impactHash,
        string impactType,
        uint256 timestamp
    );

    event SustainabilityCertificationAdded(
        uint256 indexed productId,
        string certificationType,
        bytes32 certificationHash,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct SustainabilityScore {
        uint256 productId;
        uint256 overallScore; // 0-1000
        uint256 carbonFootprint; // kg CO2e
        uint256 waterUsage; // liters
        uint256 landUsage; // square meters
        uint256 energyUsage; // kWh
        bytes32 metricsDataHash;
        uint256 recordedAt;
        address recorder;
        bool isVerified;
    }

    struct EnvironmentalImpact {
        string impactType; // "CARBON", "WATER", "BIODIVERSITY", etc.
        uint256 value;
        string unit;
        bytes32 evidenceHash;
        bytes32 calculationMethodHash;
        uint256 timestamp;
        bool isPositive; // true for positive impact, false for negative
    }

    struct SustainabilityCertification {
        string certificationType;
        bytes32 certificationHash;
        address issuer;
        uint256 issueDate;
        uint256 expiryDate;
        bool isValid;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => SustainabilityScore) private _sustainabilityScores;
    mapping(uint256 => EnvironmentalImpact[]) private _environmentalImpacts;
    mapping(uint256 => SustainabilityCertification[]) private _certifications;
    mapping(uint256 => uint256) private _latestScores;
    
    // Score calculation weights (in basis points)
    uint256 public carbonWeight = 3000; // 30%
    uint256 public waterWeight = 2500;  // 25%
    uint256 public landWeight = 2000;   // 20%
    uint256 public energyWeight = 1500; // 15%
    uint256 public practicesWeight = 1000; // 10%

    // ============ MODIFIERS ============
    modifier validProductId(uint256 productId) {
        require(productId > 0, "SustainabilityMetrics: Invalid product ID");
        _;
    }

    modifier validScore(uint256 score) {
        require(score <= 1000, "SustainabilityMetrics: Score must be <= 1000");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============ SUSTAINABILITY FUNCTIONS ============
    function recordSustainabilityScore(
        uint256 productId,
        uint256 carbonFootprint,
        uint256 waterUsage,
        uint256 landUsage,
        uint256 energyUsage,
        bytes32 metricsDataHash
    ) external validProductId(productId) returns (uint256 overallScore) {
        require(metricsDataHash != bytes32(0), "SustainabilityMetrics: Metrics data hash required");
        require(
            hasRole(FARMER_ROLE, msg.sender) || 
            hasRole(AUDITOR_ROLE, msg.sender),
            "SustainabilityMetrics: Not authorized"
        );

        overallScore = _calculateOverallScore(carbonFootprint, waterUsage, landUsage, energyUsage);

        _sustainabilityScores[productId] = SustainabilityScore({
            productId: productId,
            overallScore: overallScore,
            carbonFootprint: carbonFootprint,
            waterUsage: waterUsage,
            landUsage: landUsage,
            energyUsage: energyUsage,
            metricsDataHash: metricsDataHash,
            recordedAt: block.timestamp,
            recorder: msg.sender,
            isVerified: false
        });

        _latestScores[productId] = overallScore;

        emit SustainabilityScoreRecorded(productId, overallScore, metricsDataHash, block.timestamp);
        return overallScore;
    }

    function recordEnvironmentalImpact(
        uint256 productId,
        string calldata impactType,
        uint256 value,
        string calldata unit,
        bytes32 evidenceHash,
        bytes32 calculationMethodHash,
        bool isPositive
    ) external validProductId(productId) {
        require(bytes(impactType).length > 0, "SustainabilityMetrics: Impact type required");
        require(evidenceHash != bytes32(0), "SustainabilityMetrics: Evidence hash required");

        EnvironmentalImpact memory impact = EnvironmentalImpact({
            impactType: impactType,
            value: value,
            unit: unit,
            evidenceHash: evidenceHash,
            calculationMethodHash: calculationMethodHash,
            timestamp: block.timestamp,
            isPositive: isPositive
        });

        _environmentalImpacts[productId].push(impact);

        emit EnvironmentalImpactRecorded(productId, evidenceHash, impactType, block.timestamp);
    }

    function addSustainabilityCertification(
        uint256 productId,
        string calldata certificationType,
        bytes32 certificationHash,
        uint256 expiryDate
    ) external onlyRole(AUDITOR_ROLE) validProductId(productId) {
        require(bytes(certificationType).length > 0, "SustainabilityMetrics: Certification type required");
        require(certificationHash != bytes32(0), "SustainabilityMetrics: Certification hash required");
        require(expiryDate > block.timestamp, "SustainabilityMetrics: Invalid expiry date");

        SustainabilityCertification memory cert = SustainabilityCertification({
            certificationType: certificationType,
            certificationHash: certificationHash,
            issuer: msg.sender,
            issueDate: block.timestamp,
            expiryDate: expiryDate,
            isValid: true
        });

        _certifications[productId].push(cert);

        emit SustainabilityCertificationAdded(productId, certificationType, certificationHash, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    function getSustainabilityScore(uint256 productId) external view returns (SustainabilityScore memory) {
        return _sustainabilityScores[productId];
    }

    function getEnvironmentalImpacts(uint256 productId) external view returns (EnvironmentalImpact[] memory) {
        return _environmentalImpacts[productId];
    }

    function getCertifications(uint256 productId) external view returns (SustainabilityCertification[] memory) {
        return _certifications[productId];
    }

    function getLatestScore(uint256 productId) external view returns (uint256) {
        return _latestScores[productId];
    }

    function verifySustainabilityIntegrity(
        uint256 productId,
        bytes32 currentMetricsHash
    ) external view returns (bool) {
        return _sustainabilityScores[productId].metricsDataHash == currentMetricsHash;
    }

    function calculateCarbonEfficiency(uint256 productId, uint256 yield) external view returns (uint256) {
        SustainabilityScore memory score = _sustainabilityScores[productId];
        if (yield == 0) return 0;
        return (score.carbonFootprint * 1000) / yield; // kg CO2e per kg yield
    }

    function calculateWaterEfficiency(uint256 productId, uint256 yield) external view returns (uint256) {
        SustainabilityScore memory score = _sustainabilityScores[productId];
        if (yield == 0) return 0;
        return (score.waterUsage * 1000) / yield; // liters per kg yield
    }

    // ============ ADMIN FUNCTIONS ============
    function verifySustainabilityScore(uint256 productId) external onlyRole(AUDITOR_ROLE) {
        require(_sustainabilityScores[productId].productId != 0, "SustainabilityMetrics: Score not found");
        _sustainabilityScores[productId].isVerified = true;
    }

    function updateScoreWeights(
        uint256 _carbonWeight,
        uint256 _waterWeight,
        uint256 _landWeight,
        uint256 _energyWeight,
        uint256 _practicesWeight
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            _carbonWeight + _waterWeight + _landWeight + _energyWeight + _practicesWeight == 10000,
            "SustainabilityMetrics: Weights must sum to 10000"
        );

        carbonWeight = _carbonWeight;
        waterWeight = _waterWeight;
        landWeight = _landWeight;
        energyWeight = _energyWeight;
        practicesWeight = _practicesWeight;
    }

    function invalidateCertification(uint256 productId, uint256 certIndex) external onlyRole(AUDITOR_ROLE) {
        require(certIndex < _certifications[productId].length, "SustainabilityMetrics: Invalid cert index");
        _certifications[productId][certIndex].isValid = false;
    }

    // ============ INTERNAL FUNCTIONS ============
    function _calculateOverallScore(
        uint256 carbonFootprint,
        uint256 waterUsage,
        uint256 landUsage,
        uint256 energyUsage
    ) internal view returns (uint256) {
        // Normalize values and calculate weighted score
        // This is a simplified calculation - in production, use industry benchmarks
        
        uint256 carbonScore = carbonFootprint > 0 ? (1000 * 1000) / carbonFootprint : 1000;
        uint256 waterScore = waterUsage > 0 ? (1000 * 1000) / waterUsage : 1000;
        uint256 landScore = landUsage > 0 ? (1000 * 1000) / landUsage : 1000;
        uint256 energyScore = energyUsage > 0 ? (1000 * 1000) / energyUsage : 1000;
        
        // Cap scores at 1000
        if (carbonScore > 1000) carbonScore = 1000;
        if (waterScore > 1000) waterScore = 1000;
        if (landScore > 1000) landScore = 1000;
        if (energyScore > 1000) energyScore = 1000;
        
        uint256 weightedScore = (
            carbonScore * carbonWeight +
            waterScore * waterWeight +
            landScore * landWeight +
            energyScore * energyWeight +
            800 * practicesWeight // Base practices score
        ) / 10000;
        
        return weightedScore > 1000 ? 1000 : weightedScore;
    }
}
