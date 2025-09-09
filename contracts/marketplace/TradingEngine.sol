// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";
import "../interfaces/IStakeholder.sol";

/**
 * @title TradingEngine
 * @dev Buy/sell order matching for agricultural products
 * @author AgriTrace Team
 */
contract TradingEngine is AgriAccessControl {

    // ============ EVENTS ============
    event OrderCreated(
        bytes32 indexed orderId,
        address indexed creator,
        bool isBuyOrder,
        uint256 productId,
        uint256 quantity,
        uint256 price,
        uint256 timestamp
    );

    event OrderMatched(
        bytes32 indexed buyOrderId,
        bytes32 indexed sellOrderId,
        uint256 quantity,
        uint256 price,
        uint256 timestamp
    );

    event OrderCancelled(
        bytes32 indexed orderId,
        address indexed creator,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum OrderStatus {
        ACTIVE,     // 0
        PARTIAL,    // 1
        FILLED,     // 2
        CANCELLED   // 3
    }

    // ============ STRUCTS ============
    struct Order {
        bytes32 orderId;
        address creator;
        bool isBuyOrder;
        uint256 productId;
        uint256 quantity;
        uint256 filledQuantity;
        uint256 price;
        bytes32 orderDataHash;
        uint256 createdAt;
        uint256 expiresAt;
        OrderStatus status;
    }

    struct Trade {
        bytes32 tradeId;
        bytes32 buyOrderId;
        bytes32 sellOrderId;
        address buyer;
        address seller;
        uint256 quantity;
        uint256 price;
        uint256 timestamp;
    }

    // ============ STATE VARIABLES ============
    mapping(bytes32 => Order) private _orders;
    mapping(address => bytes32[]) private _userOrders;
    mapping(uint256 => bytes32[]) private _productOrders;
    mapping(bytes32 => Trade) private _trades;
    
    bytes32[] private _activeBuyOrders;
    bytes32[] private _activeSellOrders;
    
    IStakeholder public stakeholderContract;

    // ============ MODIFIERS ============
    modifier orderExists(bytes32 orderId) {
        require(_orders[orderId].orderId != bytes32(0), "TradingEngine: Order not found");
        _;
    }

    modifier onlyOrderCreator(bytes32 orderId) {
        require(_orders[orderId].creator == msg.sender, "TradingEngine: Not order creator");
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

    // ============ ORDER FUNCTIONS ============
    function createOrder(
        bool isBuyOrder,
        uint256 productId,
        uint256 quantity,
        uint256 price,
        bytes32 orderDataHash,
        uint256 expiresAt
    ) external returns (bytes32 orderId) {
        require(productId > 0, "TradingEngine: Invalid product ID");
        require(quantity > 0, "TradingEngine: Invalid quantity");
        require(price > 0, "TradingEngine: Invalid price");
        require(expiresAt > block.timestamp, "TradingEngine: Invalid expiry");
        require(orderDataHash != bytes32(0), "TradingEngine: Order data hash required");

        if (address(stakeholderContract) != address(0)) {
            require(stakeholderContract.isVerifiedAndIntact(msg.sender), "TradingEngine: Not verified");
        }

        orderId = keccak256(abi.encodePacked(
            msg.sender,
            productId,
            quantity,
            price,
            block.timestamp
        ));

        _orders[orderId] = Order({
            orderId: orderId,
            creator: msg.sender,
            isBuyOrder: isBuyOrder,
            productId: productId,
            quantity: quantity,
            filledQuantity: 0,
            price: price,
            orderDataHash: orderDataHash,
            createdAt: block.timestamp,
            expiresAt: expiresAt,
            status: OrderStatus.ACTIVE
        });

        _userOrders[msg.sender].push(orderId);
        _productOrders[productId].push(orderId);

        if (isBuyOrder) {
            _activeBuyOrders.push(orderId);
        } else {
            _activeSellOrders.push(orderId);
        }

        emit OrderCreated(orderId, msg.sender, isBuyOrder, productId, quantity, price, block.timestamp);
        return orderId;
    }

    function cancelOrder(bytes32 orderId) 
        external 
        orderExists(orderId) 
        onlyOrderCreator(orderId) {
        
        Order storage order = _orders[orderId];
        require(order.status == OrderStatus.ACTIVE || order.status == OrderStatus.PARTIAL, "TradingEngine: Cannot cancel");

        order.status = OrderStatus.CANCELLED;
        _removeFromActiveOrders(orderId, order.isBuyOrder);

        emit OrderCancelled(orderId, msg.sender, block.timestamp);
    }

    function matchOrders(bytes32 buyOrderId, bytes32 sellOrderId, uint256 quantity) 
        external 
        onlyRole(AUDITOR_ROLE) {
        
        Order storage buyOrder = _orders[buyOrderId];
        Order storage sellOrder = _orders[sellOrderId];

        require(buyOrder.isBuyOrder && !sellOrder.isBuyOrder, "TradingEngine: Invalid order types");
        require(buyOrder.productId == sellOrder.productId, "TradingEngine: Product mismatch");
        require(buyOrder.price >= sellOrder.price, "TradingEngine: Price mismatch");
        require(quantity > 0, "TradingEngine: Invalid quantity");

        uint256 buyAvailable = buyOrder.quantity - buyOrder.filledQuantity;
        uint256 sellAvailable = sellOrder.quantity - sellOrder.filledQuantity;
        
        require(quantity <= buyAvailable && quantity <= sellAvailable, "TradingEngine: Insufficient quantity");

        // Update orders
        buyOrder.filledQuantity += quantity;
        sellOrder.filledQuantity += quantity;

        // Update status
        if (buyOrder.filledQuantity == buyOrder.quantity) {
            buyOrder.status = OrderStatus.FILLED;
            _removeFromActiveOrders(buyOrderId, true);
        } else {
            buyOrder.status = OrderStatus.PARTIAL;
        }

        if (sellOrder.filledQuantity == sellOrder.quantity) {
            sellOrder.status = OrderStatus.FILLED;
            _removeFromActiveOrders(sellOrderId, false);
        } else {
            sellOrder.status = OrderStatus.PARTIAL;
        }

        // Create trade record
        bytes32 tradeId = keccak256(abi.encodePacked(buyOrderId, sellOrderId, block.timestamp));
        _trades[tradeId] = Trade({
            tradeId: tradeId,
            buyOrderId: buyOrderId,
            sellOrderId: sellOrderId,
            buyer: buyOrder.creator,
            seller: sellOrder.creator,
            quantity: quantity,
            price: sellOrder.price,
            timestamp: block.timestamp
        });

        emit OrderMatched(buyOrderId, sellOrderId, quantity, sellOrder.price, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    function getOrder(bytes32 orderId) external view orderExists(orderId) returns (Order memory) {
        return _orders[orderId];
    }

    function getUserOrders(address user) external view returns (bytes32[] memory) {
        return _userOrders[user];
    }

    function getProductOrders(uint256 productId) external view returns (bytes32[] memory) {
        return _productOrders[productId];
    }

    function getTrade(bytes32 tradeId) external view returns (Trade memory) {
        return _trades[tradeId];
    }

    function getActiveBuyOrders() external view returns (bytes32[] memory) {
        return _activeBuyOrders;
    }

    function getActiveSellOrders() external view returns (bytes32[] memory) {
        return _activeSellOrders;
    }

    // ============ INTERNAL FUNCTIONS ============
    function _removeFromActiveOrders(bytes32 orderId, bool isBuyOrder) internal {
        bytes32[] storage activeOrders = isBuyOrder ? _activeBuyOrders : _activeSellOrders;
        
        for (uint256 i = 0; i < activeOrders.length; i++) {
            if (activeOrders[i] == orderId) {
                activeOrders[i] = activeOrders[activeOrders.length - 1];
                activeOrders.pop();
                break;
            }
        }
    }
}
