// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title AccessControl
 * @dev Role-based access control for AgriTrace platform
 * @author AgriTrace Team
 */
contract AgriAccessControl is AccessControl {
    // ============ ROLE DEFINITIONS ============
    bytes32 public constant FARMER_ROLE = keccak256("FARMER_ROLE");
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant RETAILER_ROLE = keccak256("RETAILER_ROLE");
    bytes32 public constant CONSUMER_ROLE = keccak256("CONSUMER_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant ML_ORACLE_ROLE = keccak256("ML_ORACLE_ROLE");
    bytes32 public constant IOT_DEVICE_ROLE = keccak256("IOT_DEVICE_ROLE");

    // ============ EVENTS ============
    event RoleGrantedWithTimestamp(
        bytes32 indexed role,
        address indexed account,
        address indexed sender,
        uint256 timestamp
    );

    event RoleRevokedWithTimestamp(
        bytes32 indexed role,
        address indexed account,
        address indexed sender,
        uint256 timestamp
    );

    event RoleAdminChanged(
        bytes32 indexed role,
        bytes32 indexed previousAdminRole,
        bytes32 indexed newAdminRole,
        uint256 timestamp
    );

    // ============ STATE VARIABLES ============
    mapping(address => mapping(bytes32 => uint256)) private _roleGrantedTimestamp;
    mapping(address => mapping(bytes32 => uint256)) private _roleRevokedTimestamp;
    mapping(bytes32 => uint256) private _roleCreatedTimestamp;
    mapping(address => bytes32[]) private _userRoles;
    mapping(bytes32 => address[]) private _roleMembers;

    // ============ CONSTRUCTOR ============
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setRoleAdmin(FARMER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(PROCESSOR_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(DISTRIBUTOR_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(RETAILER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(CONSUMER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(AUDITOR_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(EMERGENCY_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(ML_ORACLE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(IOT_DEVICE_ROLE, DEFAULT_ADMIN_ROLE);

        // Record creation timestamps
        _roleCreatedTimestamp[DEFAULT_ADMIN_ROLE] = block.timestamp;
        _roleCreatedTimestamp[FARMER_ROLE] = block.timestamp;
        _roleCreatedTimestamp[PROCESSOR_ROLE] = block.timestamp;
        _roleCreatedTimestamp[DISTRIBUTOR_ROLE] = block.timestamp;
        _roleCreatedTimestamp[RETAILER_ROLE] = block.timestamp;
        _roleCreatedTimestamp[CONSUMER_ROLE] = block.timestamp;
        _roleCreatedTimestamp[AUDITOR_ROLE] = block.timestamp;
        _roleCreatedTimestamp[EMERGENCY_ROLE] = block.timestamp;
        _roleCreatedTimestamp[ML_ORACLE_ROLE] = block.timestamp;
        _roleCreatedTimestamp[IOT_DEVICE_ROLE] = block.timestamp;
    }

    // ============ ENHANCED ROLE MANAGEMENT ============
    /**
     * @notice Grant role with timestamp tracking
     */
    function grantRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        super.grantRole(role, account);
        _roleGrantedTimestamp[account][role] = block.timestamp;
        _addUserRole(account, role);
        _addRoleMember(role, account);
        emit RoleGrantedWithTimestamp(role, account, msg.sender, block.timestamp);
    }

    /**
     * @notice Revoke role with timestamp tracking
     */
    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        super.revokeRole(role, account);
        _roleRevokedTimestamp[account][role] = block.timestamp;
        _removeUserRole(account, role);
        _removeRoleMember(role, account);
        emit RoleRevokedWithTimestamp(role, account, msg.sender, block.timestamp);
    }

    /**
     * @notice Grant multiple roles to an account
     */
    function grantMultipleRoles(bytes32[] calldata roles, address account) external {
        for (uint256 i = 0; i < roles.length; i++) {
            require(hasRole(getRoleAdmin(roles[i]), msg.sender), "AccessControl: sender must be an admin");
            grantRole(roles[i], account);
        }
    }

    /**
     * @notice Revoke multiple roles from an account
     */
    function revokeMultipleRoles(bytes32[] calldata roles, address account) external {
        for (uint256 i = 0; i < roles.length; i++) {
            require(hasRole(getRoleAdmin(roles[i]), msg.sender), "AccessControl: sender must be an admin");
            revokeRole(roles[i], account);
        }
    }

    /**
     * @notice Batch grant role to multiple accounts
     */
    function batchGrantRole(bytes32 role, address[] calldata accounts) external onlyRole(getRoleAdmin(role)) {
        for (uint256 i = 0; i < accounts.length; i++) {
            grantRole(role, accounts[i]);
        }
    }

    /**
     * @notice Batch revoke role from multiple accounts
     */
    function batchRevokeRole(bytes32 role, address[] calldata accounts) external onlyRole(getRoleAdmin(role)) {
        for (uint256 i = 0; i < accounts.length; i++) {
            revokeRole(role, accounts[i]);
        }
    }

    // ============ QUERY FUNCTIONS ============
    /**
     * @notice Get timestamp when role was granted
     */
    function getRoleGrantedTimestamp(address account, bytes32 role) external view returns (uint256) {
        return _roleGrantedTimestamp[account][role];
    }

    /**
     * @notice Get timestamp when role was revoked
     */
    function getRoleRevokedTimestamp(address account, bytes32 role) external view returns (uint256) {
        return _roleRevokedTimestamp[account][role];
    }

    /**
     * @notice Get all roles for an account
     */
    function getUserRoles(address account) external view returns (bytes32[] memory) {
        return _userRoles[account];
    }

    /**
     * @notice Get all members of a role
     */
    function getRoleMembers(bytes32 role) external view returns (address[] memory) {
        return _roleMembers[role];
    }

    /**
     * @notice Get role member count
     */
    function getRoleMemberCount(bytes32 role) external view returns (uint256) {
        return _roleMembers[role].length;
    }

    /**
     * @notice Check if account has any supply chain role
     */
    function hasSupplyChainRole(address account) external view returns (bool) {
        return hasRole(FARMER_ROLE, account) ||
               hasRole(PROCESSOR_ROLE, account) ||
               hasRole(DISTRIBUTOR_ROLE, account) ||
               hasRole(RETAILER_ROLE, account);
    }

    /**
     * @notice Check if account has administrative privileges
     */
    function hasAdminPrivileges(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account) ||
               hasRole(AUDITOR_ROLE, account) ||
               hasRole(EMERGENCY_ROLE, account);
    }

    /**
     * @notice Get role creation timestamp
     */
    function getRoleCreatedTimestamp(bytes32 role) external view returns (uint256) {
        return _roleCreatedTimestamp[role];
    }

    // ============ STAKEHOLDER TYPE MAPPING ============
    /**
     * @notice Get role for stakeholder type
     */
    function getStakeholderRole(uint8 stakeholderType) external pure returns (bytes32) {
        if (stakeholderType == 0) return FARMER_ROLE;
        if (stakeholderType == 1) return PROCESSOR_ROLE;
        if (stakeholderType == 2) return DISTRIBUTOR_ROLE;
        if (stakeholderType == 3) return RETAILER_ROLE;
        if (stakeholderType == 4) return CONSUMER_ROLE;
        if (stakeholderType == 5) return AUDITOR_ROLE;
        if (stakeholderType == 6) return DEFAULT_ADMIN_ROLE;
        revert("AccessControl: Invalid stakeholder type");
    }

    /**
     * @notice Check if account can modify product in specific stage
     */
    function canModifyProductStage(address account, uint8 stage) external view returns (bool) {
        if (stage == 0 || stage == 1) return hasRole(FARMER_ROLE, account); // PLANTED, GROWING
        if (stage == 2) return hasRole(FARMER_ROLE, account); // HARVESTED
        if (stage == 3) return hasRole(PROCESSOR_ROLE, account); // PROCESSED
        if (stage == 4) return hasRole(PROCESSOR_ROLE, account) || hasRole(DISTRIBUTOR_ROLE, account); // PACKAGED
        if (stage == 5) return hasRole(DISTRIBUTOR_ROLE, account); // SHIPPED
        if (stage == 6) return hasRole(DISTRIBUTOR_ROLE, account) || hasRole(RETAILER_ROLE, account); // DELIVERED
        if (stage == 7) return hasRole(RETAILER_ROLE, account); // SOLD
        return false;
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Add role to user's role list
     */
    function _addUserRole(address account, bytes32 role) internal {
        bytes32[] storage userRoles = _userRoles[account];
        for (uint256 i = 0; i < userRoles.length; i++) {
            if (userRoles[i] == role) return; // Role already exists
        }
        userRoles.push(role);
    }

    /**
     * @dev Remove role from user's role list
     */
    function _removeUserRole(address account, bytes32 role) internal {
        bytes32[] storage userRoles = _userRoles[account];
        for (uint256 i = 0; i < userRoles.length; i++) {
            if (userRoles[i] == role) {
                userRoles[i] = userRoles[userRoles.length - 1];
                userRoles.pop();
                break;
            }
        }
    }

    /**
     * @dev Add member to role's member list
     */
    function _addRoleMember(bytes32 role, address account) internal {
        address[] storage roleMembers = _roleMembers[role];
        for (uint256 i = 0; i < roleMembers.length; i++) {
            if (roleMembers[i] == account) return; // Member already exists
        }
        roleMembers.push(account);
    }

    /**
     * @dev Remove member from role's member list
     */
    function _removeRoleMember(bytes32 role, address account) internal {
        address[] storage roleMembers = _roleMembers[role];
        for (uint256 i = 0; i < roleMembers.length; i++) {
            if (roleMembers[i] == account) {
                roleMembers[i] = roleMembers[roleMembers.length - 1];
                roleMembers.pop();
                break;
            }
        }
    }

    // ============ EMERGENCY FUNCTIONS ============
    /**
     * @notice Emergency role revocation
     */
    function emergencyRevokeRole(bytes32 role, address account, string calldata reason) 
        external 
        onlyRole(EMERGENCY_ROLE) {
        
        super.revokeRole(role, account);
        _roleRevokedTimestamp[account][role] = block.timestamp;
        _removeUserRole(account, role);
        _removeRoleMember(role, account);
        
        emit RoleRevokedWithTimestamp(role, account, msg.sender, block.timestamp);
    }

    /**
     * @notice Emergency batch role revocation
     */
    function emergencyBatchRevokeRole(
        bytes32 role, 
        address[] calldata accounts, 
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            // Directly implement the emergency revocation logic instead of calling emergencyRevokeRole
            super.revokeRole(role, accounts[i]);
            _roleRevokedTimestamp[accounts[i]][role] = block.timestamp;
            _removeUserRole(accounts[i], role);
            _removeRoleMember(role, accounts[i]);
            
            emit RoleRevokedWithTimestamp(role, accounts[i], msg.sender, block.timestamp);
        }
    }
}