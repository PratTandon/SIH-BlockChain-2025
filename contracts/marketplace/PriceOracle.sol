// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";
import "../libraries/DateTimeLib.sol";

/**
 * @title PriceOracle
 * @dev Dynamic pricing mechanism for agricultural products
 * @author AgriTrace Team
 */
contract PriceOracle is AgriAccessControl {
    using DateTimeLib for uint256;

    // ============ EVENTS ============
    event PriceUpdated(
        string indexed productType,
        uint256 indexed priceId,
        uint256 price,
        bytes32 priceDataHash,
        address updater,
        uint256 timestamp
    );

    event MarketTrendRecorded(
        string indexed productType,
        bytes32 indexed trendHash,
        int256 trendDirection,
        uint256 timestamp
    );

    event PriceAlertTriggered(
        string indexed productType,
        uint256 price,
        uint256 threshold,
        string alertType,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct PriceEntry {
        uint256 priceId;
        string productType;
        uint256 price; // Price per kg in wei
        bytes32 priceDataHash;
        address updater;
        uint256 timestamp;
        bool isVerified;
        string source; // "MANUAL", "API", "CALCULATED"
    }

    struct MarketData {
        string productType;
        uint256 currentPrice;
        uint256 avgPrice7Days;
        uint256 avgPrice30Days;
        uint256 minPrice;
        uint256 maxPrice;
        int256 volatility;
        uint256 lastUpdated;
    }

    struct PriceThreshold {
        uint256 minPrice;
        uint256 maxPrice;
        uint256 volatilityLimit;
        bool alertsEnabled;
    }

    // ============ STATE VARIABLES ============
    mapping(string => PriceEntry[]) private _priceHistory;
    mapping(string => MarketData) private _marketData;
    mapping(string => PriceThreshold) private _priceThresholds;
    mapping(bytes32 => PriceEntry) private _priceById;
    mapping(address => bool) private _authorizedOracles;
    
    string[] private _trackedProducts;
    uint256 private _priceIdCounter;

    // Price update parameters
    uint256 public constant PRICE_UPDATE_COOLDOWN = 5 minutes;
    uint256 public constant MAX_PRICE_DEVIATION = 2000; // 20% max deviation
    uint256 public constant VOLATILITY_THRESHOLD = 1500; // 15% volatility alert

    // ============ MODIFIERS ============
    modifier onlyAuthorizedOracle() {
        require(
            _authorizedOracles[msg.sender] || 
            hasRole(AUDITOR_ROLE, msg.sender) || 
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "PriceOracle: Not authorized oracle"
        );
        _;
    }

    modifier validProductType(string calldata productType) {
        require(bytes(productType).length > 0, "PriceOracle: Invalid product type");
        _;
    }

    modifier validPrice(uint256 price) {
        require(price > 0, "PriceOracle: Price must be greater than zero");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _priceIdCounter = 0;
    }

    // ============ ORACLE MANAGEMENT ============
    function addAuthorizedOracle(address oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(oracle != address(0), "PriceOracle: Invalid oracle address");
        _authorizedOracles[oracle] = true;
    }

    function removeAuthorizedOracle(address oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _authorizedOracles[oracle] = false;
    }

    // ============ PRICE FUNCTIONS ============
    function updatePrice(
        string calldata productType,
        uint256 price,
        bytes32 priceDataHash,
        string calldata source
    ) external 
      onlyAuthorizedOracle 
      validProductType(productType) 
      validPrice(price) 
      returns (uint256 priceId) {
        
        require(priceDataHash != bytes32(0), "PriceOracle: Price data hash required");
        require(bytes(source).length > 0, "PriceOracle: Source required");

        // Check cooldown period
        MarketData memory market = _marketData[productType];
        if (market.lastUpdated > 0) {
            require(
                block.timestamp >= market.lastUpdated + PRICE_UPDATE_COOLDOWN,
                "PriceOracle: Update too frequent"
            );
        }

        // Validate price deviation
        if (market.currentPrice > 0) {
            uint256 deviation = _calculateDeviation(price, market.currentPrice);
            require(deviation <= MAX_PRICE_DEVIATION, "PriceOracle: Price deviation too high");
        }

        _priceIdCounter++;
        priceId = _priceIdCounter;

        PriceEntry memory priceEntry = PriceEntry({
            priceId: priceId,
            productType: productType,
            price: price,
            priceDataHash: priceDataHash,
            updater: msg.sender,
            timestamp: block.timestamp,
            isVerified: false,
            source: source
        });

        _priceHistory[productType].push(priceEntry);
        _priceById[bytes32(priceId)] = priceEntry;

        // Add to tracked products if new
        if (market.lastUpdated == 0) {
            _trackedProducts.push(productType);
        }

        // Update market data
        _updateMarketData(productType, price);

        // Check thresholds
        _checkPriceThresholds(productType, price);

        emit PriceUpdated(productType, priceId, price, priceDataHash, msg.sender, block.timestamp);
        return priceId;
    }

    function batchUpdatePrices(
        string[] calldata productTypes,
        uint256[] calldata prices,
        bytes32[] calldata priceDataHashes,
        string calldata source
    ) external onlyAuthorizedOracle {
        require(productTypes.length == prices.length, "PriceOracle: Array length mismatch");
        require(productTypes.length == priceDataHashes.length, "PriceOracle: Array length mismatch");

        for (uint256 i = 0; i < productTypes.length; i++) {
            if (bytes(productTypes[i]).length > 0 && prices[i] > 0 && priceDataHashes[i] != bytes32(0)) {
                this.updatePrice(productTypes[i], prices[i], priceDataHashes[i], source);
            }
        }
    }

    // ============ VIEW FUNCTIONS ============
    function getCurrentPrice(string calldata productType) external view returns (uint256) {
        return _marketData[productType].currentPrice;
    }

    function getMarketData(string calldata productType) external view returns (MarketData memory) {
        return _marketData[productType];
    }

    function getPriceHistory(string calldata productType, uint256 limit) 
        external view 
        returns (PriceEntry[] memory) {
        
        PriceEntry[] memory history = _priceHistory[productType];
        
        if (limit == 0 || limit >= history.length) {
            return history;
        }
        
        PriceEntry[] memory limitedHistory = new PriceEntry[](limit);
        uint256 startIndex = history.length - limit;
        
        for (uint256 i = 0; i < limit; i++) {
            limitedHistory[i] = history[startIndex + i];
        }
        
        return limitedHistory;
    }

    function getPriceById(uint256 priceId) external view returns (PriceEntry memory) {
        return _priceById[bytes32(priceId)];
    }

    function getTrackedProducts() external view returns (string[] memory) {
        return _trackedProducts;
    }

    function getPriceThreshold(string calldata productType) external view returns (PriceThreshold memory) {
        return _priceThresholds[productType];
    }

    function calculateAveragePrice(
        string calldata productType,
        uint256 periodDays
    ) external view returns (uint256 avgPrice) {
        PriceEntry[] memory history = _priceHistory[productType];
        if (history.length == 0) return 0;

        uint256 cutoffTime = block.timestamp - (periodDays * 1 days);
        uint256 totalPrice = 0;
        uint256 count = 0;

        for (uint256 i = history.length; i > 0; i--) {
            if (history[i-1].timestamp >= cutoffTime) {
                totalPrice += history[i-1].price;
                count++;
            } else {
                break;
            }
        }

        return count > 0 ? totalPrice / count : 0;
    }

    function getPriceVolatility(string calldata productType) external view returns (int256) {
        return _marketData[productType].volatility;
    }

    function verifyPriceIntegrity(
        uint256 priceId,
        bytes32 currentDataHash
    ) external view returns (bool) {
        return _priceById[bytes32(priceId)].priceDataHash == currentDataHash;
    }

    // ============ ADMIN FUNCTIONS ============
    function setPriceThreshold(
        string calldata productType,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 volatilityLimit,
        bool alertsEnabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) validProductType(productType) {
        require(minPrice < maxPrice, "PriceOracle: Invalid price range");
        require(volatilityLimit <= 5000, "PriceOracle: Volatility limit too high");

        _priceThresholds[productType] = PriceThreshold({
            minPrice: minPrice,
            maxPrice: maxPrice,
            volatilityLimit: volatilityLimit,
            alertsEnabled: alertsEnabled
        });
    }

    function verifyPrice(uint256 priceId) external onlyRole(AUDITOR_ROLE) {
        require(_priceById[bytes32(priceId)].priceId != 0, "PriceOracle: Price not found");
        _priceById[bytes32(priceId)].isVerified = true;
    }

    function emergencyUpdatePrice(
        string calldata productType,
        uint256 price,
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) validProductType(productType) validPrice(price) {
        require(bytes(reason).length > 0, "PriceOracle: Reason required");

        bytes32 emergencyHash = keccak256(abi.encodePacked(reason, block.timestamp));
        
        _priceIdCounter++;
        uint256 priceId = _priceIdCounter;

        PriceEntry memory priceEntry = PriceEntry({
            priceId: priceId,
            productType: productType,
            price: price,
            priceDataHash: emergencyHash,
            updater: msg.sender,
            timestamp: block.timestamp,
            isVerified: true,
            source: "EMERGENCY"
        });

        _priceHistory[productType].push(priceEntry);
        _priceById[bytes32(priceId)] = priceEntry;
        _updateMarketData(productType, price);

        emit PriceUpdated(productType, priceId, price, emergencyHash, msg.sender, block.timestamp);
    }

    // ============ INTERNAL FUNCTIONS ============
    function _updateMarketData(string memory productType, uint256 newPrice) internal {
        MarketData storage market = _marketData[productType];
        
        // Update basic data
        market.productType = productType;
        market.currentPrice = newPrice;
        market.lastUpdated = block.timestamp;

        // Update min/max
        if (market.minPrice == 0 || newPrice < market.minPrice) {
            market.minPrice = newPrice;
        }
        if (newPrice > market.maxPrice) {
            market.maxPrice = newPrice;
        }

        // Calculate averages
        market.avgPrice7Days = this.calculateAveragePrice(productType, 7);
        market.avgPrice30Days = this.calculateAveragePrice(productType, 30);

        // Calculate volatility
        market.volatility = _calculateVolatility(productType);
    }

    function _calculateDeviation(uint256 newPrice, uint256 currentPrice) internal pure returns (uint256) {
        if (currentPrice == 0) return 0;
        
        uint256 diff = newPrice > currentPrice ? newPrice - currentPrice : currentPrice - newPrice;
        return (diff * 10000) / currentPrice; // Basis points
    }

    function _calculateVolatility(string memory productType) internal view returns (int256) {
        PriceEntry[] memory history = _priceHistory[productType];
        if (history.length < 2) return 0;

        uint256 periods = history.length > 10 ? 10 : history.length - 1;
        int256 totalDeviation = 0;

        for (uint256 i = history.length - periods; i < history.length - 1; i++) {
            uint256 currentPrice = history[i].price;
            uint256 nextPrice = history[i + 1].price;
            
            int256 change = int256(nextPrice) - int256(currentPrice);
            int256 percentChange = (change * 10000) / int256(currentPrice);
            
            totalDeviation += percentChange < 0 ? -percentChange : percentChange;
        }

        return totalDeviation / int256(periods);
    }

    function _checkPriceThresholds(string memory productType, uint256 price) internal {
        PriceThreshold memory threshold = _priceThresholds[productType];
        if (!threshold.alertsEnabled) return;

        if (price < threshold.minPrice) {
            emit PriceAlertTriggered(productType, price, threshold.minPrice, "LOW_PRICE", block.timestamp);
        } else if (price > threshold.maxPrice) {
            emit PriceAlertTriggered(productType, price, threshold.maxPrice, "HIGH_PRICE", block.timestamp);
        }

        int256 volatility = _marketData[productType].volatility;
        if (volatility > int256(threshold.volatilityLimit)) {
            emit PriceAlertTriggered(productType, price, threshold.volatilityLimit, "HIGH_VOLATILITY", block.timestamp);
        }
    }
}
