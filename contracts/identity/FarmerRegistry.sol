// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IStakeholder.sol";
import "../libraries/GeolocationLib.sol";
import "../libraries/DateTimeLib.sol";
import "../core/AgriAccessControl.sol";

/**
 * @title FarmerRegistry
 * @dev Farmer onboarding and verification system
 * @author AgriTrace Team
 */
contract FarmerRegistry is AgriAccessControl {
    using GeolocationLib for GeolocationLib.GPSCoordinate;
    using DateTimeLib for uint256;

    // ============ EVENTS ============
    event FarmerRegistered(
        address indexed farmer,
        bytes32 indexed profileHash,
        string farmName,
        uint256 timestamp
    );

    event FarmerVerified(
        address indexed farmer,
        address indexed verifier,
        bytes32 verificationHash,
        uint256 timestamp
    );

    event FarmDetailsUpdated(
        address indexed farmer,
        bytes32 indexed newDetailsHash,
        uint256 timestamp
    );

    event LandVerificationSubmitted(
        address indexed farmer,
        bytes32 indexed landDocumentHash,
        uint256 landArea,
        uint256 timestamp
    );

    event FarmerSuspended(
        address indexed farmer,
        address indexed suspender,
        string reason,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct FarmerProfile {
        address farmerAddress;
        string farmName;
        bytes32 profileDataHash;
        GeolocationLib.GPSCoordinate farmLocation;
        uint256 totalLandArea; // in square meters
        uint256 registrationDate;
        uint256 lastVerificationDate;
        bool isActive;
        bool isVerified;
        bytes32 kycDocumentHash;
        bytes32 landOwnershipHash;
    }

    struct VerificationRequest {
        address farmer;
        bytes32 documentsHash;
        string verificationType;
        address verifier;
        uint256 requestDate;
        uint256 responseDate;
        bool isApproved;
        string comments;
    }

    struct FarmAsset {
        string assetType; // "Land", "Equipment", "Livestock"
        string description;
        uint256 value; // in wei
        bytes32 documentHash;
        uint256 acquisitionDate;
        bool isVerified;
    }

    // ============ STATE VARIABLES ============
    mapping(address => FarmerProfile) private _farmers;
    mapping(address => VerificationRequest[]) private _verificationHistory;
    mapping(address => FarmAsset[]) private _farmAssets;
    mapping(string => address) private _farmNameToAddress;
    mapping(bytes32 => address) private _kycHashToFarmer;
    
    address[] private _registeredFarmers;
    address[] private _verifiedFarmers;
    
    IStakeholder public stakeholderContract;
    
    uint256 public constant MIN_LAND_AREA = 100; // 100 sq meters minimum
    uint256 public constant MAX_LAND_AREA = 10000000; // 1000 hectares maximum
    uint256 public constant VERIFICATION_VALIDITY = 365 days;

    // ============ MODIFIERS ============
    modifier onlyRegisteredFarmer() {
        require(_farmers[msg.sender].farmerAddress != address(0), "FarmerRegistry: Not registered farmer");
        _;
    }

    modifier onlyActiveFarmer() {
        require(_farmers[msg.sender].isActive, "FarmerRegistry: Farmer not active");
        _;
    }

    modifier validFarmName(string calldata farmName) {
        require(bytes(farmName).length > 0 && bytes(farmName).length <= 100, "FarmerRegistry: Invalid farm name");
        require(_farmNameToAddress[farmName] == address(0), "FarmerRegistry: Farm name already taken");
        _;
    }

    modifier validLocation(GeolocationLib.GPSCoordinate memory location) {
        require(location.validateCoordinates(), "FarmerRegistry: Invalid GPS coordinates");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============ SETUP FUNCTIONS ============
    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakeholderContract != address(0), "FarmerRegistry: Invalid stakeholder contract");
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    // ============ REGISTRATION FUNCTIONS ============
    /**
     * @notice Register new farmer
     */
    function registerFarmer(
        string calldata farmName,
        bytes32 profileDataHash,
        GeolocationLib.GPSCoordinate calldata farmLocation,
        uint256 landArea,
        bytes32 kycDocumentHash
    ) external validFarmName(farmName) validLocation(farmLocation) {
        require(_farmers[msg.sender].farmerAddress == address(0), "FarmerRegistry: Already registered");
        require(profileDataHash != bytes32(0), "FarmerRegistry: Profile hash required");
        require(kycDocumentHash != bytes32(0), "FarmerRegistry: KYC document hash required");
        require(landArea >= MIN_LAND_AREA && landArea <= MAX_LAND_AREA, "FarmerRegistry: Invalid land area");
        require(_kycHashToFarmer[kycDocumentHash] == address(0), "FarmerRegistry: KYC document already used");

        _farmers[msg.sender] = FarmerProfile({
            farmerAddress: msg.sender,
            farmName: farmName,
            profileDataHash: profileDataHash,
            farmLocation: farmLocation,
            totalLandArea: landArea,
            registrationDate: block.timestamp,
            lastVerificationDate: 0,
            isActive: true,
            isVerified: false,
            kycDocumentHash: kycDocumentHash,
            landOwnershipHash: bytes32(0)
        });

        _farmNameToAddress[farmName] = msg.sender;
        _kycHashToFarmer[kycDocumentHash] = msg.sender;
        _registeredFarmers.push(msg.sender);

        // Register in stakeholder contract if available
        if (address(stakeholderContract) != address(0)) {
            stakeholderContract.registerStakeholderHash(
                IStakeholder.StakeholderType.FARMER,
                profileDataHash
            );
        }

        emit FarmerRegistered(msg.sender, profileDataHash, farmName, block.timestamp);
    }

    /**
     * @notice Submit verification request
     */
    function submitVerificationRequest(
        bytes32 documentsHash,
        string calldata verificationType
    ) external onlyRegisteredFarmer onlyActiveFarmer {
        require(documentsHash != bytes32(0), "FarmerRegistry: Documents hash required");
        require(bytes(verificationType).length > 0, "FarmerRegistry: Verification type required");

        VerificationRequest memory request = VerificationRequest({
            farmer: msg.sender,
            documentsHash: documentsHash,
            verificationType: verificationType,
            verifier: address(0),
            requestDate: block.timestamp,
            responseDate: 0,
            isApproved: false,
            comments: ""
        });

        _verificationHistory[msg.sender].push(request);
    }

    /**
     * @notice Verify farmer (auditor only)
     */
    function verifyFarmer(
        address farmer,
        bytes32 verificationHash,
        bool approved,
        string calldata comments
    ) external onlyRole(AUDITOR_ROLE) {
        require(_farmers[farmer].farmerAddress != address(0), "FarmerRegistry: Farmer not registered");
        require(verificationHash != bytes32(0), "FarmerRegistry: Verification hash required");

        FarmerProfile storage profile = _farmers[farmer];
        
        if (approved) {
            profile.isVerified = true;
            profile.lastVerificationDate = block.timestamp;
            
            // Add to verified farmers list if not already present
            bool alreadyVerified = false;
            for (uint256 i = 0; i < _verifiedFarmers.length; i++) {
                if (_verifiedFarmers[i] == farmer) {
                    alreadyVerified = true;
                    break;
                }
            }
            if (!alreadyVerified) {
                _verifiedFarmers.push(farmer);
            }

            // Grant farmer role
            grantRole(FARMER_ROLE, farmer);

            // Update stakeholder verification
            if (address(stakeholderContract) != address(0)) {
                stakeholderContract.updateVerificationHash(
                    farmer,
                    IStakeholder.VerificationStatus.VERIFIED,
                    verificationHash
                );
            }
        }

        // Update latest verification request
        VerificationRequest[] storage requests = _verificationHistory[farmer];
        if (requests.length > 0) {
            VerificationRequest storage latestRequest = requests[requests.length - 1];
            latestRequest.verifier = msg.sender;
            latestRequest.responseDate = block.timestamp;
            latestRequest.isApproved = approved;
            latestRequest.comments = comments;
        }

        emit FarmerVerified(farmer, msg.sender, verificationHash, block.timestamp);
    }

    /**
     * @notice Submit land ownership verification
     */
    function submitLandVerification(
        bytes32 landDocumentHash,
        uint256 verifiedLandArea
    ) external onlyRegisteredFarmer {
        require(landDocumentHash != bytes32(0), "FarmerRegistry: Land document hash required");
        require(verifiedLandArea >= MIN_LAND_AREA, "FarmerRegistry: Land area too small");

        FarmerProfile storage profile = _farmers[msg.sender];
        profile.landOwnershipHash = landDocumentHash;
        profile.totalLandArea = verifiedLandArea;

        emit LandVerificationSubmitted(msg.sender, landDocumentHash, verifiedLandArea, block.timestamp);
    }

    /**
     * @notice Update farm details
     */
    function updateFarmDetails(
        bytes32 newProfileDataHash,
        GeolocationLib.GPSCoordinate calldata newLocation
    ) external onlyRegisteredFarmer onlyActiveFarmer validLocation(newLocation) {
        require(newProfileDataHash != bytes32(0), "FarmerRegistry: Profile hash required");

        FarmerProfile storage profile = _farmers[msg.sender];
        profile.profileDataHash = newProfileDataHash;
        profile.farmLocation = newLocation;

        emit FarmDetailsUpdated(msg.sender, newProfileDataHash, block.timestamp);
    }

    /**
     * @notice Add farm asset
     */
    function addFarmAsset(
        string calldata assetType,
        string calldata description,
        uint256 value,
        bytes32 documentHash
    ) external onlyRegisteredFarmer onlyActiveFarmer {
        require(bytes(assetType).length > 0, "FarmerRegistry: Asset type required");
        require(bytes(description).length > 0, "FarmerRegistry: Description required");
        require(documentHash != bytes32(0), "FarmerRegistry: Document hash required");

        FarmAsset memory asset = FarmAsset({
            assetType: assetType,
            description: description,
            value: value,
            documentHash: documentHash,
            acquisitionDate: block.timestamp,
            isVerified: false
        });

        _farmAssets[msg.sender].push(asset);
    }

    /**
     * @notice Verify farm asset (auditor only)
     */
    function verifyFarmAsset(
        address farmer,
        uint256 assetIndex,
        bool verified
    ) external onlyRole(AUDITOR_ROLE) {
        require(_farmAssets[farmer].length > assetIndex, "FarmerRegistry: Invalid asset index");
        
        _farmAssets[farmer][assetIndex].isVerified = verified;
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get farmer profile
     */
    function getFarmerProfile(address farmer) external view returns (FarmerProfile memory) {
        require(_farmers[farmer].farmerAddress != address(0), "FarmerRegistry: Farmer not found");
        return _farmers[farmer];
    }

    /**
     * @notice Get verification history
     */
    function getVerificationHistory(address farmer) external view returns (VerificationRequest[] memory) {
        return _verificationHistory[farmer];
    }

    /**
     * @notice Get farm assets
     */
    function getFarmAssets(address farmer) external view returns (FarmAsset[] memory) {
        return _farmAssets[farmer];
    }

    /**
     * @notice Check if farmer is registered
     */
    function isFarmerRegistered(address farmer) external view returns (bool) {
        return _farmers[farmer].farmerAddress != address(0);
    }

    /**
     * @notice Check if farmer is verified
     */
    function isFarmerVerified(address farmer) external view returns (bool) {
        return _farmers[farmer].isVerified;
    }

    /**
     * @notice Check if verification is still valid
     */
    function isVerificationValid(address farmer) external view returns (bool) {
        FarmerProfile memory profile = _farmers[farmer];
        if (!profile.isVerified || profile.lastVerificationDate == 0) {
            return false;
        }
        return block.timestamp <= profile.lastVerificationDate + VERIFICATION_VALIDITY;
    }

    /**
     * @notice Get farmer by farm name
     */
    function getFarmerByFarmName(string calldata farmName) external view returns (address) {
        return _farmNameToAddress[farmName];
    }

    /**
     * @notice Get all registered farmers
     */
    function getRegisteredFarmers() external view returns (address[] memory) {
        return _registeredFarmers;
    }

    /**
     * @notice Get all verified farmers
     */
    function getVerifiedFarmers() external view returns (address[] memory) {
        return _verifiedFarmers;
    }

    /**
     * @notice Get farmers count
     */
    function getFarmersCount() external view returns (uint256 registered, uint256 verified) {
        return (_registeredFarmers.length, _verifiedFarmers.length);
    }

    /**
     * @notice Get farmers by location (within radius)
     */
    function getFarmersByLocation(
        GeolocationLib.GPSCoordinate calldata center,
        uint256 radiusMeters
    ) external view validLocation(center) returns (address[] memory) {
        address[] memory tempFarmers = new address[](_registeredFarmers.length);
        uint256 count = 0;

        for (uint256 i = 0; i < _registeredFarmers.length; i++) {
            address farmer = _registeredFarmers[i];
            if (_farmers[farmer].isActive) {
                uint256 distance = center.calculateDistance(_farmers[farmer].farmLocation);
                if (distance <= radiusMeters) {
                    tempFarmers[count] = farmer;
                    count++;
                }
            }
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = tempFarmers[i];
        }

        return result;
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Suspend farmer
     */
    function suspendFarmer(address farmer, string calldata reason) external onlyRole(AUDITOR_ROLE) {
        require(_farmers[farmer].farmerAddress != address(0), "FarmerRegistry: Farmer not found");
        require(bytes(reason).length > 0, "FarmerRegistry: Reason required");

        _farmers[farmer].isActive = false;
        
        // Revoke farmer role
        revokeRole(FARMER_ROLE, farmer);

        // Update stakeholder status
        if (address(stakeholderContract) != address(0)) {
            stakeholderContract.updateVerificationHash(
                farmer,
                IStakeholder.VerificationStatus.SUSPENDED,
                keccak256(abi.encodePacked(reason, block.timestamp))
            );
        }

        emit FarmerSuspended(farmer, msg.sender, reason, block.timestamp);
    }

    /**
     * @notice Reactivate farmer
     */
    function reactivateFarmer(address farmer) external onlyRole(AUDITOR_ROLE) {
        require(_farmers[farmer].farmerAddress != address(0), "FarmerRegistry: Farmer not found");
        require(!_farmers[farmer].isActive, "FarmerRegistry: Farmer already active");

        _farmers[farmer].isActive = true;
        
        // Grant farmer role back if verified
        if (_farmers[farmer].isVerified) {
            grantRole(FARMER_ROLE, farmer);
        }

        // Update stakeholder status
        if (address(stakeholderContract) != address(0)) {
            IStakeholder.VerificationStatus status = _farmers[farmer].isVerified ? 
                IStakeholder.VerificationStatus.VERIFIED : 
                IStakeholder.VerificationStatus.PENDING;
                
            stakeholderContract.updateVerificationHash(
                farmer,
                status,
                keccak256(abi.encodePacked("REACTIVATED", block.timestamp))
            );
        }
    }

    /**
     * @notice Update verification validity period
     */
    function updateVerificationValidity(uint256 newValidityPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newValidityPeriod >= 30 days && newValidityPeriod <= 1095 days, "FarmerRegistry: Invalid validity period");
        // Note: This would require a state variable for verification validity
        // Currently using constant for gas efficiency
    }

    /**
     * @notice Batch verify farmers
     */
    function batchVerifyFarmers(
        address[] calldata farmers,
        bytes32[] calldata verificationHashes,
        bool[] calldata approvals
    ) external onlyRole(AUDITOR_ROLE) {
        require(farmers.length == verificationHashes.length, "FarmerRegistry: Array length mismatch");
        require(farmers.length == approvals.length, "FarmerRegistry: Array length mismatch");

        for (uint256 i = 0; i < farmers.length; i++) {
            if (_farmers[farmers[i]].farmerAddress != address(0)) {
                this.verifyFarmer(farmers[i], verificationHashes[i], approvals[i], "Batch verification");
            }
        }
    }

    /**
     * @notice Emergency farmer deactivation
     */
    function emergencyDeactivateFarmer(address farmer, string calldata reason) external onlyRole(EMERGENCY_ROLE) {
        require(_farmers[farmer].farmerAddress != address(0), "FarmerRegistry: Farmer not found");
        
        _farmers[farmer].isActive = false;
        revokeRole(FARMER_ROLE, farmer);
        
        emit FarmerSuspended(farmer, msg.sender, string(abi.encodePacked("EMERGENCY: ", reason)), block.timestamp);
    }
}
