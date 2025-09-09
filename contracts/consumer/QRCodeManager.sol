// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";
import "../interfaces/IStakeholder.sol";

/**
 * @title QRCodeManager
 * @dev Consumer QR code interface for product verification
 * @author AgriTrace Team
 */
contract QRCodeManager is AgriAccessControl {

    // ============ EVENTS ============
    event QRCodeGenerated(
        uint256 indexed productId,
        bytes32 indexed qrCodeHash,
        address indexed generator,
        uint256 timestamp
    );

    event QRCodeScanned(
        uint256 indexed productId,
        bytes32 indexed qrCodeHash,
        address indexed scanner,
        uint256 timestamp
    );

    event QRCodeUpdated(
        uint256 indexed productId,
        bytes32 oldQRHash,
        bytes32 newQRHash,
        uint256 timestamp
    );

    event QRCodeDeactivated(
        uint256 indexed productId,
        bytes32 indexed qrCodeHash,
        string reason,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct QRCode {
        uint256 productId;
        bytes32 qrCodeHash;
        bytes32 productDataHash;
        bytes32 metadataHash;
        address generator;
        uint256 generatedAt;
        uint256 lastScanned;
        uint256 scanCount;
        bool isActive;
        bool isVerified;
    }

    struct ScanRecord {
        address scanner;
        bytes32 qrCodeHash;
        uint256 timestamp;
        bytes32 locationHash;
        string deviceInfo;
    }

    struct QRCodeMetadata {
        string qrFormat; // "QR_CODE_V1", "QR_CODE_V2"
        uint256 expiryDate;
        string accessLevel; // "PUBLIC", "VERIFIED_ONLY", "STAKEHOLDER_ONLY"
        bytes32 encryptionHash;
        bool requiresAuth;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => QRCode) private _qrCodes;
    mapping(bytes32 => uint256) private _qrHashToProductId;
    mapping(uint256 => ScanRecord[]) private _scanHistory;
    mapping(uint256 => QRCodeMetadata) private _qrMetadata;
    mapping(address => uint256[]) private _userScans;
    
    // Contract references
    IStakeholder public stakeholderContract;
    address public productLifecycleContract;
    address public productHistoryContract;
    
    // QR Code parameters
    uint256 public constant DEFAULT_QR_EXPIRY = 365 days;
    uint256 public constant MAX_SCAN_RATE = 100; // Max scans per hour per user

    // ============ MODIFIERS ============
    modifier validProductId(uint256 productId) {
        require(productId > 0, "QRCodeManager: Invalid product ID");
        _;
    }

    modifier qrCodeExists(uint256 productId) {
        require(_qrCodes[productId].productId != 0, "QRCodeManager: QR code not found");
        _;
    }

    modifier onlyAuthorizedGenerator() {
        require(
            hasRole(FARMER_ROLE, msg.sender) ||
            hasRole(PROCESSOR_ROLE, msg.sender) ||
            hasRole(DISTRIBUTOR_ROLE, msg.sender) ||
            hasRole(RETAILER_ROLE, msg.sender) ||
            hasRole(AUDITOR_ROLE, msg.sender),
            "QRCodeManager: Not authorized to generate QR codes"
        );
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============ SETUP FUNCTIONS ============
    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakeholderContract != address(0), "QRCodeManager: Invalid stakeholder contract");
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    function setProductLifecycleContract(address _productLifecycleContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_productLifecycleContract != address(0), "QRCodeManager: Invalid lifecycle contract");
        productLifecycleContract = _productLifecycleContract;
    }

    function setProductHistoryContract(address _productHistoryContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_productHistoryContract != address(0), "QRCodeManager: Invalid history contract");
        productHistoryContract = _productHistoryContract;
    }

    // ============ QR CODE FUNCTIONS ============
    /**
     * @notice Generate QR code for product
     */
    function generateQRCode(
        uint256 productId,
        bytes32 productDataHash,
        bytes32 metadataHash,
        string calldata qrFormat,
        string calldata accessLevel,
        uint256 expiryDays
    ) external 
      validProductId(productId) 
      onlyAuthorizedGenerator 
      returns (bytes32 qrCodeHash) {
        
        require(productDataHash != bytes32(0), "QRCodeManager: Product data hash required");
        require(metadataHash != bytes32(0), "QRCodeManager: Metadata hash required");
        require(bytes(qrFormat).length > 0, "QRCodeManager: QR format required");
        require(expiryDays > 0 && expiryDays <= 730, "QRCodeManager: Invalid expiry period"); // Max 2 years

        // Generate unique QR code hash
        qrCodeHash = keccak256(abi.encodePacked(
            productId,
            productDataHash,
            msg.sender,
            block.timestamp
        ));

        // Check if QR code already exists for this product
        if (_qrCodes[productId].productId != 0) {
            // Update existing QR code
            bytes32 oldQRHash = _qrCodes[productId].qrCodeHash;
            _qrCodes[productId].qrCodeHash = qrCodeHash;
            _qrCodes[productId].productDataHash = productDataHash;
            _qrCodes[productId].metadataHash = metadataHash;
            _qrCodes[productId].generator = msg.sender;
            _qrCodes[productId].generatedAt = block.timestamp;
            
            emit QRCodeUpdated(productId, oldQRHash, qrCodeHash, block.timestamp);
        } else {
            // Create new QR code
            _qrCodes[productId] = QRCode({
                productId: productId,
                qrCodeHash: qrCodeHash,
                productDataHash: productDataHash,
                metadataHash: metadataHash,
                generator: msg.sender,
                generatedAt: block.timestamp,
                lastScanned: 0,
                scanCount: 0,
                isActive: true,
                isVerified: false
            });
        }

        // Set metadata
        _qrMetadata[productId] = QRCodeMetadata({
            qrFormat: qrFormat,
            expiryDate: block.timestamp + (expiryDays * 1 days),
            accessLevel: accessLevel,
            encryptionHash: metadataHash,
            requiresAuth: keccak256(bytes(accessLevel)) != keccak256(bytes("PUBLIC"))
        });

        _qrHashToProductId[qrCodeHash] = productId;

        emit QRCodeGenerated(productId, qrCodeHash, msg.sender, block.timestamp);
        return qrCodeHash;
    }

    /**
     * @notice Scan QR code
     */
    function scanQRCode(
        bytes32 qrCodeHash,
        bytes32 locationHash,
        string calldata deviceInfo
    ) external returns (uint256 productId, bool accessGranted) {
        require(qrCodeHash != bytes32(0), "QRCodeManager: Invalid QR code hash");
        
        productId = _qrHashToProductId[qrCodeHash];
        require(productId != 0, "QRCodeManager: QR code not found");

        QRCode storage qrCode = _qrCodes[productId];
        QRCodeMetadata memory metadata = _qrMetadata[productId];
        
        require(qrCode.isActive, "QRCodeManager: QR code deactivated");
        require(block.timestamp <= metadata.expiryDate, "QRCodeManager: QR code expired");

        // Check access permissions
        accessGranted = _checkAccessPermission(msg.sender, metadata.accessLevel);
        
        if (accessGranted) {
            // Record scan
            ScanRecord memory scan = ScanRecord({
                scanner: msg.sender,
                qrCodeHash: qrCodeHash,
                timestamp: block.timestamp,
                locationHash: locationHash,
                deviceInfo: deviceInfo
            });

            _scanHistory[productId].push(scan);
            _userScans[msg.sender].push(productId);
            
            qrCode.lastScanned = block.timestamp;
            qrCode.scanCount++;

            emit QRCodeScanned(productId, qrCodeHash, msg.sender, block.timestamp);
        }

        return (productId, accessGranted);
    }

    /**
     * @notice Verify QR code authenticity
     */
    function verifyQRCode(
        uint256 productId,
        bytes32 qrCodeHash,
        bytes32 currentProductDataHash
    ) external view returns (bool isValid, bool isExpired) {
        QRCode memory qrCode = _qrCodes[productId];
        QRCodeMetadata memory metadata = _qrMetadata[productId];
        
        isValid = qrCode.qrCodeHash == qrCodeHash && 
                  qrCode.productDataHash == currentProductDataHash &&
                  qrCode.isActive;
        
        isExpired = block.timestamp > metadata.expiryDate;
        
        return (isValid, isExpired);
    }

    // ============ VIEW FUNCTIONS ============
    function getQRCode(uint256 productId) external view qrCodeExists(productId) returns (QRCode memory) {
        return _qrCodes[productId];
    }

    function getQRCodeMetadata(uint256 productId) external view returns (QRCodeMetadata memory) {
        return _qrMetadata[productId];
    }

    function getScanHistory(uint256 productId) external view returns (ScanRecord[] memory) {
        return _scanHistory[productId];
    }

    function getUserScanHistory(address user) external view returns (uint256[] memory) {
        return _userScans[user];
    }

    function getProductByQRHash(bytes32 qrCodeHash) external view returns (uint256) {
        return _qrHashToProductId[qrCodeHash];
    }

    // ============ ADMIN FUNCTIONS ============
    function verifyQRCode(uint256 productId) external onlyRole(AUDITOR_ROLE) qrCodeExists(productId) {
        _qrCodes[productId].isVerified = true;
    }

    function deactivateQRCode(uint256 productId, string calldata reason) 
        external 
        onlyRole(AUDITOR_ROLE) 
        qrCodeExists(productId) {
        
        _qrCodes[productId].isActive = false;
        emit QRCodeDeactivated(productId, _qrCodes[productId].qrCodeHash, reason, block.timestamp);
    }

    // ============ INTERNAL FUNCTIONS ============
    function _checkAccessPermission(address user, string memory accessLevel) internal view returns (bool) {
        bytes32 levelHash = keccak256(bytes(accessLevel));
        
        if (levelHash == keccak256(bytes("PUBLIC"))) {
            return true;
        } else if (levelHash == keccak256(bytes("VERIFIED_ONLY"))) {
            return address(stakeholderContract) != address(0) && 
                   stakeholderContract.isVerifiedAndIntact(user);
        } else if (levelHash == keccak256(bytes("STAKEHOLDER_ONLY"))) {
            return hasRole(FARMER_ROLE, user) ||
                   hasRole(PROCESSOR_ROLE, user) ||
                   hasRole(DISTRIBUTOR_ROLE, user) ||
                   hasRole(RETAILER_ROLE, user) ||
                   hasRole(AUDITOR_ROLE, user);
        }
        
        return false;
    }
}