// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IMLOracle.sol";
import "../core/AgriAccessControl.sol";
import "../libraries/DateTimeLib.sol";

/**
 * @title DamageDetection
 * @dev Photo-based damage assessment using AI analysis
 * @author AgriTrace Team
 */
contract DamageDetection is AgriAccessControl {
    using DateTimeLib for uint256;

    // ============ EVENTS ============
    event DamageReportSubmitted(
        uint256 indexed productId,
        uint8 indexed stage,
        bytes32 indexed damageId,
        bytes32 photoHash,
        string damageType,
        uint8 severity,
        address reporter,
        uint256 timestamp
    );

    event DamageAnalysisCompleted(
        uint256 indexed productId,
        bytes32 indexed damageId,
        bytes32 analysisResultHash,
        uint8 aiSeverity,
        uint256 confidence,
        string modelVersion,
        uint256 timestamp
    );

    event DamageStatusUpdated(
        uint256 indexed productId,
        bytes32 indexed damageId,
        DamageStatus oldStatus,
        DamageStatus newStatus,
        address updater,
        uint256 timestamp
    );

    event RepairActionRecorded(
        uint256 indexed productId,
        bytes32 indexed damageId,
        bytes32 repairActionHash,
        address repairer,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum DamageStatus {
        REPORTED,     // 0 - Damage reported, awaiting verification
        CONFIRMED,    // 1 - Damage confirmed
        UNDER_REPAIR, // 2 - Repair in progress
        REPAIRED,     // 3 - Repair completed
        IRREPARABLE   // 4 - Cannot be repaired
    }

    enum DamageSeverity {
        NONE,         // 0 - No damage
        MINOR,        // 1 - Minor damage (1-2)
        MODERATE,     // 2 - Moderate damage (3-5)
        SEVERE,       // 3 - Severe damage (6-8)
        CRITICAL      // 4 - Critical damage (9-10)
    }

    // ============ STRUCTS ============
    struct DamageReport {
        bytes32 damageId;
        uint256 productId;
        uint8 stage;
        string damageType;
        uint8 severity; // 1-10 scale
        bytes32 photoHash;
        bytes32 descriptionHash;
        address reporter;
        uint256 timestamp;
        DamageStatus status;
        bool isAIAnalyzed;
        bool isVerified;
    }

    struct AIAnalysisResult {
        bytes32 damageId;
        bytes32 analysisResultHash;
        uint8 aiSeverity;
        uint256 confidence;
        string modelVersion;
        string aiDamageType;
        uint256 analysisTimestamp;
        bool isValidated;
    }

    struct RepairAction {
        bytes32 repairId;
        bytes32 damageId;
        bytes32 repairActionHash;
        address repairer;
        uint256 estimatedCost;
        uint256 actualCost;
        uint256 startTime;
        uint256 completionTime;
        bool isCompleted;
        string repairMethod;
    }

    struct DamageStatistics {
        uint256 totalReports;
        uint256 confirmedDamages;
        uint256 repairedDamages;
        uint256 irreparableDamages;
        uint256 avgSeverity;
        uint256 lastUpdated;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => mapping(uint8 => DamageReport[])) private _damageReports;
    mapping(bytes32 => DamageReport) private _damageById;
    mapping(bytes32 => AIAnalysisResult) private _aiAnalysisResults;
    mapping(bytes32 => RepairAction[]) private _repairActions;
    mapping(uint256 => DamageStatistics) private _damageStats;
    mapping(string => uint256) private _damageTypeCount;
    
    // Contract references
    IMLOracle public mlOracleContract;
    
    // Detection parameters
    uint256 public constant MIN_AI_CONFIDENCE = 75;
    uint256 public constant ANALYSIS_TIMEOUT = 12 hours;
    uint256 public constant SEVERITY_THRESHOLD_ALERT = 7;

    // ============ MODIFIERS ============
    modifier validProductId(uint256 productId) {
        require(productId > 0, "DamageDetection: Invalid product ID");
        _;
    }

    modifier validStage(uint8 stage) {
        require(stage <= 7, "DamageDetection: Invalid stage");
        _;
    }

    modifier validSeverity(uint8 severity) {
        require(severity >= 1 && severity <= 10, "DamageDetection: Severity must be 1-10");
        _;
    }

    modifier damageExists(bytes32 damageId) {
        require(_damageById[damageId].damageId != bytes32(0), "DamageDetection: Damage report not found");
        _;
    }

    modifier onlyAuthorizedReporter() {
        require(
            hasRole(FARMER_ROLE, msg.sender) ||
            hasRole(PROCESSOR_ROLE, msg.sender) ||
            hasRole(DISTRIBUTOR_ROLE, msg.sender) ||
            hasRole(RETAILER_ROLE, msg.sender) ||
            hasRole(AUDITOR_ROLE, msg.sender),
            "DamageDetection: Not authorized to report damage"
        );
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============ SETUP FUNCTIONS ============
    function setMLOracleContract(address _mlOracleContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_mlOracleContract != address(0), "DamageDetection: Invalid ML oracle contract");
        mlOracleContract = IMLOracle(_mlOracleContract);
    }

    // ============ DAMAGE REPORTING ============
    /**
     * @notice Submit damage report with photo evidence
     */
    function submitDamageReport(
        uint256 productId,
        uint8 stage,
        string calldata damageType,
        uint8 severity,
        bytes32 photoHash,
        bytes32 descriptionHash
    ) external 
      validProductId(productId) 
      validStage(stage) 
      validSeverity(severity) 
      onlyAuthorizedReporter {
        
        require(bytes(damageType).length > 0, "DamageDetection: Damage type required");
        require(photoHash != bytes32(0), "DamageDetection: Photo hash required");
        require(descriptionHash != bytes32(0), "DamageDetection: Description hash required");

        bytes32 damageId = keccak256(abi.encodePacked(
            productId,
            stage,
            msg.sender,
            block.timestamp,
            photoHash
        ));

        DamageReport memory report = DamageReport({
            damageId: damageId,
            productId: productId,
            stage: stage,
            damageType: damageType,
            severity: severity,
            photoHash: photoHash,
            descriptionHash: descriptionHash,
            reporter: msg.sender,
            timestamp: block.timestamp,
            status: DamageStatus.REPORTED,
            isAIAnalyzed: false,
            isVerified: false
        });

        _damageReports[productId][stage].push(report);
        _damageById[damageId] = report;
        
        // Update statistics
        _updateDamageStatistics(productId, damageType, severity);

        // Submit for AI analysis if ML Oracle is available
        if (address(mlOracleContract) != address(0)) {
            mlOracleContract.submitPhotoHash(productId, stage, photoHash, damageType, severity);
        }

        // Emit alert for severe damage
        if (severity >= SEVERITY_THRESHOLD_ALERT) {
            // Additional alerting logic can be added here
        }

        emit DamageReportSubmitted(productId, stage, damageId, photoHash, damageType, severity, msg.sender, block.timestamp);
    }

    /**
 * @notice Process AI damage analysis result
 */
function processAIDamageAnalysis(
    bytes32 damageId,
    bytes32 analysisResultHash,
    uint8 aiSeverity,
    uint256 confidence,
    string calldata modelVersion,
    string calldata aiDamageType
) external onlyRole(ML_ORACLE_ROLE) damageExists(damageId) {
    require(analysisResultHash != bytes32(0), "DamageDetection: Analysis result hash required");
    require(aiSeverity <= 10, "DamageDetection: Invalid AI severity");
    require(confidence <= 100, "DamageDetection: Invalid confidence");
    require(bytes(modelVersion).length > 0, "DamageDetection: Model version required");

    AIAnalysisResult memory result = AIAnalysisResult({
        damageId: damageId,
        analysisResultHash: analysisResultHash,
        aiSeverity: aiSeverity,
        confidence: confidence,
        modelVersion: modelVersion,
        aiDamageType: aiDamageType,
        analysisTimestamp: block.timestamp,
        isValidated: confidence >= MIN_AI_CONFIDENCE
    });

    _aiAnalysisResults[damageId] = result;
    _damageById[damageId].isAIAnalyzed = true;

    // Auto-confirm if AI confidence is high
    if (confidence >= MIN_AI_CONFIDENCE) {
        _updateDamageStatus(damageId, DamageStatus.CONFIRMED);
    }

    // Fix: Use productId instead of damageId for the second parameter
    emit DamageAnalysisCompleted(_damageById[damageId].productId, damageId, analysisResultHash, aiSeverity, confidence, modelVersion, block.timestamp);
}

    /**
     * @notice Update damage status
     */
    function updateDamageStatus(
        bytes32 damageId,
        DamageStatus newStatus
    ) external onlyRole(AUDITOR_ROLE) damageExists(damageId) {
        _updateDamageStatus(damageId, newStatus);
    }

    /**
     * @notice Record repair action
     */
    function recordRepairAction(
        bytes32 damageId,
        bytes32 repairActionHash,
        uint256 estimatedCost,
        string calldata repairMethod
    ) external damageExists(damageId) {
        require(repairActionHash != bytes32(0), "DamageDetection: Repair action hash required");
        require(bytes(repairMethod).length > 0, "DamageDetection: Repair method required");
        
        DamageReport storage damage = _damageById[damageId];
        require(
            damage.status == DamageStatus.CONFIRMED || damage.status == DamageStatus.UNDER_REPAIR,
            "DamageDetection: Cannot repair in current status"
        );

        bytes32 repairId = keccak256(abi.encodePacked(
            damageId,
            msg.sender,
            block.timestamp
        ));

        RepairAction memory action = RepairAction({
            repairId: repairId,
            damageId: damageId,
            repairActionHash: repairActionHash,
            repairer: msg.sender,
            estimatedCost: estimatedCost,
            actualCost: 0,
            startTime: block.timestamp,
            completionTime: 0,
            isCompleted: false,
            repairMethod: repairMethod
        });

        _repairActions[damageId].push(action);
        
        // Update damage status to under repair
        if (damage.status != DamageStatus.UNDER_REPAIR) {
            _updateDamageStatus(damageId, DamageStatus.UNDER_REPAIR);
        }

        emit RepairActionRecorded(damage.productId, damageId, repairActionHash, msg.sender, block.timestamp);
    }

    /**
     * @notice Complete repair action
     */
    function completeRepairAction(
        bytes32 damageId,
        uint256 repairIndex,
        uint256 actualCost,
        bytes32 completionEvidenceHash
    ) external damageExists(damageId) {
        require(completionEvidenceHash != bytes32(0), "DamageDetection: Completion evidence hash required");
        
        RepairAction[] storage actions = _repairActions[damageId];
        require(repairIndex < actions.length, "DamageDetection: Invalid repair index");
        
        RepairAction storage action = actions[repairIndex];
        require(action.repairer == msg.sender || hasRole(AUDITOR_ROLE, msg.sender), "DamageDetection: Not authorized");
        require(!action.isCompleted, "DamageDetection: Repair already completed");

        action.actualCost = actualCost;
        action.completionTime = block.timestamp;
        action.isCompleted = true;

        // Check if all repairs are completed
        bool allRepairsCompleted = true;
        for (uint256 i = 0; i < actions.length; i++) {
            if (!actions[i].isCompleted) {
                allRepairsCompleted = false;
                break;
            }
        }

        if (allRepairsCompleted) {
            _updateDamageStatus(damageId, DamageStatus.REPAIRED);
        }
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get damage reports for product and stage
     */
    function getDamageReports(uint256 productId, uint8 stage) 
        external view 
        validProductId(productId) 
        validStage(stage) 
        returns (DamageReport[] memory) {
        return _damageReports[productId][stage];
    }

    /**
     * @notice Get damage report by ID
     */
    function getDamageById(bytes32 damageId) external view damageExists(damageId) returns (DamageReport memory) {
        return _damageById[damageId];
    }

    /**
     * @notice Get AI analysis result
     */
    function getAIAnalysisResult(bytes32 damageId) external view returns (AIAnalysisResult memory) {
        return _aiAnalysisResults[damageId];
    }

    /**
     * @notice Get repair actions for damage
     */
    function getRepairActions(bytes32 damageId) external view returns (RepairAction[] memory) {
        return _repairActions[damageId];
    }

    /**
     * @notice Get damage statistics for product
     */
    function getDamageStatistics(uint256 productId) external view returns (DamageStatistics memory) {
        return _damageStats[productId];
    }

    /**
     * @notice Check if product has critical damage
     */
    function hasCriticalDamage(uint256 productId) external view returns (bool) {
        for (uint8 stage = 0; stage <= 7; stage++) {
            DamageReport[] memory reports = _damageReports[productId][stage];
            for (uint256 i = 0; i < reports.length; i++) {
                if (reports[i].severity >= SEVERITY_THRESHOLD_ALERT && 
                    reports[i].status != DamageStatus.REPAIRED) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * @notice Get damage severity classification
     */
    function getDamageSeverityClassification(uint8 severity) external pure returns (DamageSeverity) {
        if (severity == 0) return DamageSeverity.NONE;
        if (severity <= 2) return DamageSeverity.MINOR;
        if (severity <= 5) return DamageSeverity.MODERATE;
        if (severity <= 8) return DamageSeverity.SEVERE;
        return DamageSeverity.CRITICAL;
    }

    /**
     * @notice Get pending AI analysis reports
     */
    function getPendingAIAnalysis() external view returns (bytes32[] memory) {
        // Simplified implementation - in production, maintain a separate mapping
        bytes32[] memory pending = new bytes32[](100); // Arbitrary limit
        uint256 count = 0;
        
        // This would need optimization in production
        // Currently simplified for demonstration
        
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = pending[i];
        }
        
        return result;
    }

    /**
     * @notice Verify damage report integrity
     */
    function verifyDamageReportIntegrity(
        bytes32 damageId,
        bytes32 currentDescriptionHash,
        bytes32 currentPhotoHash
    ) external view damageExists(damageId) returns (bool) {
        DamageReport memory report = _damageById[damageId];
        return report.descriptionHash == currentDescriptionHash && report.photoHash == currentPhotoHash;
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Verify damage report
     */
    function verifyDamageReport(bytes32 damageId) external onlyRole(AUDITOR_ROLE) damageExists(damageId) {
        _damageById[damageId].isVerified = true;
        
        if (_damageById[damageId].status == DamageStatus.REPORTED) {
            _updateDamageStatus(damageId, DamageStatus.CONFIRMED);
        }
    }

    /**
     * @notice Mark damage as irreparable
     */
    function markAsIrreparable(bytes32 damageId, string calldata reason) 
        external 
        onlyRole(AUDITOR_ROLE) 
        damageExists(damageId) {
        require(bytes(reason).length > 0, "DamageDetection: Reason required");
        
        _updateDamageStatus(damageId, DamageStatus.IRREPARABLE);
    }

    /**
     * @notice Batch verify damage reports
     */
    function batchVerifyDamageReports(bytes32[] calldata damageIds) external onlyRole(AUDITOR_ROLE) {
        for (uint256 i = 0; i < damageIds.length; i++) {
            if (_damageById[damageIds[i]].damageId != bytes32(0)) {
                _damageById[damageIds[i]].isVerified = true;
                if (_damageById[damageIds[i]].status == DamageStatus.REPORTED) {
                    _updateDamageStatus(damageIds[i], DamageStatus.CONFIRMED);
                }
            }
        }
    }

    /**
     * @notice Emergency override damage status
     */
    function emergencyOverrideDamageStatus(
        bytes32 damageId,
        DamageStatus newStatus,
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) damageExists(damageId) {
        require(bytes(reason).length > 0, "DamageDetection: Reason required");
        
        _updateDamageStatus(damageId, newStatus);
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Update damage status
     */
    function _updateDamageStatus(bytes32 damageId, DamageStatus newStatus) internal {
        DamageReport storage report = _damageById[damageId];
        DamageStatus oldStatus = report.status;
        report.status = newStatus;

        emit DamageStatusUpdated(report.productId, damageId, oldStatus, newStatus, msg.sender, block.timestamp);
    }

    /**
     * @dev Update damage statistics
     */
    function _updateDamageStatistics(uint256 productId, string memory damageType, uint8 severity) internal {
        DamageStatistics storage stats = _damageStats[productId];
        
        stats.totalReports++;
        stats.avgSeverity = ((stats.avgSeverity * (stats.totalReports - 1)) + severity) / stats.totalReports;
        stats.lastUpdated = block.timestamp;
        
        _damageTypeCount[damageType]++;
    }
}
