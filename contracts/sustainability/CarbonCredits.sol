// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";
import "../interfaces/IStakeholder.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title CarbonCredits
 * @dev Carbon credit minting and trading for sustainable farming
 * @author AgriTrace Team
 */
contract CarbonCredits is ERC20, AgriAccessControl {

    // ============ EVENTS ============
    event CarbonCreditMinted(
        address indexed farmer,
        uint256 indexed productId,
        uint256 amount,
        bytes32 verificationHash,
        uint256 timestamp
    );

    event CarbonCreditTraded(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 price,
        uint256 timestamp
    );

    event CarbonCreditRetired(
        address indexed owner,
        uint256 amount,
        string purpose,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct CarbonCredit {
        uint256 creditId;
        address farmer;
        uint256 productId;
        uint256 amount; // in tons CO2e
        bytes32 verificationHash;
        bytes32 methodologyHash;
        uint256 mintedAt;
        bool isRetired;
        string vintageYear;
    }

    struct TradingOrder {
        address seller;
        uint256 amount;
        uint256 pricePerCredit;
        bytes32 orderHash;
        uint256 createdAt;
        bool isActive;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => CarbonCredit) private _carbonCredits;
    mapping(address => uint256[]) private _farmerCredits;
    mapping(address => TradingOrder[]) private _tradingOrders;
    mapping(uint256 => bool) private _retiredCredits;
    
    IStakeholder public stakeholderContract;
    uint256 private _creditIdCounter;
    uint256 public totalRetired;

    // ============ MODIFIERS ============
    modifier onlyVerifiedFarmer() {
        require(
            hasRole(FARMER_ROLE, msg.sender) &&
            (address(stakeholderContract) == address(0) || stakeholderContract.isVerifiedAndIntact(msg.sender)),
            "CarbonCredits: Not verified farmer"
        );
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() ERC20("AgriTrace Carbon Credits", "ATCC") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _creditIdCounter = 0;
    }

    // ============ SETUP FUNCTIONS ============
    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    // ============ MINTING FUNCTIONS ============
    function mintCarbonCredits(
        uint256 productId,
        uint256 amount,
        bytes32 verificationHash,
        bytes32 methodologyHash,
        string calldata vintageYear
    ) external onlyVerifiedFarmer returns (uint256 creditId) {
        require(productId > 0, "CarbonCredits: Invalid product ID");
        require(amount > 0, "CarbonCredits: Invalid amount");
        require(verificationHash != bytes32(0), "CarbonCredits: Verification hash required");
        require(methodologyHash != bytes32(0), "CarbonCredits: Methodology hash required");

        _creditIdCounter++;
        creditId = _creditIdCounter;

        _carbonCredits[creditId] = CarbonCredit({
            creditId: creditId,
            farmer: msg.sender,
            productId: productId,
            amount: amount,
            verificationHash: verificationHash,
            methodologyHash: methodologyHash,
            mintedAt: block.timestamp,
            isRetired: false,
            vintageYear: vintageYear
        });

        _farmerCredits[msg.sender].push(creditId);
        _mint(msg.sender, amount * 1e18); // 1 token = 1 ton CO2e

        emit CarbonCreditMinted(msg.sender, productId, amount, verificationHash, block.timestamp);
        return creditId;
    }

    // ============ TRADING FUNCTIONS ============
    function createTradingOrder(
        uint256 amount,
        uint256 pricePerCredit,
        bytes32 orderHash
    ) external returns (uint256 orderId) {
        require(amount > 0, "CarbonCredits: Invalid amount");
        require(pricePerCredit > 0, "CarbonCredits: Invalid price");
        require(balanceOf(msg.sender) >= amount * 1e18, "CarbonCredits: Insufficient balance");

        TradingOrder memory order = TradingOrder({
            seller: msg.sender,
            amount: amount,
            pricePerCredit: pricePerCredit,
            orderHash: orderHash,
            createdAt: block.timestamp,
            isActive: true
        });

        _tradingOrders[msg.sender].push(order);
        return _tradingOrders[msg.sender].length - 1;
    }

    function executeTrade(address seller, uint256 orderIndex) external payable {
        require(orderIndex < _tradingOrders[seller].length, "CarbonCredits: Invalid order");
        
        TradingOrder storage order = _tradingOrders[seller][orderIndex];
        require(order.isActive, "CarbonCredits: Order not active");
        
        uint256 totalPrice = order.amount * order.pricePerCredit;
        require(msg.value >= totalPrice, "CarbonCredits: Insufficient payment");

        order.isActive = false;
        
        // Transfer credits
        _transfer(seller, msg.sender, order.amount * 1e18);
        
        // Transfer payment
        (bool success, ) = payable(seller).call{value: totalPrice}("");
        require(success, "CarbonCredits: Payment failed");

        // Refund excess
        if (msg.value > totalPrice) {
            (bool refundSuccess, ) = payable(msg.sender).call{value: msg.value - totalPrice}("");
            require(refundSuccess, "CarbonCredits: Refund failed");
        }

        emit CarbonCreditTraded(seller, msg.sender, order.amount, order.pricePerCredit, block.timestamp);
    }

    // ============ RETIREMENT FUNCTIONS ============
    function retireCredits(uint256 amount, string calldata purpose) external {
        require(amount > 0, "CarbonCredits: Invalid amount");
        require(balanceOf(msg.sender) >= amount * 1e18, "CarbonCredits: Insufficient balance");
        require(bytes(purpose).length > 0, "CarbonCredits: Purpose required");

        _burn(msg.sender, amount * 1e18);
        totalRetired += amount;

        emit CarbonCreditRetired(msg.sender, amount, purpose, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    function getCarbonCredit(uint256 creditId) external view returns (CarbonCredit memory) {
        return _carbonCredits[creditId];
    }

    function getFarmerCredits(address farmer) external view returns (uint256[] memory) {
        return _farmerCredits[farmer];
    }

    function getTradingOrders(address seller) external view returns (TradingOrder[] memory) {
        return _tradingOrders[seller];
    }

    function getActiveTradingOrders(address seller) external view returns (TradingOrder[] memory) {
        TradingOrder[] memory allOrders = _tradingOrders[seller];
        TradingOrder[] memory temp = new TradingOrder[](allOrders.length);
        uint256 count = 0;

        for (uint256 i = 0; i < allOrders.length; i++) {
            if (allOrders[i].isActive) {
                temp[count] = allOrders[i];
                count++;
            }
        }

        TradingOrder[] memory result = new TradingOrder[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }

        return result;
    }

    function verifyCredit(uint256 creditId, bytes32 currentVerificationHash) external view returns (bool) {
        return _carbonCredits[creditId].verificationHash == currentVerificationHash;
    }

    // ============ ADMIN FUNCTIONS ============
    function verifyCarbonCredit(uint256 creditId) external onlyRole(AUDITOR_ROLE) {
        require(_carbonCredits[creditId].creditId != 0, "CarbonCredits: Credit not found");
        // Additional verification logic can be added
    }

    function cancelTradingOrder(address seller, uint256 orderIndex) external onlyRole(AUDITOR_ROLE) {
        require(orderIndex < _tradingOrders[seller].length, "CarbonCredits: Invalid order");
        _tradingOrders[seller][orderIndex].isActive = false;
    }
}
