// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";
import "../interfaces/IStakeholder.sol";
import "../libraries/DateTimeLib.sol";

/**
 * @title ContractFarming
 * @dev Forward contracts for agricultural products
 * @author AgriTrace Team
 */
contract ContractFarming is AgriAccessControl {
    using DateTimeLib for uint256;

    // ============ EVENTS ============
    event ContractCreated(
        bytes32 indexed contractId,
        address indexed farmer,
        address indexed buyer,
        string productType,
        uint256 quantity,
        uint256 pricePerUnit,
        uint256 deliveryDate,
        uint256 timestamp
    );

    event ContractAccepted(
        bytes32 indexed contractId,
        address indexed acceptor,
        uint256 timestamp
    );

    event ContractFulfilled(
        bytes32 indexed contractId,
        uint256 deliveredQuantity,
        uint256 timestamp
    );

    event ContractBreached(
        bytes32 indexed contractId,
        address indexed breacher,
        string reason,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum ContractStatus {
        PROPOSED,    // 0 - Contract proposed, awaiting acceptance
        ACTIVE,      // 1 - Contract accepted and active
        FULFILLED,   // 2 - Contract successfully completed
        BREACHED,    // 3 - Contract breached by one party
        CANCELLED,   // 4 - Contract cancelled before acceptance
        EXPIRED      // 5 - Contract expired
    }

    // ============ STRUCTS ============
    struct FarmingContract {
        bytes32 contractId;
        address farmer;
        address buyer;
        string productType;
        uint256 quantity; // in kg
        uint256 pricePerUnit; // price per kg in wei
        uint256 totalValue;
        bytes32 termsHash;
        bytes32 qualitySpecsHash;
        uint256 createdAt;
        uint256 deliveryDate;
        uint256 expiryDate;
        ContractStatus status;
        bool farmerAccepted;
        bool buyerAccepted;
        uint256 deliveredQuantity;
        uint256 qualityScore;
    }

    struct QualitySpecification {
        uint256 minQualityScore;
        string[] requiredCertifications;
        bytes32 specificationHash;
        bool moistureControl;
        bool pesticidesControl;
        bool organicRequired;
    }

    struct ContractTerms {
        uint256 advancePayment; // percentage in basis points
        uint256 penaltyRate; // penalty percentage for breach
        uint256 qualityBonus; // bonus for exceeding quality
        bool allowPartialDelivery;
        uint256 maxDeliveryDelay; // in days
        bytes32 specialConditions;
    }

    // ============ STATE VARIABLES ============
    mapping(bytes32 => FarmingContract) private _contracts;
    mapping(bytes32 => QualitySpecification) private _qualitySpecs;
    mapping(bytes32 => ContractTerms) private _contractTerms;
    mapping(address => bytes32[]) private _farmerContracts;
    mapping(address => bytes32[]) private _buyerContracts;
    mapping(string => bytes32[]) private _productTypeContracts;
    
    IStakeholder public stakeholderContract;

    uint256 public constant MAX_CONTRACT_DURATION = 365 days;
    uint256 public constant MIN_ADVANCE_PAYMENT = 1000; // 10%
    uint256 public constant MAX_ADVANCE_PAYMENT = 5000; // 50%

    // ============ MODIFIERS ============
    modifier contractExists(bytes32 contractId) {
        require(_contracts[contractId].contractId != bytes32(0), "ContractFarming: Contract not found");
        _;
    }

    modifier onlyContractParty(bytes32 contractId) {
        FarmingContract memory farmContract = _contracts[contractId];
        require(
            msg.sender == farmContract.farmer || 
            msg.sender == farmContract.buyer ||
            hasRole(AUDITOR_ROLE, msg.sender),
            "ContractFarming: Not authorized"
        );
        _;
    }

    modifier validProductType(string calldata productType) {
        require(bytes(productType).length > 0, "ContractFarming: Invalid product type");
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

    // ============ CONTRACT FUNCTIONS ============
    function createFarmingContract(
        address farmer,
        string calldata productType,
        uint256 quantity,
        uint256 pricePerUnit,
        uint256 deliveryDate,
        bytes32 termsHash,
        bytes32 qualitySpecsHash
    ) external validProductType(productType) returns (bytes32 contractId) {
        require(farmer != address(0) && farmer != msg.sender, "ContractFarming: Invalid farmer");
        require(quantity > 0, "ContractFarming: Invalid quantity");
        require(pricePerUnit > 0, "ContractFarming: Invalid price");
        require(deliveryDate > block.timestamp, "ContractFarming: Invalid delivery date");
        require(deliveryDate <= block.timestamp + MAX_CONTRACT_DURATION, "ContractFarming: Delivery date too far");
        require(termsHash != bytes32(0), "ContractFarming: Terms hash required");
        require(qualitySpecsHash != bytes32(0), "ContractFarming: Quality specs hash required");

        // Verify stakeholders
        if (address(stakeholderContract) != address(0)) {
            require(stakeholderContract.isVerifiedAndIntact(msg.sender), "ContractFarming: Buyer not verified");
            require(stakeholderContract.isVerifiedAndIntact(farmer), "ContractFarming: Farmer not verified");
        }

        contractId = keccak256(abi.encodePacked(
            farmer,
            msg.sender,
            productType,
            quantity,
            block.timestamp
        ));

        uint256 totalValue = quantity * pricePerUnit;

        _contracts[contractId] = FarmingContract({
            contractId: contractId,
            farmer: farmer,
            buyer: msg.sender,
            productType: productType,
            quantity: quantity,
            pricePerUnit: pricePerUnit,
            totalValue: totalValue,
            termsHash: termsHash,
            qualitySpecsHash: qualitySpecsHash,
            createdAt: block.timestamp,
            deliveryDate: deliveryDate,
            expiryDate: deliveryDate + 30 days, // 30 days grace period
            status: ContractStatus.PROPOSED,
            farmerAccepted: false,
            buyerAccepted: true, // Creator automatically accepts
            deliveredQuantity: 0,
            qualityScore: 0
        });

        _farmerContracts[farmer].push(contractId);
        _buyerContracts[msg.sender].push(contractId);
        _productTypeContracts[productType].push(contractId);

        emit ContractCreated(
            contractId, 
            farmer, 
            msg.sender, 
            productType, 
            quantity, 
            pricePerUnit, 
            deliveryDate, 
            block.timestamp
        );

        return contractId;
    }

    function acceptContract(bytes32 contractId) 
        external 
        contractExists(contractId) 
        onlyContractParty(contractId) {
        
        FarmingContract storage farmContract = _contracts[contractId];
        require(farmContract.status == ContractStatus.PROPOSED, "ContractFarming: Contract not in proposed status");

        if (msg.sender == farmContract.farmer) {
            farmContract.farmerAccepted = true;
        } else if (msg.sender == farmContract.buyer) {
            farmContract.buyerAccepted = true;
        }

        if (farmContract.farmerAccepted && farmContract.buyerAccepted) {
            farmContract.status = ContractStatus.ACTIVE;
        }

        emit ContractAccepted(contractId, msg.sender, block.timestamp);
    }

    function fulfillContract(
        bytes32 contractId,
        uint256 deliveredQuantity,
        uint256 qualityScore,
        bytes32 deliveryEvidenceHash
    ) external contractExists(contractId) onlyContractParty(contractId) {
        require(deliveryEvidenceHash != bytes32(0), "ContractFarming: Delivery evidence required");
        
        FarmingContract storage farmContract = _contracts[contractId];
        require(farmContract.status == ContractStatus.ACTIVE, "ContractFarming: Contract not active");
        require(msg.sender == farmContract.farmer, "ContractFarming: Only farmer can fulfill");
        require(deliveredQuantity > 0, "ContractFarming: Invalid delivered quantity");
        require(qualityScore <= 1000, "ContractFarming: Invalid quality score");

        farmContract.deliveredQuantity = deliveredQuantity;
        farmContract.qualityScore = qualityScore;

        // Check if contract is fulfilled
        ContractTerms memory terms = _contractTerms[contractId];
        if (deliveredQuantity >= farmContract.quantity || 
            (terms.allowPartialDelivery && deliveredQuantity >= farmContract.quantity * 8000 / 10000)) { // 80% minimum
            farmContract.status = ContractStatus.FULFILLED;
        }

        emit ContractFulfilled(contractId, deliveredQuantity, block.timestamp);
    }

    function reportBreach(
        bytes32 contractId,
        string calldata reason,
        bytes32 evidenceHash
    ) external contractExists(contractId) onlyContractParty(contractId) {
        require(bytes(reason).length > 0, "ContractFarming: Reason required");
        require(evidenceHash != bytes32(0), "ContractFarming: Evidence required");

        FarmingContract storage farmContract = _contracts[contractId];
        require(farmContract.status == ContractStatus.ACTIVE, "ContractFarming: Contract not active");

        farmContract.status = ContractStatus.BREACHED;

        emit ContractBreached(contractId, msg.sender, reason, block.timestamp);
    }

    function cancelContract(bytes32 contractId) 
        external 
        contractExists(contractId) 
        onlyContractParty(contractId) {
        
        FarmingContract storage farmContract = _contracts[contractId];
        require(farmContract.status == ContractStatus.PROPOSED, "ContractFarming: Cannot cancel active contract");

        farmContract.status = ContractStatus.CANCELLED;
    }

    function setContractTerms(
        bytes32 contractId,
        ContractTerms calldata terms
    ) external contractExists(contractId) onlyContractParty(contractId) {
        require(terms.advancePayment >= MIN_ADVANCE_PAYMENT, "ContractFarming: Advance payment too low");
        require(terms.advancePayment <= MAX_ADVANCE_PAYMENT, "ContractFarming: Advance payment too high");
        require(terms.penaltyRate <= 5000, "ContractFarming: Penalty rate too high"); // Max 50%

        FarmingContract memory farmContract = _contracts[contractId];
        require(farmContract.status == ContractStatus.PROPOSED, "ContractFarming: Cannot modify active contract");

        _contractTerms[contractId] = terms;
    }

    function setQualitySpecification(
        bytes32 contractId,
        QualitySpecification calldata specs
    ) external contractExists(contractId) onlyContractParty(contractId) {
        require(specs.minQualityScore <= 1000, "ContractFarming: Invalid quality score");

        FarmingContract memory farmContract = _contracts[contractId];
        require(farmContract.status == ContractStatus.PROPOSED, "ContractFarming: Cannot modify active contract");

        _qualitySpecs[contractId] = specs;
    }

    // ============ VIEW FUNCTIONS ============
    function getContract(bytes32 contractId) 
        external view 
        contractExists(contractId) 
        returns (FarmingContract memory) {
        return _contracts[contractId];
    }

    function getContractTerms(bytes32 contractId) external view returns (ContractTerms memory) {
        return _contractTerms[contractId];
    }

    function getQualitySpecification(bytes32 contractId) external view returns (QualitySpecification memory) {
        return _qualitySpecs[contractId];
    }

    function getFarmerContracts(address farmer) external view returns (bytes32[] memory) {
        return _farmerContracts[farmer];
    }

    function getBuyerContracts(address buyer) external view returns (bytes32[] memory) {
        return _buyerContracts[buyer];
    }

    function getProductTypeContracts(string calldata productType) external view returns (bytes32[] memory) {
        return _productTypeContracts[productType];
    }

    function verifyContractIntegrity(
        bytes32 contractId,
        bytes32 currentTermsHash,
        bytes32 currentSpecsHash
    ) external view contractExists(contractId) returns (bool) {
        FarmingContract memory farmContract = _contracts[contractId];
        return farmContract.termsHash == currentTermsHash && 
               farmContract.qualitySpecsHash == currentSpecsHash;
    }

    function getActiveContracts(address party) external view returns (bytes32[] memory) {
        bytes32[] memory farmerContracts = _farmerContracts[party];
        bytes32[] memory buyerContracts = _buyerContracts[party];
        
        bytes32[] memory temp = new bytes32[](farmerContracts.length + buyerContracts.length);
        uint256 count = 0;

        for (uint256 i = 0; i < farmerContracts.length; i++) {
            if (_contracts[farmerContracts[i]].status == ContractStatus.ACTIVE) {
                temp[count] = farmerContracts[i];
                count++;
            }
        }

        for (uint256 i = 0; i < buyerContracts.length; i++) {
            if (_contracts[buyerContracts[i]].status == ContractStatus.ACTIVE) {
                temp[count] = buyerContracts[i];
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
    function forceContractCompletion(
        bytes32 contractId,
        string calldata reason
    ) external onlyRole(AUDITOR_ROLE) contractExists(contractId) {
        require(bytes(reason).length > 0, "ContractFarming: Reason required");

        FarmingContract storage farmContract = _contracts[contractId];
        farmContract.status = ContractStatus.FULFILLED;
    }

    function expireOldContracts(bytes32[] calldata contractIds) external onlyRole(AUDITOR_ROLE) {
        for (uint256 i = 0; i < contractIds.length; i++) {
            FarmingContract storage farmContract = _contracts[contractIds[i]];
            if (farmContract.contractId != bytes32(0) && 
                block.timestamp > farmContract.expiryDate &&
                farmContract.status == ContractStatus.ACTIVE) {
                farmContract.status = ContractStatus.EXPIRED;
            }
        }
    }
}
