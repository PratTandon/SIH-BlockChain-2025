// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";
import "../libraries/GeolocationLib.sol";
import "../libraries/DateTimeLib.sol";

/**
 * @title Provenance
 * @dev Origin and heritage tracking with hash-based verification
 * @author AgriTrace Team
 */
contract Provenance is AgriAccessControl {
    using GeolocationLib for GeolocationLib.GPSCoordinate;
    using DateTimeLib for uint256;

    // ============ EVENTS ============
    event OriginRecorded(
        uint256 indexed productId,
        bytes32 indexed originHash,
        address indexed farmer,
        bytes32 locationHash,
        uint256 timestamp
    );

    event HeritageAdded(
        uint256 indexed productId,
        bytes32 indexed heritageHash,
        string heritageType,
        uint256 timestamp
    );

    event CertificationLinked(
        uint256 indexed productId,
        bytes32 indexed certHash,
        string certificationType,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct ProductOrigin {
        uint256 productId;
        address farmer;
        bytes32 originDataHash;
        bytes32 locationHash;
        bytes32 seedSourceHash;
        uint256 plantingDate;
        bool isVerified;
    }

    struct Heritage {
        bytes32 heritageHash;
        string heritageType; // "ORGANIC", "HEIRLOOM", "LOCAL_VARIETY"
        bytes32 documentHash;
        uint256 timestamp;
        bool isActive;
    }

    struct Certification {
        bytes32 certHash;
        string certificationType;
        bytes32 documentHash;
        uint256 issueDate;
        uint256 expiryDate;
        address issuer;
        bool isValid;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => ProductOrigin) private _origins;
    mapping(uint256 => Heritage[]) private _heritage;
    mapping(uint256 => Certification[]) private _certifications;
    mapping(bytes32 => uint256) private _originHashToProduct;

    // ============ MODIFIERS ============
    modifier validProductId(uint256 productId) {
        require(productId > 0, "Provenance: Invalid product ID");
        _;
    }

    modifier originExists(uint256 productId) {
        require(_origins[productId].productId != 0, "Provenance: Origin not recorded");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============ ORIGIN FUNCTIONS ============
    function recordOrigin(
        uint256 productId,
        bytes32 originDataHash,
        bytes32 locationHash,
        bytes32 seedSourceHash,
        uint256 plantingDate
    ) external onlyRole(FARMER_ROLE) validProductId(productId) {
        require(_origins[productId].productId == 0, "Provenance: Origin already recorded");
        require(originDataHash != bytes32(0), "Provenance: Origin hash required");
        require(locationHash != bytes32(0), "Provenance: Location hash required");

        _origins[productId] = ProductOrigin({
            productId: productId,
            farmer: msg.sender,
            originDataHash: originDataHash,
            locationHash: locationHash,
            seedSourceHash: seedSourceHash,
            plantingDate: plantingDate,
            isVerified: false
        });

        _originHashToProduct[originDataHash] = productId;

        emit OriginRecorded(productId, originDataHash, msg.sender, locationHash, block.timestamp);
    }

    function addHeritage(
        uint256 productId,
        bytes32 heritageHash,
        string calldata heritageType,
        bytes32 documentHash
    ) external onlyRole(FARMER_ROLE) validProductId(productId) originExists(productId) {
        require(heritageHash != bytes32(0), "Provenance: Heritage hash required");
        require(bytes(heritageType).length > 0, "Provenance: Heritage type required");

        Heritage memory heritage = Heritage({
            heritageHash: heritageHash,
            heritageType: heritageType,
            documentHash: documentHash,
            timestamp: block.timestamp,
            isActive: true
        });

        _heritage[productId].push(heritage);

        emit HeritageAdded(productId, heritageHash, heritageType, block.timestamp);
    }

    function linkCertification(
        uint256 productId,
        bytes32 certHash,
        string calldata certificationType,
        bytes32 documentHash,
        uint256 expiryDate,
        address issuer
    ) external onlyRole(AUDITOR_ROLE) validProductId(productId) {
        require(certHash != bytes32(0), "Provenance: Cert hash required");
        require(expiryDate > block.timestamp, "Provenance: Invalid expiry date");

        Certification memory cert = Certification({
            certHash: certHash,
            certificationType: certificationType,
            documentHash: documentHash,
            issueDate: block.timestamp,
            expiryDate: expiryDate,
            issuer: issuer,
            isValid: true
        });

        _certifications[productId].push(cert);

        emit CertificationLinked(productId, certHash, certificationType, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    function getOrigin(uint256 productId) external view originExists(productId) returns (ProductOrigin memory) {
        return _origins[productId];
    }

    function getHeritage(uint256 productId) external view returns (Heritage[] memory) {
        return _heritage[productId];
    }

    function getCertifications(uint256 productId) external view returns (Certification[] memory) {
        return _certifications[productId];
    }

    function verifyOrigin(uint256 productId, bytes32 originHash) external view returns (bool) {
        return _origins[productId].originDataHash == originHash;
    }

    function verifyHeritage(uint256 productId, bytes32 heritageHash) external view returns (bool) {
        Heritage[] memory heritages = _heritage[productId];
        for (uint256 i = 0; i < heritages.length; i++) {
            if (heritages[i].heritageHash == heritageHash && heritages[i].isActive) {
                return true;
            }
        }
        return false;
    }

    // ============ ADMIN FUNCTIONS ============
    function verifyOrigin(uint256 productId) external onlyRole(AUDITOR_ROLE) originExists(productId) {
        _origins[productId].isVerified = true;
    }
}
