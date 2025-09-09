// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IAgriTrace.sol";
import "../interfaces/IStakeholder.sol";
import "../interfaces/IHashVerification.sol";
import "../libraries/CostCalculator.sol";
import "../libraries/DateTimeLib.sol";
import "../libraries/GeolocationLib.sol";
import "../core/AgriAccessControl.sol";

/**
 * @title ProductLifecycle
 * @dev Product journey tracking with cost tracking at each stage
 * @author AgriTrace Team
 */
contract ProductLifecycle is AgriAccessControl {
    using CostCalculator for CostCalculator.CostBreakdown;
    using DateTimeLib for uint256;
    using GeolocationLib for GeolocationLib.GPSCoordinate;

    // ============ EVENTS ============
    event LifecycleStageUpdated(
        uint256 indexed productId,
        uint8 indexed stage,
        address indexed stakeholder,
        bytes32 stageDataHash,
        bytes32 locationHash,
        uint256 timestamp
    );

    event CostRecorded(
        uint256 indexed productId,
        uint8 indexed stage,
        uint256 totalCost,
        bytes32 costDataHash,
        uint256 timestamp
    );

    event StageTransition(
        uint256 indexed productId,
        uint8 fromStage,
        uint8 toStage,
        address fromStakeholder,
        address toStakeholder,
        bytes32 transitionHash,
        uint256 timestamp
    );

    event LocationUpdated(
        uint256 indexed productId,
        bytes32 indexed locationHash,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum LifecycleStage {
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
    struct StageRecord {
        LifecycleStage stage;
        address stakeholder;
        bytes32 stageDataHash;
        bytes32 locationHash;
        bytes32 costDataHash;
        uint256 timestamp;
        uint256 duration; // Time spent in this stage
        bool isCompleted;
    }

    struct ProductJourney {
        uint256 productId;
        address currentStakeholder;
        LifecycleStage currentStage;
        bytes32 latestLocationHash;
        uint256 totalJourneyTime;
        uint256 lastUpdated;
        bool isActive;
    }

    struct TransitionRecord {
        uint8 fromStage;
        uint8 toStage;
        address fromStakeholder;
        address toStakeholder;
        bytes32 transitionDataHash;
        uint256 timestamp;
        bool isVerified;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => ProductJourney) private _productJourneys;
    mapping(uint256 => StageRecord[]) private _stageHistory;
    mapping(uint256 => TransitionRecord[]) private _transitions;
    mapping(uint256 => mapping(uint8 => bytes32)) private _stageCostHashes;
    mapping(uint256 => uint256) private _totalProductCosts;
    
    // Contract references
    IAgriTrace public agriTraceCore;
    IStakeholder public stakeholderContract;
    IHashVerification public hashVerificationContract;

    // Stage duration limits (in seconds)
    mapping(uint8 => uint256) private _maxStageDurations;

    // ============ MODIFIERS ============
    modifier productExists(uint256 productId) {
        require(_productJourneys[productId].productId != 0, "ProductLifecycle: Product not found");
        _;
    }

    modifier validStageProgression(uint256 productId, LifecycleStage newStage) {
        LifecycleStage currentStage = _productJourneys[productId].currentStage;
        require(uint8(newStage) == uint8(currentStage) + 1, "ProductLifecycle: Invalid stage progression");
        _;
    }

    modifier onlyCurrentStakeholder(uint256 productId) {
        require(_productJourneys[productId].currentStakeholder == msg.sender, "ProductLifecycle: Not current stakeholder");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        // Set default maximum stage durations
        _maxStageDurations[0] = 1 days;      // PLANTED
        _maxStageDurations[1] = 120 days;    // GROWING
        _maxStageDurations[2] = 7 days;      // HARVESTED
        _maxStageDurations[3] = 14 days;     // PROCESSED
        _maxStageDurations[4] = 3 days;      // PACKAGED
        _maxStageDurations[5] = 30 days;     // SHIPPED
        _maxStageDurations[6] = 7 days;      // DELIVERED
        _maxStageDurations[7] = 365 days;    // SOLD
    }

    // ============ SETUP FUNCTIONS ============
    function setAgriTraceCore(address _agriTraceCore) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_agriTraceCore != address(0), "ProductLifecycle: Invalid core contract");
        agriTraceCore = IAgriTrace(_agriTraceCore);
    }

    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakeholderContract != address(0), "ProductLifecycle: Invalid stakeholder contract");
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    function setHashVerificationContract(address _hashVerificationContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_hashVerificationContract != address(0), "ProductLifecycle: Invalid hash verification contract");
        hashVerificationContract = IHashVerification(_hashVerificationContract);
    }

    // ============ LIFECYCLE MANAGEMENT ============
    /**
     * @notice Initialize product lifecycle
     */
    function initializeProductLifecycle(
        uint256 productId,
        address farmer,
        bytes32 initialDataHash,
        bytes32 locationHash
    ) external onlyRole(FARMER_ROLE) {
        require(productId > 0, "ProductLifecycle: Invalid product ID");
        require(farmer != address(0), "ProductLifecycle: Invalid farmer address");
        require(initialDataHash != bytes32(0), "ProductLifecycle: Initial data hash required");
        require(locationHash != bytes32(0), "ProductLifecycle: Location hash required");
        require(_productJourneys[productId].productId == 0, "ProductLifecycle: Product already initialized");

        _productJourneys[productId] = ProductJourney({
            productId: productId,
            currentStakeholder: farmer,
            currentStage: LifecycleStage.PLANTED,
            latestLocationHash: locationHash,
            totalJourneyTime: 0,
            lastUpdated: block.timestamp,
            isActive: true
        });

        // Create initial stage record
        StageRecord memory initialStage = StageRecord({
            stage: LifecycleStage.PLANTED,
            stakeholder: farmer,
            stageDataHash: initialDataHash,
            locationHash: locationHash,
            costDataHash: bytes32(0),
            timestamp: block.timestamp,
            duration: 0,
            isCompleted: false
        });

        _stageHistory[productId].push(initialStage);

        emit LifecycleStageUpdated(productId, 0, farmer, initialDataHash, locationHash, block.timestamp);
    }

    /**
     * @notice Update lifecycle stage
     */
    function updateLifecycleStage(
        uint256 productId,
        LifecycleStage newStage,
        bytes32 stageDataHash,
        bytes32 locationHash,
        bytes32 costDataHash
    ) external 
      productExists(productId) 
      validStageProgression(productId, newStage)
      onlyCurrentStakeholder(productId) {
        
        require(stageDataHash != bytes32(0), "ProductLifecycle: Stage data hash required");
        require(locationHash != bytes32(0), "ProductLifecycle: Location hash required");

        ProductJourney storage journey = _productJourneys[productId];
        StageRecord[] storage stages = _stageHistory[productId];
        
        // Complete previous stage
        if (stages.length > 0) {
            StageRecord storage previousStage = stages[stages.length - 1];
            previousStage.isCompleted = true;
            previousStage.duration = block.timestamp - previousStage.timestamp;
            journey.totalJourneyTime += previousStage.duration;
        }

        // Create new stage record
        StageRecord memory newStageRecord = StageRecord({
            stage: newStage,
            stakeholder: msg.sender,
            stageDataHash: stageDataHash,
            locationHash: locationHash,
            costDataHash: costDataHash,
            timestamp: block.timestamp,
            duration: 0,
            isCompleted: false
        });

        stages.push(newStageRecord);
        
        // Update journey
        journey.currentStage = newStage;
        journey.latestLocationHash = locationHash;
        journey.lastUpdated = block.timestamp;

        // Store cost hash if provided
        if (costDataHash != bytes32(0)) {
            _stageCostHashes[productId][uint8(newStage)] = costDataHash;
        }

        emit LifecycleStageUpdated(productId, uint8(newStage), msg.sender, stageDataHash, locationHash, block.timestamp);
    }

    /**
     * @notice Transfer to next stakeholder
     */
    function transferToNextStakeholder(
        uint256 productId,
        address nextStakeholder,
        bytes32 transferDataHash
    ) external productExists(productId) onlyCurrentStakeholder(productId) {
        require(nextStakeholder != address(0), "ProductLifecycle: Invalid next stakeholder");
        require(nextStakeholder != msg.sender, "ProductLifecycle: Cannot transfer to self");
        require(transferDataHash != bytes32(0), "ProductLifecycle: Transfer data hash required");
        
        // Verify next stakeholder is registered and verified
        if (address(stakeholderContract) != address(0)) {
            require(stakeholderContract.isVerifiedAndIntact(nextStakeholder), "ProductLifecycle: Next stakeholder not verified");
        }

        ProductJourney storage journey = _productJourneys[productId];
        LifecycleStage currentStage = journey.currentStage;

        // Create transition record
        TransitionRecord memory transition = TransitionRecord({
            fromStage: uint8(currentStage),
            toStage: uint8(currentStage), // Same stage, different stakeholder
            fromStakeholder: msg.sender,
            toStakeholder: nextStakeholder,
            transitionDataHash: transferDataHash,
            timestamp: block.timestamp,
            isVerified: false
        });

        _transitions[productId].push(transition);
        journey.currentStakeholder = nextStakeholder;

        emit StageTransition(productId, uint8(currentStage), uint8(currentStage), msg.sender, nextStakeholder, transferDataHash, block.timestamp);
    }

    /**
     * @notice Record stage cost
     */
    function recordStageCost(
        uint256 productId,
        uint8 stage,
        uint256 totalCost,
        bytes32 costDataHash
    ) external productExists(productId) {
        require(costDataHash != bytes32(0), "ProductLifecycle: Cost data hash required");
        require(totalCost > 0, "ProductLifecycle: Invalid cost amount");
        
        // Verify caller can record costs for this stage
        require(_canRecordCostForStage(msg.sender, stage), "ProductLifecycle: Not authorized for this stage");

        _stageCostHashes[productId][stage] = costDataHash;
        _totalProductCosts[productId] += totalCost;

        emit CostRecorded(productId, stage, totalCost, costDataHash, block.timestamp);
    }

    /**
     * @notice Update location
     */
    function updateLocation(
        uint256 productId,
        bytes32 locationHash
    ) external productExists(productId) onlyCurrentStakeholder(productId) {
        require(locationHash != bytes32(0), "ProductLifecycle: Location hash required");

        _productJourneys[productId].latestLocationHash = locationHash;
        _productJourneys[productId].lastUpdated = block.timestamp;

        emit LocationUpdated(productId, locationHash, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get product journey
     */
    function getProductJourney(uint256 productId) external view productExists(productId) returns (ProductJourney memory) {
        return _productJourneys[productId];
    }

    /**
     * @notice Get stage history
     */
    function getStageHistory(uint256 productId) external view productExists(productId) returns (StageRecord[] memory) {
        return _stageHistory[productId];
    }

    /**
     * @notice Get transition history
     */
    function getTransitionHistory(uint256 productId) external view productExists(productId) returns (TransitionRecord[] memory) {
        return _transitions[productId];
    }

    /**
     * @notice Get current stage info
     */
    function getCurrentStageInfo(uint256 productId) external view productExists(productId) returns (
        LifecycleStage stage,
        address stakeholder,
        uint256 stageStartTime,
        uint256 stageDuration
    ) {
        ProductJourney memory journey = _productJourneys[productId];
        StageRecord[] memory stages = _stageHistory[productId];
        
        if (stages.length > 0) {
            StageRecord memory currentStage = stages[stages.length - 1];
            return (
                journey.currentStage,
                journey.currentStakeholder,
                currentStage.timestamp,
                block.timestamp - currentStage.timestamp
            );
        }
        
        return (journey.currentStage, journey.currentStakeholder, 0, 0);
    }

    /**
     * @notice Get stage cost hash
     */
    function getStageCostHash(uint256 productId, uint8 stage) external view returns (bytes32) {
        return _stageCostHashes[productId][stage];
    }

    /**
     * @notice Get total product cost
     */
    function getTotalProductCost(uint256 productId) external view returns (uint256) {
        return _totalProductCosts[productId];
    }

    /**
     * @notice Check if stage is overdue
     */
    function isStageOverdue(uint256 productId) external view productExists(productId) returns (bool) {
        ProductJourney memory journey = _productJourneys[productId];
        StageRecord[] memory stages = _stageHistory[productId];
        
        if (stages.length == 0) return false;
        
        StageRecord memory currentStage = stages[stages.length - 1];
        uint256 maxDuration = _maxStageDurations[uint8(journey.currentStage)];
        
        return !currentStage.isCompleted && (block.timestamp - currentStage.timestamp) > maxDuration;
    }

    /**
     * @notice Get products by current stakeholder
     */
    function getProductsByStakeholder(address stakeholder) external view returns (uint256[] memory) {
        // Note: This is a simplified implementation
        // In production, maintain a reverse mapping for efficiency
        uint256[] memory tempProducts = new uint256[](1000); // Arbitrary limit
        uint256 count = 0;
        
        // This would need to be optimized with proper indexing in production
        for (uint256 i = 1; i <= 1000; i++) {
            if (_productJourneys[i].currentStakeholder == stakeholder && _productJourneys[i].isActive) {
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
     * @notice Verify stage data integrity
     */
    function verifyStageDataIntegrity(
        uint256 productId,
        uint8 stage,
        bytes32 currentDataHash
    ) external view productExists(productId) returns (bool) {
        StageRecord[] memory stages = _stageHistory[productId];
        
        for (uint256 i = 0; i < stages.length; i++) {
            if (uint8(stages[i].stage) == stage) {
                return stages[i].stageDataHash == currentDataHash;
            }
        }
        
        return false;
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Set maximum stage duration
     */
    function setMaxStageDuration(uint8 stage, uint256 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(stage <= 7, "ProductLifecycle: Invalid stage");
        require(duration >= 1 hours && duration <= 365 days, "ProductLifecycle: Invalid duration");
        
        _maxStageDurations[stage] = duration;
    }

    /**
     * @notice Emergency complete stage
     */
    function emergencyCompleteStage(uint256 productId, string calldata reason) 
        external 
        onlyRole(EMERGENCY_ROLE) 
        productExists(productId) {
        
        StageRecord[] storage stages = _stageHistory[productId];
        if (stages.length > 0) {
            StageRecord storage currentStage = stages[stages.length - 1];
            currentStage.isCompleted = true;
            currentStage.duration = block.timestamp - currentStage.timestamp;
        }
    }

    /**
     * @notice Verify transition
     */
    function verifyTransition(uint256 productId, uint256 transitionIndex) 
        external 
        onlyRole(AUDITOR_ROLE) 
        productExists(productId) {
        
        require(transitionIndex < _transitions[productId].length, "ProductLifecycle: Invalid transition index");
        _transitions[productId][transitionIndex].isVerified = true;
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Check if caller can record cost for specific stage
     */
    function _canRecordCostForStage(address caller, uint8 stage) internal view returns (bool) {
        if (hasRole(AUDITOR_ROLE, caller) || hasRole(DEFAULT_ADMIN_ROLE, caller)) {
            return true;
        }
        
        if (stage <= 2 && hasRole(FARMER_ROLE, caller)) return true;          // PLANTED, GROWING, HARVESTED
        if (stage == 3 && hasRole(PROCESSOR_ROLE, caller)) return true;       // PROCESSED
        if (stage == 4 && (hasRole(PROCESSOR_ROLE, caller) || hasRole(DISTRIBUTOR_ROLE, caller))) return true; // PACKAGED
        if (stage >= 5 && stage <= 6 && hasRole(DISTRIBUTOR_ROLE, caller)) return true; // SHIPPED, DELIVERED
        if (stage == 7 && hasRole(RETAILER_ROLE, caller)) return true;        // SOLD
        
        return false;
    }
}
