// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./AgriAccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title EmergencyController
 * @dev Circuit breaker and emergency functions for platform security
 * @author AgriTrace Team
 */
contract EmergencyController is AgriAccessControl, Pausable, ReentrancyGuard {
    // ============ EVENTS ============
    event EmergencyActivated(
        string indexed emergencyType,
        address indexed activator,
        string reason,
        uint256 timestamp
    );

    event EmergencyDeactivated(
        string indexed emergencyType,
        address indexed deactivator,
        string reason,
        uint256 timestamp
    );

    event SecurityAlertTriggered(
        string indexed alertType,
        address indexed reporter,
        bytes32 indexed dataHash,
        uint256 severity,
        uint256 timestamp
    );

    event EmergencyActionExecuted(
        string indexed actionType,
        address indexed executor,
        bytes32 indexed targetHash,
        bool success,
        uint256 timestamp
    );

    event GuardianAdded(
        address indexed guardian,
        address indexed addedBy,
        uint256 timestamp
    );

    event GuardianRemoved(
        address indexed guardian,
        address indexed removedBy,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum EmergencyType {
        GLOBAL_PAUSE,           // 0 - Pause entire platform
        PRODUCT_QUARANTINE,     // 1 - Quarantine specific products
        STAKEHOLDER_SUSPEND,    // 2 - Suspend stakeholder access
        DATA_BREACH,           // 3 - Data integrity compromise
        SYSTEM_MAINTENANCE,     // 4 - Scheduled maintenance
        SECURITY_INCIDENT      // 5 - Security-related emergency
    }

    enum AlertSeverity {
        LOW,        // 0 - Minor issue
        MEDIUM,     // 1 - Moderate concern
        HIGH,       // 2 - Serious issue
        CRITICAL    // 3 - Immediate action required
    }

    // ============ STRUCTS ============
    struct EmergencyState {
        bool isActive;
        EmergencyType emergencyType;
        address activator;
        uint256 activatedAt;
        uint256 deactivatedAt;
        string reason;
        bytes32 dataHash;
    }

    struct SecurityAlert {
        uint256 id;
        string alertType;
        address reporter;
        bytes32 dataHash;
        AlertSeverity severity;
        uint256 timestamp;
        bool isResolved;
        string resolution;
    }

    struct Guardian {
        address guardianAddress;
        bool isActive;
        uint256 addedAt;
        uint256 totalActions;
        uint256 lastActionAt;
    }

    // ============ STATE VARIABLES ============
    mapping(string => EmergencyState) private _emergencyStates;
    mapping(address => Guardian) private _guardians;
    mapping(uint256 => SecurityAlert) private _securityAlerts;
    
    address[] private _guardianList;
    uint256 private _alertCounter;
    uint256 private _guardianCount;
    
    string[] private _activeEmergencies;
    
    // Emergency thresholds
    uint256 public constant CRITICAL_ALERT_THRESHOLD = 3;
    uint256 public constant GUARDIAN_CONSENSUS_THRESHOLD = 2; // 2 out of 3 guardians
    uint256 public constant MAX_EMERGENCY_DURATION = 7 days;

    // ============ MODIFIERS ============
    modifier onlyGuardian() {
        require(_guardians[msg.sender].isActive, "EmergencyController: Not an active guardian");
        _;
    }

    modifier onlyEmergencyRole() {
        require(
            hasRole(EMERGENCY_ROLE, msg.sender) || 
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
            _guardians[msg.sender].isActive,
            "EmergencyController: Not authorized for emergency actions"
        );
        _;
    }

    modifier emergencyNotActive(string memory emergencyType) {
        require(!_emergencyStates[emergencyType].isActive, "EmergencyController: Emergency already active");
        _;
    }

    modifier emergencyActive(string memory emergencyType) {
        require(_emergencyStates[emergencyType].isActive, "EmergencyController: Emergency not active");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        // Add deployer as first guardian
        _addGuardian(msg.sender);
    }

    // ============ GUARDIAN MANAGEMENT ============
    /**
     * @notice Add emergency guardian
     */
    function addGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(guardian != address(0), "EmergencyController: Invalid guardian address");
        require(!_guardians[guardian].isActive, "EmergencyController: Guardian already active");
        require(_guardianCount < 10, "EmergencyController: Too many guardians");

        _addGuardian(guardian);
        emit GuardianAdded(guardian, msg.sender, block.timestamp);
    }

    /**
     * @notice Remove emergency guardian
     */
    function removeGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_guardians[guardian].isActive, "EmergencyController: Guardian not active");
        require(_guardianCount > 1, "EmergencyController: Cannot remove last guardian");

        _guardians[guardian].isActive = false;
        _guardianCount--;

        // Remove from guardian list
        for (uint256 i = 0; i < _guardianList.length; i++) {
            if (_guardianList[i] == guardian) {
                _guardianList[i] = _guardianList[_guardianList.length - 1];
                _guardianList.pop();
                break;
            }
        }

        emit GuardianRemoved(guardian, msg.sender, block.timestamp);
    }

    // ============ EMERGENCY FUNCTIONS ============
    /**
     * @notice Activate emergency state
     */
    function activateEmergency(
        string calldata emergencyType,
        EmergencyType eType,
        string calldata reason,
        bytes32 dataHash
    ) external onlyEmergencyRole emergencyNotActive(emergencyType) nonReentrant {
        require(bytes(emergencyType).length > 0, "EmergencyController: Emergency type required");
        require(bytes(reason).length > 0, "EmergencyController: Reason required");

        _emergencyStates[emergencyType] = EmergencyState({
            isActive: true,
            emergencyType: eType,
            activator: msg.sender,
            activatedAt: block.timestamp,
            deactivatedAt: 0,
            reason: reason,
            dataHash: dataHash
        });

        _activeEmergencies.push(emergencyType);

        // Auto-pause if global emergency
        if (eType == EmergencyType.GLOBAL_PAUSE) {
            _pause();
        }

        emit EmergencyActivated(emergencyType, msg.sender, reason, block.timestamp);
    }

    /**
     * @notice Deactivate emergency state
     */
    function deactivateEmergency(
        string calldata emergencyType,
        string calldata reason
    ) external onlyEmergencyRole emergencyActive(emergencyType) nonReentrant {
        require(bytes(reason).length > 0, "EmergencyController: Reason required");

        EmergencyState storage emergency = _emergencyStates[emergencyType];
        emergency.isActive = false;
        emergency.deactivatedAt = block.timestamp;

        // Remove from active emergencies
        _removeFromActiveEmergencies(emergencyType);

        // Auto-unpause if global emergency and no other critical emergencies
        if (emergency.emergencyType == EmergencyType.GLOBAL_PAUSE && _activeEmergencies.length == 0) {
            _unpause();
        }

        emit EmergencyDeactivated(emergencyType, msg.sender, reason, block.timestamp);
    }

    /**
     * @notice Trigger security alert
     */
    function triggerSecurityAlert(
        string calldata alertType,
        bytes32 dataHash,
        AlertSeverity severity,
        string calldata description
    ) external returns (uint256 alertId) {
        require(bytes(alertType).length > 0, "EmergencyController: Alert type required");

        _alertCounter++;
        alertId = _alertCounter;

        _securityAlerts[alertId] = SecurityAlert({
            id: alertId,
            alertType: alertType,
            reporter: msg.sender,
            dataHash: dataHash,
            severity: severity,
            timestamp: block.timestamp,
            isResolved: false,
            resolution: ""
        });

        emit SecurityAlertTriggered(alertType, msg.sender, dataHash, uint256(severity), block.timestamp);

        // Auto-trigger emergency for critical alerts
        if (severity == AlertSeverity.CRITICAL) {
            string memory emergencyType = string(abi.encodePacked("CRITICAL_", alertType));
            if (!_emergencyStates[emergencyType].isActive) {
                this.activateEmergency(
                    emergencyType,
                    EmergencyType.SECURITY_INCIDENT,
                    string(abi.encodePacked("Critical alert: ", alertType)),
                    dataHash
                );
            }
        }

        return alertId;
    }

    /**
     * @notice Execute emergency action
     */
    function executeEmergencyAction(
        string calldata actionType,
        bytes32 targetHash,
        bytes calldata actionData
    ) external onlyEmergencyRole nonReentrant returns (bool success) {
        require(bytes(actionType).length > 0, "EmergencyController: Action type required");

        // Record guardian action
        if (_guardians[msg.sender].isActive) {
            _guardians[msg.sender].totalActions++;
            _guardians[msg.sender].lastActionAt = block.timestamp;
        }

        // Execute action based on type
        success = _executeAction(actionType, targetHash, actionData);

        emit EmergencyActionExecuted(actionType, msg.sender, targetHash, success, block.timestamp);
        
        return success;
    }

    /**
     * @notice Emergency pause (guardian consensus)
     */
    function emergencyPause(string calldata reason) external onlyGuardian {
        require(!paused(), "EmergencyController: Already paused");
        
        // Call internal emergency activation
        _activateEmergencyInternal(
            "GUARDIAN_PAUSE",
            EmergencyType.GLOBAL_PAUSE,
            reason,
            keccak256(abi.encodePacked(msg.sender, block.timestamp))
        );
    }

    /**
     * @notice Emergency unpause (admin only)
     */
    function emergencyUnpause(string calldata reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(paused(), "EmergencyController: Not paused");
        
        // Call internal emergency deactivation
        _deactivateEmergencyInternal("GUARDIAN_PAUSE", reason);
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get emergency state
     */
    function getEmergencyState(string calldata emergencyType) external view returns (EmergencyState memory) {
        return _emergencyStates[emergencyType];
    }

    /**
     * @notice Check if emergency is active
     */
    function isEmergencyActive(string calldata emergencyType) external view returns (bool) {
        return _emergencyStates[emergencyType].isActive;
    }

    /**
     * @notice Get security alert
     */
    function getSecurityAlert(uint256 alertId) external view returns (SecurityAlert memory) {
        require(alertId > 0 && alertId <= _alertCounter, "EmergencyController: Invalid alert ID");
        return _securityAlerts[alertId];
    }

    /**
     * @notice Get guardian info
     */
    function getGuardianInfo(address guardian) external view returns (Guardian memory) {
        return _guardians[guardian];
    }

    /**
     * @notice Get all guardians
     */
    function getGuardians() external view returns (address[] memory) {
        return _guardianList;
    }

    /**
     * @notice Get active emergencies
     */
    function getActiveEmergencies() external view returns (string[] memory) {
        return _activeEmergencies;
    }

    /**
     * @notice Get critical alerts count
     */
    function getCriticalAlertsCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 1; i <= _alertCounter; i++) {
            if (_securityAlerts[i].severity == AlertSeverity.CRITICAL && !_securityAlerts[i].isResolved) {
                count++;
            }
        }
        return count;
    }

    /**
     * @notice Check if guardian consensus is reached
     */
    function hasGuardianConsensus() external view returns (bool) {
        return _guardianCount >= GUARDIAN_CONSENSUS_THRESHOLD;
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Add guardian to system
     */
    function _addGuardian(address guardian) internal {
        _guardians[guardian] = Guardian({
            guardianAddress: guardian,
            isActive: true,
            addedAt: block.timestamp,
            totalActions: 0,
            lastActionAt: 0
        });

        _guardianList.push(guardian);
        _guardianCount++;

        // Grant emergency role
        grantRole(EMERGENCY_ROLE, guardian);
    }

    /**
     * @dev Internal function to activate emergency without modifiers
     */
    function _activateEmergencyInternal(
        string memory emergencyType,
        EmergencyType eType,
        string memory reason,
        bytes32 dataHash
    ) internal {
        require(!_emergencyStates[emergencyType].isActive, "EmergencyController: Emergency already active");
        require(bytes(emergencyType).length > 0, "EmergencyController: Emergency type required");
        require(bytes(reason).length > 0, "EmergencyController: Reason required");

        _emergencyStates[emergencyType] = EmergencyState({
            isActive: true,
            emergencyType: eType,
            activator: msg.sender,
            activatedAt: block.timestamp,
            deactivatedAt: 0,
            reason: reason,
            dataHash: dataHash
        });

        _activeEmergencies.push(emergencyType);

        // Auto-pause if global emergency
        if (eType == EmergencyType.GLOBAL_PAUSE) {
            _pause();
        }

        emit EmergencyActivated(emergencyType, msg.sender, reason, block.timestamp);
    }

    /**
     * @dev Internal function to deactivate emergency without modifiers
     */
    function _deactivateEmergencyInternal(
        string memory emergencyType,
        string memory reason
    ) internal {
        require(_emergencyStates[emergencyType].isActive, "EmergencyController: Emergency not active");
        require(bytes(reason).length > 0, "EmergencyController: Reason required");

        EmergencyState storage emergency = _emergencyStates[emergencyType];
        emergency.isActive = false;
        emergency.deactivatedAt = block.timestamp;

        // Remove from active emergencies
        _removeFromActiveEmergenciesInternal(emergencyType);

        // Auto-unpause if global emergency and no other critical emergencies
        if (emergency.emergencyType == EmergencyType.GLOBAL_PAUSE && _activeEmergencies.length == 0) {
            _unpause();
        }

        emit EmergencyDeactivated(emergencyType, msg.sender, reason, block.timestamp);
    }

    /**
     * @dev Remove emergency type from active list (internal version)
     */
    function _removeFromActiveEmergenciesInternal(string memory emergencyType) internal {
        for (uint256 i = 0; i < _activeEmergencies.length; i++) {
            if (keccak256(bytes(_activeEmergencies[i])) == keccak256(bytes(emergencyType))) {
                _activeEmergencies[i] = _activeEmergencies[_activeEmergencies.length - 1];
                _activeEmergencies.pop();
                break;
            }
        }
    }

    /**
     * @dev Remove emergency type from active list
     */
    function _removeFromActiveEmergencies(string calldata emergencyType) internal {
        for (uint256 i = 0; i < _activeEmergencies.length; i++) {
            if (keccak256(bytes(_activeEmergencies[i])) == keccak256(bytes(emergencyType))) {
                _activeEmergencies[i] = _activeEmergencies[_activeEmergencies.length - 1];
                _activeEmergencies.pop();
                break;
            }
        }
    }

    /**
     * @dev Execute specific emergency action
     */
    function _executeAction(
        string calldata actionType,
        bytes32 targetHash,
        bytes calldata actionData
    ) internal returns (bool) {
        // Implement specific emergency actions
        // This is a placeholder for actual emergency action execution
        bytes32 actionHash = keccak256(bytes(actionType));
        
        if (actionHash == keccak256(bytes("QUARANTINE_PRODUCT"))) {
            // Quarantine specific product
            return true;
        } else if (actionHash == keccak256(bytes("SUSPEND_STAKEHOLDER"))) {
            // Suspend stakeholder access
            return true;
        } else if (actionHash == keccak256(bytes("INVALIDATE_DATA"))) {
            // Invalidate compromised data
            return true;
        }
        
        return false;
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Resolve security alert
     */
    function resolveSecurityAlert(
        uint256 alertId,
        string calldata resolution
    ) external onlyRole(AUDITOR_ROLE) {
        require(alertId > 0 && alertId <= _alertCounter, "EmergencyController: Invalid alert ID");
        require(!_securityAlerts[alertId].isResolved, "EmergencyController: Alert already resolved");
        require(bytes(resolution).length > 0, "EmergencyController: Resolution required");

        _securityAlerts[alertId].isResolved = true;
        _securityAlerts[alertId].resolution = resolution;
    }

    /**
     * @notice Auto-deactivate expired emergencies
     */
    function deactivateExpiredEmergencies() external {
        for (uint256 i = 0; i < _activeEmergencies.length; i++) {
            string memory emergencyType = _activeEmergencies[i];
            EmergencyState storage emergency = _emergencyStates[emergencyType];
            
            if (block.timestamp > emergency.activatedAt + MAX_EMERGENCY_DURATION) {
                emergency.isActive = false;
                emergency.deactivatedAt = block.timestamp;
                
                emit EmergencyDeactivated(
                    emergencyType,
                    address(this),
                    "Auto-deactivated due to expiration",
                    block.timestamp
                );
            }
        }
    }
}