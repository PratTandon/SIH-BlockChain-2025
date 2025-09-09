// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IStakeholder.sol";
import "../core/AgriAccessControl.sol";

/**
 * @title TransferProtocol
 * @dev Custody transfer rules and verification
 * @author AgriTrace Team
 */
contract TransferProtocol is AgriAccessControl {

    // ============ EVENTS ============
    event TransferInitiated(
        uint256 indexed productId,
        address indexed from,
        address indexed to,
        bytes32 transferHash,
        uint256 timestamp
    );

    event TransferCompleted(
        uint256 indexed productId,
        bytes32 indexed transferId,
        uint256 timestamp
    );

    event TransferRejected(
        uint256 indexed productId,
        bytes32 indexed transferId,
        string reason,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum TransferStatus {
        INITIATED,  // 0
        ACCEPTED,   // 1
        REJECTED,   // 2
        COMPLETED   // 3
    }

    // ============ STRUCTS ============
    struct Transfer {
        bytes32 transferId;
        uint256 productId;
        address from;
        address to;
        uint8 fromStage;
        uint8 toStage;
        bytes32 transferDataHash;
        bytes32 conditionsHash;
        uint256 initiatedAt;
        uint256 completedAt;
        TransferStatus status;
        bool requiresVerification;
    }

    struct TransferConditions {
        bool qualityCheck;
        bool temperatureLog;
        bool quantityVerification;
        uint256 maxTransferTime;
        bytes32 specialInstructions;
    }

    // ============ STATE VARIABLES ============
    mapping(bytes32 => Transfer) private _transfers;
    mapping(uint256 => bytes32[]) private _productTransfers;
    mapping(address => bytes32[]) private _stakeholderTransfers;
    
    IStakeholder public stakeholderContract;

    // ============ MODIFIERS ============
    modifier transferExists(bytes32 transferId) {
        require(_transfers[transferId].transferId != bytes32(0), "TransferProtocol: Transfer not found");
        _;
    }

    modifier onlyTransferParticipant(bytes32 transferId) {
        Transfer memory transfer = _transfers[transferId];
        require(
            msg.sender == transfer.from || 
            msg.sender == transfer.to ||
            hasRole(AUDITOR_ROLE, msg.sender),
            "TransferProtocol: Not authorized"
        );
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============ SETUP FUNCTIONS ============
    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakeholderContract != address(0), "TransferProtocol: Invalid stakeholder contract");
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    // ============ TRANSFER FUNCTIONS ============
    function initiateTransfer(
        uint256 productId,
        address to,
        uint8 fromStage,
        uint8 toStage,
        bytes32 transferDataHash,
        bytes32 conditionsHash,
        bool requiresVerification
    ) external returns (bytes32 transferId) {
        require(productId > 0, "TransferProtocol: Invalid product ID");
        require(to != address(0) && to != msg.sender, "TransferProtocol: Invalid recipient");
        require(transferDataHash != bytes32(0), "TransferProtocol: Transfer data hash required");
        
        // Verify stakeholders
        if (address(stakeholderContract) != address(0)) {
            require(stakeholderContract.isVerifiedAndIntact(msg.sender), "TransferProtocol: Sender not verified");
            require(stakeholderContract.isVerifiedAndIntact(to), "TransferProtocol: Recipient not verified");
        }

        transferId = keccak256(abi.encodePacked(
            productId,
            msg.sender,
            to,
            block.timestamp
        ));

        _transfers[transferId] = Transfer({
            transferId: transferId,
            productId: productId,
            from: msg.sender,
            to: to,
            fromStage: fromStage,
            toStage: toStage,
            transferDataHash: transferDataHash,
            conditionsHash: conditionsHash,
            initiatedAt: block.timestamp,
            completedAt: 0,
            status: TransferStatus.INITIATED,
            requiresVerification: requiresVerification
        });

        _productTransfers[productId].push(transferId);
        _stakeholderTransfers[msg.sender].push(transferId);
        _stakeholderTransfers[to].push(transferId);

        emit TransferInitiated(productId, msg.sender, to, transferDataHash, block.timestamp);
        return transferId;
    }

    function acceptTransfer(bytes32 transferId) 
        external 
        transferExists(transferId) 
        onlyTransferParticipant(transferId) {
        
        Transfer storage transfer = _transfers[transferId];
        require(msg.sender == transfer.to, "TransferProtocol: Only recipient can accept");
        require(transfer.status == TransferStatus.INITIATED, "TransferProtocol: Invalid status");

        transfer.status = TransferStatus.ACCEPTED;
    }

    function completeTransfer(
        bytes32 transferId,
        bytes32 completionDataHash
    ) external transferExists(transferId) onlyTransferParticipant(transferId) {
        require(completionDataHash != bytes32(0), "TransferProtocol: Completion data hash required");
        
        Transfer storage transfer = _transfers[transferId];
        require(transfer.status == TransferStatus.ACCEPTED, "TransferProtocol: Transfer not accepted");

        if (transfer.requiresVerification && !hasRole(AUDITOR_ROLE, msg.sender)) {
            revert("TransferProtocol: Verification required");
        }

        transfer.status = TransferStatus.COMPLETED;
        transfer.completedAt = block.timestamp;

        emit TransferCompleted(transfer.productId, transferId, block.timestamp);
    }

    function rejectTransfer(
        bytes32 transferId,
        string calldata reason
    ) external transferExists(transferId) onlyTransferParticipant(transferId) {
        require(bytes(reason).length > 0, "TransferProtocol: Reason required");
        
        Transfer storage transfer = _transfers[transferId];
        require(transfer.status == TransferStatus.INITIATED, "TransferProtocol: Cannot reject");
        require(msg.sender == transfer.to, "TransferProtocol: Only recipient can reject");

        transfer.status = TransferStatus.REJECTED;

        emit TransferRejected(transfer.productId, transferId, reason, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    function getTransfer(bytes32 transferId) 
        external view 
        transferExists(transferId) 
        returns (Transfer memory) {
        return _transfers[transferId];
    }

    function getProductTransfers(uint256 productId) external view returns (bytes32[] memory) {
        return _productTransfers[productId];
    }

    function getStakeholderTransfers(address stakeholder) external view returns (bytes32[] memory) {
        return _stakeholderTransfers[stakeholder];
    }

    function verifyTransferIntegrity(
        bytes32 transferId,
        bytes32 currentDataHash
    ) external view transferExists(transferId) returns (bool) {
        return _transfers[transferId].transferDataHash == currentDataHash;
    }

    function getPendingTransfers(address stakeholder) external view returns (bytes32[] memory) {
        bytes32[] memory allTransfers = _stakeholderTransfers[stakeholder];
        bytes32[] memory temp = new bytes32[](allTransfers.length);
        uint256 count = 0;

        for (uint256 i = 0; i < allTransfers.length; i++) {
            if (_transfers[allTransfers[i]].status == TransferStatus.INITIATED &&
                _transfers[allTransfers[i]].to == stakeholder) {
                temp[count] = allTransfers[i];
                count++;
            }
        }

        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }

        return result;
    }

    // ============ ADMIN FUNCTIONS ============
    function verifyTransfer(bytes32 transferId) 
        external 
        onlyRole(AUDITOR_ROLE) 
        transferExists(transferId) {
        
        Transfer storage transfer = _transfers[transferId];
        require(transfer.status == TransferStatus.ACCEPTED, "TransferProtocol: Not ready for verification");
        
        transfer.status = TransferStatus.COMPLETED;
        transfer.completedAt = block.timestamp;

        emit TransferCompleted(transfer.productId, transferId, block.timestamp);
    }

    function emergencyRejectTransfer(
        bytes32 transferId,
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) transferExists(transferId) {
        Transfer storage transfer = _transfers[transferId];
        transfer.status = TransferStatus.REJECTED;

        emit TransferRejected(transfer.productId, transferId, reason, block.timestamp);
    }
}
