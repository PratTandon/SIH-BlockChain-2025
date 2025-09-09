// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";
import "../interfaces/IStakeholder.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title EscrowService
 * @dev Secure payment handling for agricultural trades
 * @author AgriTrace Team
 */
contract EscrowService is AgriAccessControl, ReentrancyGuard {

    // ============ EVENTS ============
    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        bytes32 termsHash,
        uint256 timestamp
    );

    event EscrowFunded(
        bytes32 indexed escrowId,
        address indexed funder,
        uint256 amount,
        uint256 timestamp
    );

    event EscrowReleased(
        bytes32 indexed escrowId,
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );

    event DisputeRaised(
        bytes32 indexed escrowId,
        address indexed initiator,
        string reason,
        uint256 timestamp
    );

    event DisputeResolved(
        bytes32 indexed escrowId,
        address indexed resolver,
        string resolution,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum EscrowStatus {
        CREATED,        // 0 - Escrow created, awaiting funding
        FUNDED,         // 1 - Funds deposited
        COMPLETED,      // 2 - Successfully completed
        DISPUTED,       // 3 - Under dispute
        CANCELLED,      // 4 - Cancelled
        REFUNDED        // 5 - Funds refunded
    }

    // ============ STRUCTS ============
    struct Escrow {
        bytes32 escrowId;
        address buyer;
        address seller;
        uint256 amount;
        uint256 depositedAmount;
        bytes32 termsHash;
        bytes32 productDataHash;
        uint256 createdAt;
        uint256 expiresAt;
        EscrowStatus status;
        bool buyerApproval;
        bool sellerApproval;
        address arbitrator;
    }

    struct Dispute {
        bytes32 escrowId;
        address initiator;
        string reason;
        bytes32 evidenceHash;
        uint256 raisedAt;
        address resolver;
        string resolution;
        uint256 resolvedAt;
        bool isResolved;
    }

    // ============ STATE VARIABLES ============
    mapping(bytes32 => Escrow) private _escrows;
    mapping(bytes32 => Dispute) private _disputes;
    mapping(address => bytes32[]) private _userEscrows;
    mapping(address => bool) private _authorizedArbitrators;
    
    IStakeholder public stakeholderContract;
    
    uint256 public constant ESCROW_TIMEOUT = 30 days;
    uint256 public constant DISPUTE_TIMEOUT = 7 days;
    uint256 public platformFeeRate = 250; // 2.5% in basis points

    // ============ MODIFIERS ============
    modifier escrowExists(bytes32 escrowId) {
        require(_escrows[escrowId].escrowId != bytes32(0), "EscrowService: Escrow not found");
        _;
    }

    modifier onlyEscrowParty(bytes32 escrowId) {
        Escrow memory escrow = _escrows[escrowId];
        require(
            msg.sender == escrow.buyer || 
            msg.sender == escrow.seller ||
            hasRole(AUDITOR_ROLE, msg.sender),
            "EscrowService: Not authorized"
        );
        _;
    }

    modifier onlyArbitrator() {
        require(
            _authorizedArbitrators[msg.sender] || 
            hasRole(AUDITOR_ROLE, msg.sender),
            "EscrowService: Not authorized arbitrator"
        );
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============ SETUP FUNCTIONS ============
    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    function addArbitrator(address arbitrator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _authorizedArbitrators[arbitrator] = true;
    }

    function removeArbitrator(address arbitrator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _authorizedArbitrators[arbitrator] = false;
    }

    // ============ ESCROW FUNCTIONS ============
    function createEscrow(
        address seller,
        uint256 amount,
        bytes32 termsHash,
        bytes32 productDataHash,
        uint256 expirationDays
    ) external payable nonReentrant returns (bytes32 escrowId) {
        require(seller != address(0) && seller != msg.sender, "EscrowService: Invalid seller");
        require(amount > 0, "EscrowService: Invalid amount");
        require(termsHash != bytes32(0), "EscrowService: Terms hash required");
        require(productDataHash != bytes32(0), "EscrowService: Product data hash required");
        require(expirationDays > 0 && expirationDays <= 90, "EscrowService: Invalid expiration");

        // Verify stakeholders
        if (address(stakeholderContract) != address(0)) {
            require(stakeholderContract.isVerifiedAndIntact(msg.sender), "EscrowService: Buyer not verified");
            require(stakeholderContract.isVerifiedAndIntact(seller), "EscrowService: Seller not verified");
        }

        escrowId = keccak256(abi.encodePacked(
            msg.sender,
            seller,
            amount,
            block.timestamp
        ));

        _escrows[escrowId] = Escrow({
            escrowId: escrowId,
            buyer: msg.sender,
            seller: seller,
            amount: amount,
            depositedAmount: msg.value,
            termsHash: termsHash,
            productDataHash: productDataHash,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + (expirationDays * 1 days),
            status: msg.value >= amount ? EscrowStatus.FUNDED : EscrowStatus.CREATED,
            buyerApproval: false,
            sellerApproval: false,
            arbitrator: address(0)
        });

        _userEscrows[msg.sender].push(escrowId);
        _userEscrows[seller].push(escrowId);

        emit EscrowCreated(escrowId, msg.sender, seller, amount, termsHash, block.timestamp);
        
        if (msg.value > 0) {
            emit EscrowFunded(escrowId, msg.sender, msg.value, block.timestamp);
        }

        return escrowId;
    }

    function fundEscrow(bytes32 escrowId) 
        external 
        payable 
        nonReentrant 
        escrowExists(escrowId) {
        
        Escrow storage escrow = _escrows[escrowId];
        require(msg.sender == escrow.buyer, "EscrowService: Only buyer can fund");
        require(escrow.status == EscrowStatus.CREATED, "EscrowService: Invalid status for funding");
        require(block.timestamp <= escrow.expiresAt, "EscrowService: Escrow expired");

        escrow.depositedAmount += msg.value;

        if (escrow.depositedAmount >= escrow.amount) {
            escrow.status = EscrowStatus.FUNDED;
        }

        emit EscrowFunded(escrowId, msg.sender, msg.value, block.timestamp);
    }

    function approveEscrow(bytes32 escrowId) 
        external 
        escrowExists(escrowId) 
        onlyEscrowParty(escrowId) {
        
        Escrow storage escrow = _escrows[escrowId];
        require(escrow.status == EscrowStatus.FUNDED, "EscrowService: Escrow not funded");

        if (msg.sender == escrow.buyer) {
            escrow.buyerApproval = true;
        } else if (msg.sender == escrow.seller) {
            escrow.sellerApproval = true;
        }

        // Release funds if both parties approve
        if (escrow.buyerApproval && escrow.sellerApproval) {
            _releaseEscrow(escrowId);
        }
    }

    function raiseDispute(
        bytes32 escrowId,
        string calldata reason,
        bytes32 evidenceHash
    ) external escrowExists(escrowId) onlyEscrowParty(escrowId) {
        require(bytes(reason).length > 0, "EscrowService: Reason required");
        require(evidenceHash != bytes32(0), "EscrowService: Evidence hash required");

        Escrow storage escrow = _escrows[escrowId];
        require(escrow.status == EscrowStatus.FUNDED, "EscrowService: Invalid status for dispute");

        escrow.status = EscrowStatus.DISPUTED;

        _disputes[escrowId] = Dispute({
            escrowId: escrowId,
            initiator: msg.sender,
            reason: reason,
            evidenceHash: evidenceHash,
            raisedAt: block.timestamp,
            resolver: address(0),
            resolution: "",
            resolvedAt: 0,
            isResolved: false
        });

        emit DisputeRaised(escrowId, msg.sender, reason, block.timestamp);
    }

    function resolveDispute(
        bytes32 escrowId,
        string calldata resolution,
        bool releaseToBuyer
    ) external escrowExists(escrowId) onlyArbitrator {
        require(bytes(resolution).length > 0, "EscrowService: Resolution required");

        Escrow storage escrow = _escrows[escrowId];
        require(escrow.status == EscrowStatus.DISPUTED, "EscrowService: Not disputed");

        Dispute storage dispute = _disputes[escrowId];
        dispute.resolver = msg.sender;
        dispute.resolution = resolution;
        dispute.resolvedAt = block.timestamp;
        dispute.isResolved = true;

        if (releaseToBuyer) {
            _refundEscrow(escrowId);
        } else {
            _releaseEscrow(escrowId);
        }

        emit DisputeResolved(escrowId, msg.sender, resolution, block.timestamp);
    }

    function cancelEscrow(bytes32 escrowId) 
        external 
        escrowExists(escrowId) 
        onlyEscrowParty(escrowId) {
        
        Escrow storage escrow = _escrows[escrowId];
        require(
            escrow.status == EscrowStatus.CREATED || 
            (escrow.status == EscrowStatus.FUNDED && block.timestamp > escrow.expiresAt),
            "EscrowService: Cannot cancel"
        );

        escrow.status = EscrowStatus.CANCELLED;

        if (escrow.depositedAmount > 0) {
            _refundEscrow(escrowId);
        }
    }

    // ============ VIEW FUNCTIONS ============
    function getEscrow(bytes32 escrowId) external view escrowExists(escrowId) returns (Escrow memory) {
        return _escrows[escrowId];
    }

    function getDispute(bytes32 escrowId) external view returns (Dispute memory) {
        return _disputes[escrowId];
    }

    function getUserEscrows(address user) external view returns (bytes32[] memory) {
        return _userEscrows[user];
    }

    function verifyEscrowIntegrity(
        bytes32 escrowId,
        bytes32 currentTermsHash,
        bytes32 currentProductHash
    ) external view escrowExists(escrowId) returns (bool) {
        Escrow memory escrow = _escrows[escrowId];
        return escrow.termsHash == currentTermsHash && escrow.productDataHash == currentProductHash;
    }

    function calculatePlatformFee(uint256 amount) external view returns (uint256) {
        return (amount * platformFeeRate) / 10000;
    }

    // ============ ADMIN FUNCTIONS ============
    function setPlatformFeeRate(uint256 newFeeRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeeRate <= 1000, "EscrowService: Fee rate too high"); // Max 10%
        platformFeeRate = newFeeRate;
    }

    function emergencyReleaseEscrow(
        bytes32 escrowId,
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) escrowExists(escrowId) {
        require(bytes(reason).length > 0, "EscrowService: Reason required");
        _releaseEscrow(escrowId);
    }

    function emergencyRefundEscrow(
        bytes32 escrowId,
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) escrowExists(escrowId) {
        require(bytes(reason).length > 0, "EscrowService: Reason required");
        _refundEscrow(escrowId);
    }

    // ============ INTERNAL FUNCTIONS ============
    function _releaseEscrow(bytes32 escrowId) internal {
        Escrow storage escrow = _escrows[escrowId];
        require(escrow.depositedAmount > 0, "EscrowService: No funds to release");

        uint256 platformFee = this.calculatePlatformFee(escrow.depositedAmount);
        uint256 sellerAmount = escrow.depositedAmount - platformFee;

        escrow.status = EscrowStatus.COMPLETED;

        // Transfer to seller
        (bool success, ) = payable(escrow.seller).call{value: sellerAmount}("");
        require(success, "EscrowService: Transfer to seller failed");

        // Platform fee (if any)
        if (platformFee > 0) {
            // Platform fee handling (could be sent to treasury)
        }

        emit EscrowReleased(escrowId, escrow.seller, sellerAmount, block.timestamp);
    }

    function _refundEscrow(bytes32 escrowId) internal {
        Escrow storage escrow = _escrows[escrowId];
        require(escrow.depositedAmount > 0, "EscrowService: No funds to refund");

        uint256 refundAmount = escrow.depositedAmount;
        escrow.status = EscrowStatus.REFUNDED;

        // Transfer back to buyer
        (bool success, ) = payable(escrow.buyer).call{value: refundAmount}("");
        require(success, "EscrowService: Refund to buyer failed");

        emit EscrowReleased(escrowId, escrow.buyer, refundAmount, block.timestamp);
    }
}
