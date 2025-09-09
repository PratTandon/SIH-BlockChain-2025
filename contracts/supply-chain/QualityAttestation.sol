// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IMLOracle.sol";
import "../interfaces/IStakeholder.sol";
import "../libraries/QualityMetrics.sol";
import "../libraries/DateTimeLib.sol";
import "../core/AgriAccessControl.sol";

/**
 * @title QualityAttestation
 * @dev AI quality validation with photo analysis integration
 * @author AgriTrace Team
 */
contract QualityAttestation is AgriAccessControl {
    using QualityMetrics for QualityMetrics.QualityData;
    using DateTimeLib for uint256;

    // ============ EVENTS ============
    event QualityAssessmentSubmitted(
        uint256 indexed productId,
        uint8 indexed stage,
        bytes32 indexed assessmentHash,
        uint256 score,
        uint256 confidence,
        address assessor,
        uint256 timestamp
    );

    event PhotoEvidenceSubmitted(
        uint256 indexed productId,
        uint8 indexed stage,
        bytes32 indexed photoHash,
        address submitter,
        uint256 timestamp
    );

    event AIAnalysisCompleted(
        uint256 indexed productId,
        bytes32 indexed analysisId,
        uint256 qualityScore,
        uint256 confidence,
        string modelVersion,
        uint256 timestamp
    );

    event QualityThresholdAlert(
        uint256 indexed productId,
        uint8 stage,
        uint256 score,
        uint256 threshold,
        string alertType,
        uint256 timestamp
    );

    event WeatherImpactRecorded(
        uint256 indexed productId,
        bytes32 indexed weatherHash,
        int256 impactScore,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct QualityAssessment {
        bytes32 assessmentId;
        uint256 productId;
        uint8 stage;
        bytes32 assessmentDataHash;
        bytes32 photoHash;
        bytes32 weatherDataHash;
        uint256 qualityScore; // 0-1000
        uint256 confidence; // 0-100
        address assessor;
        uint256 timestamp;
        bool isAIValidated;
        bool isVerified;
        string modelVersion;
    }

    struct PhotoEvidence {
        bytes32 photoHash;
        uint256 productId;
        uint8 stage;
        address submitter;
        uint256 timestamp;
        bytes32 analysisResultHash;
        bool isAnalyzed;
        bool isVerified;
    }

    struct QualityThreshold {
        uint8 stage;
        uint256 minScore;
        uint256 warningScore;
        bool isActive;
    }

    struct WeatherImpact {
        bytes32 weatherDataHash;
        int256 temperatureImpact;
        int256 humidityImpact;
        int256 rainfallImpact;
        int256 overallImpact;
        uint256 timestamp;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => mapping(uint8 => QualityAssessment[])) private _qualityAssessments;
    mapping(uint256 => mapping(uint8 => PhotoEvidence[])) private _photoEvidence;
    mapping(uint256 => WeatherImpact[]) private _weatherImpacts;
    mapping(bytes32 => QualityAssessment) private _assessmentById;
    mapping(uint8 => QualityThreshold) private _qualityThresholds;
    mapping(uint256 => uint256) private _latestQualityScores;
    
    // Contract references
    IMLOracle public mlOracleContract;
    IStakeholder public stakeholderContract;
    
    // Assessment parameters
    uint256 public constant MIN_CONFIDENCE_THRESHOLD = 70;
    uint256 public constant AI_VALIDATION_TIMEOUT = 24 hours;
    uint256 public constant PHOTO_ANALYSIS_TIMEOUT = 6 hours;

    // ============ MODIFIERS ============
    modifier validProductId(uint256 productId) {
        require(productId > 0, "QualityAttestation: Invalid product ID");
        _;
    }

    modifier validStage(uint8 stage) {
        require(stage <= 7, "QualityAttestation: Invalid stage");
        _;
    }

    modifier validScore(uint256 score) {
        require(score <= 1000, "QualityAttestation: Score must be <= 1000");
        _;
    }

    modifier validConfidence(uint256 confidence) {
        require(confidence <= 100, "QualityAttestation: Confidence must be <= 100");
        _;
    }

    modifier onlyVerifiedAssessor() {
        require(
            hasRole(AUDITOR_ROLE, msg.sender) ||
            hasRole(FARMER_ROLE, msg.sender) ||
            hasRole(PROCESSOR_ROLE, msg.sender) ||
            address(stakeholderContract) != address(0) && stakeholderContract.isVerifiedAndIntact(msg.sender),
            "QualityAttestation: Not authorized assessor"
        );
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        // Initialize default quality thresholds
        _qualityThresholds[0] = QualityThreshold(0, 600, 700, true);  // PLANTED
        _qualityThresholds[1] = QualityThreshold(1, 650, 750, true);  // GROWING
        _qualityThresholds[2] = QualityThreshold(2, 700, 800, true);  // HARVESTED
        _qualityThresholds[3] = QualityThreshold(3, 650, 750, true);  // PROCESSED
        _qualityThresholds[4] = QualityThreshold(4, 700, 800, true);  // PACKAGED
        _qualityThresholds[5] = QualityThreshold(5, 650, 750, true);  // SHIPPED
        _qualityThresholds[6] = QualityThreshold(6, 650, 750, true);  // DELIVERED
        _qualityThresholds[7] = QualityThreshold(7, 700, 800, true);  // SOLD
    }

    // ============ SETUP FUNCTIONS ============
    function setMLOracleContract(address _mlOracleContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_mlOracleContract != address(0), "QualityAttestation: Invalid ML oracle contract");
        mlOracleContract = IMLOracle(_mlOracleContract);
    }

    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakeholderContract != address(0), "QualityAttestation: Invalid stakeholder contract");
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    // ============ QUALITY ASSESSMENT ============
    /**
     * @notice Submit photo evidence for quality assessment
     */
    function submitPhotoEvidence(
        uint256 productId,
        uint8 stage,
        bytes32 photoHash
    ) external 
      validProductId(productId) 
      validStage(stage) 
      onlyVerifiedAssessor {
        
        require(photoHash != bytes32(0), "QualityAttestation: Photo hash required");

        PhotoEvidence memory evidence = PhotoEvidence({
            photoHash: photoHash,
            productId: productId,
            stage: stage,
            submitter: msg.sender,
            timestamp: block.timestamp,
            analysisResultHash: bytes32(0),
            isAnalyzed: false,
            isVerified: false
        });

        _photoEvidence[productId][stage].push(evidence);

        // Trigger AI analysis if ML Oracle is available
        if (address(mlOracleContract) != address(0)) {
            mlOracleContract.submitPhotoHash(productId, stage, photoHash, "quality_assessment", 0);
        }

        emit PhotoEvidenceSubmitted(productId, stage, photoHash, msg.sender, block.timestamp);
    }

    /**
     * @notice Submit quality assessment
     */
    function submitQualityAssessment(
        uint256 productId,
        uint8 stage,
        bytes32 assessmentDataHash,
        uint256 qualityScore,
        uint256 confidence,
        bytes32 photoHash,
        bytes32 weatherDataHash
    ) external 
      validProductId(productId) 
      validStage(stage) 
      validScore(qualityScore) 
      validConfidence(confidence) 
      onlyVerifiedAssessor {
        
        require(assessmentDataHash != bytes32(0), "QualityAttestation: Assessment data hash required");
        require(confidence >= MIN_CONFIDENCE_THRESHOLD, "QualityAttestation: Confidence too low");

        bytes32 assessmentId = keccak256(abi.encodePacked(
            productId,
            stage,
            msg.sender,
            block.timestamp,
            assessmentDataHash
        ));

        QualityAssessment memory assessment = QualityAssessment({
            assessmentId: assessmentId,
            productId: productId,
            stage: stage,
            assessmentDataHash: assessmentDataHash,
            photoHash: photoHash,
            weatherDataHash: weatherDataHash,
            qualityScore: qualityScore,
            confidence: confidence,
            assessor: msg.sender,
            timestamp: block.timestamp,
            isAIValidated: false,
            isVerified: false,
            modelVersion: ""
        });

        _qualityAssessments[productId][stage].push(assessment);
        _assessmentById[assessmentId] = assessment;
        _latestQualityScores[productId] = qualityScore;

        // Check quality thresholds
        _checkQualityThresholds(productId, stage, qualityScore);

        // Request AI validation if ML Oracle is available
        if (address(mlOracleContract) != address(0)) {
            mlOracleContract.updateQualityScoreHash(
                productId,
                assessmentDataHash,
                qualityScore,
                confidence,
                photoHash,
                weatherDataHash
            );
        }

        emit QualityAssessmentSubmitted(productId, stage, assessmentDataHash, qualityScore, confidence, msg.sender, block.timestamp);
    }

    /**
     * @notice Process AI analysis result
     */
    function processAIAnalysisResult(
        uint256 productId,
        bytes32 analysisId,
        uint256 aiQualityScore,
        uint256 aiConfidence,
        string calldata modelVersion,
        bytes32 resultHash
    ) external onlyRole(ML_ORACLE_ROLE) 
      validProductId(productId) 
      validScore(aiQualityScore) 
      validConfidence(aiConfidence) {
        
        require(analysisId != bytes32(0), "QualityAttestation: Analysis ID required");
        require(resultHash != bytes32(0), "QualityAttestation: Result hash required");
        require(bytes(modelVersion).length > 0, "QualityAttestation: Model version required");

        // Find and update corresponding assessment
        _updateAssessmentWithAIResult(productId, analysisId, aiQualityScore, aiConfidence, modelVersion);

        emit AIAnalysisCompleted(productId, analysisId, aiQualityScore, aiConfidence, modelVersion, block.timestamp);
    }

    /**
     * @notice Record weather impact on quality
     */
    function recordWeatherImpact(
        uint256 productId,
        bytes32 weatherDataHash,
        int256 temperatureImpact,
        int256 humidityImpact,
        int256 rainfallImpact
    ) external onlyRole(ML_ORACLE_ROLE) validProductId(productId) {
        require(weatherDataHash != bytes32(0), "QualityAttestation: Weather data hash required");

        int256 overallImpact = (temperatureImpact + humidityImpact + rainfallImpact) / 3;

        WeatherImpact memory impact = WeatherImpact({
            weatherDataHash: weatherDataHash,
            temperatureImpact: temperatureImpact,
            humidityImpact: humidityImpact,
            rainfallImpact: rainfallImpact,
            overallImpact: overallImpact,
            timestamp: block.timestamp
        });

        _weatherImpacts[productId].push(impact);

        // Adjust latest quality score based on weather impact
        if (_latestQualityScores[productId] > 0) {
            uint256 adjustedScore = _adjustScoreForWeather(_latestQualityScores[productId], overallImpact);
            _latestQualityScores[productId] = adjustedScore;
        }

        emit WeatherImpactRecorded(productId, weatherDataHash, overallImpact, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get quality assessments for product and stage
     */
    function getQualityAssessments(uint256 productId, uint8 stage) 
        external view 
        validProductId(productId) 
        validStage(stage) 
        returns (QualityAssessment[] memory) {
        return _qualityAssessments[productId][stage];
    }

    /**
     * @notice Get photo evidence for product and stage
     */
    function getPhotoEvidence(uint256 productId, uint8 stage) 
        external view 
        validProductId(productId) 
        validStage(stage) 
        returns (PhotoEvidence[] memory) {
        return _photoEvidence[productId][stage];
    }

    /**
     * @notice Get latest quality score
     */
    function getLatestQualityScore(uint256 productId) external view returns (uint256) {
        return _latestQualityScores[productId];
    }

    /**
     * @notice Get weather impacts
     */
    function getWeatherImpacts(uint256 productId) external view returns (WeatherImpact[] memory) {
        return _weatherImpacts[productId];
    }

    /**
     * @notice Get assessment by ID
     */
    function getAssessmentById(bytes32 assessmentId) external view returns (QualityAssessment memory) {
        return _assessmentById[assessmentId];
    }

    /**
     * @notice Get quality threshold for stage
     */
    function getQualityThreshold(uint8 stage) external view validStage(stage) returns (QualityThreshold memory) {
        return _qualityThresholds[stage];
    }

    /**
     * @notice Check if product meets quality standards
     */
    function meetsQualityStandards(uint256 productId, uint8 stage) external view returns (bool) {
        QualityThreshold memory threshold = _qualityThresholds[stage];
        uint256 currentScore = _latestQualityScores[productId];
        
        return threshold.isActive ? currentScore >= threshold.minScore : true;
    }

    /**
     * @notice Get quality score history
     */
    function getQualityScoreHistory(uint256 productId) external view returns (
        uint8[] memory stages,
        uint256[] memory scores,
        uint256[] memory timestamps
    ) {
        uint256 totalAssessments = 0;
        
        // Count total assessments across all stages
        for (uint8 i = 0; i <= 7; i++) {
            totalAssessments += _qualityAssessments[productId][i].length;
        }
        
        stages = new uint8[](totalAssessments);
        scores = new uint256[](totalAssessments);
        timestamps = new uint256[](totalAssessments);
        
        uint256 index = 0;
        for (uint8 i = 0; i <= 7; i++) {
            QualityAssessment[] memory stageAssessments = _qualityAssessments[productId][i];
            for (uint256 j = 0; j < stageAssessments.length; j++) {
                stages[index] = i;
                scores[index] = stageAssessments[j].qualityScore;
                timestamps[index] = stageAssessments[j].timestamp;
                index++;
            }
        }
    }

    /**
     * @notice Get AI validation status
     */
    function getAIValidationStatus(bytes32 assessmentId) external view returns (bool isValidated, string memory modelVersion) {
        QualityAssessment memory assessment = _assessmentById[assessmentId];
        return (assessment.isAIValidated, assessment.modelVersion);
    }

    // ============ VERIFICATION FUNCTIONS ============
    /**
     * @notice Verify assessment integrity
     */
    function verifyAssessmentIntegrity(
        bytes32 assessmentId,
        bytes32 currentDataHash
    ) external view returns (bool) {
        QualityAssessment memory assessment = _assessmentById[assessmentId];
        return assessment.assessmentDataHash == currentDataHash;
    }

    /**
     * @notice Verify photo evidence integrity
     */
    function verifyPhotoIntegrity(
        uint256 productId,
        uint8 stage,
        uint256 photoIndex,
        bytes32 currentPhotoHash
    ) external view validProductId(productId) validStage(stage) returns (bool) {
        PhotoEvidence[] memory evidence = _photoEvidence[productId][stage];
        
        if (photoIndex >= evidence.length) return false;
        return evidence[photoIndex].photoHash == currentPhotoHash;
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Verify assessment (auditor only)
     */
    function verifyAssessment(bytes32 assessmentId) external onlyRole(AUDITOR_ROLE) {
        require(_assessmentById[assessmentId].assessmentId != bytes32(0), "QualityAttestation: Assessment not found");
        _assessmentById[assessmentId].isVerified = true;
    }

    /**
     * @notice Set quality threshold
     */
    function setQualityThreshold(
        uint8 stage,
        uint256 minScore,
        uint256 warningScore,
        bool isActive
    ) external onlyRole(DEFAULT_ADMIN_ROLE) validStage(stage) {
        require(minScore <= 1000 && warningScore <= 1000, "QualityAttestation: Invalid scores");
        require(minScore <= warningScore, "QualityAttestation: Min score cannot exceed warning score");

        _qualityThresholds[stage] = QualityThreshold({
            stage: stage,
            minScore: minScore,
            warningScore: warningScore,
            isActive: isActive
        });
    }

    /**
     * @notice Batch verify assessments
     */
    function batchVerifyAssessments(bytes32[] calldata assessmentIds) external onlyRole(AUDITOR_ROLE) {
        for (uint256 i = 0; i < assessmentIds.length; i++) {
            if (_assessmentById[assessmentIds[i]].assessmentId != bytes32(0)) {
                _assessmentById[assessmentIds[i]].isVerified = true;
            }
        }
    }

    /**
     * @notice Emergency override quality score
     */
    function emergencyOverrideQualityScore(
        uint256 productId,
        uint256 newScore,
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) validProductId(productId) validScore(newScore) {
        require(bytes(reason).length > 0, "QualityAttestation: Reason required");
        
        _latestQualityScores[productId] = newScore;
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Check quality thresholds and emit alerts
     */
    function _checkQualityThresholds(uint256 productId, uint8 stage, uint256 score) internal {
        QualityThreshold memory threshold = _qualityThresholds[stage];
        
        if (!threshold.isActive) return;
        
        if (score < threshold.minScore) {
            emit QualityThresholdAlert(productId, stage, score, threshold.minScore, "CRITICAL", block.timestamp);
        } else if (score < threshold.warningScore) {
            emit QualityThresholdAlert(productId, stage, score, threshold.warningScore, "WARNING", block.timestamp);
        }
    }

    /**
     * @dev Update assessment with AI result
     */
    function _updateAssessmentWithAIResult(
        uint256 productId,
        bytes32 analysisId,
        uint256 aiScore,
        uint256 aiConfidence,
        string memory modelVersion
    ) internal {
        // Find matching assessment (simplified implementation)
        for (uint8 stage = 0; stage <= 7; stage++) {
            QualityAssessment[] storage assessments = _qualityAssessments[productId][stage];
            for (uint256 i = 0; i < assessments.length; i++) {
                if (!assessments[i].isAIValidated && 
                    block.timestamp <= assessments[i].timestamp + AI_VALIDATION_TIMEOUT) {
                    
                    assessments[i].isAIValidated = true;
                    assessments[i].modelVersion = modelVersion;
                    
                    // Update in mapping as well
                    _assessmentById[assessments[i].assessmentId].isAIValidated = true;
                    _assessmentById[assessments[i].assessmentId].modelVersion = modelVersion;
                    
                    return;
                }
            }
        }
    }

    /**
     * @dev Adjust quality score based on weather impact
     */
    function _adjustScoreForWeather(uint256 baseScore, int256 weatherImpact) internal pure returns (uint256) {
        int256 adjustedScore = int256(baseScore) + weatherImpact;
        
        if (adjustedScore < 0) return 0;
        if (adjustedScore > 1000) return 1000;
        
        return uint256(adjustedScore);
    }
}
