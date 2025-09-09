// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IMLOracle
 * @dev Interface for ML model results and photo verification hashes
 * @author AgriTrace Team
 */
interface IMLOracle {
    // ============ EVENTS ============
    event MLResultHashSubmitted(
        bytes32 indexed resultId,
        string indexed modelType,
        uint256 indexed productId,
        bytes32 resultHash,
        uint256 confidence,
        uint256 timestamp
    );
    
    event PhotoHashSubmitted(
        uint256 indexed productId,
        uint8 indexed stage,
        bytes32 indexed photoHash,
        string damageType,
        uint8 severity,
        uint256 timestamp
    );
    
    event QualityScoreHashUpdated(
        uint256 indexed productId,
        bytes32 indexed scoreHash,
        uint256 score,
        uint256 confidence,
        uint256 timestamp
    );

    event WeatherDataHashLinked(
        uint256 indexed productId,
        bytes32 indexed weatherHash,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct MLResultHash {
        bytes32 resultId;
        string modelType;
        uint256 productId;
        bytes32 resultDataHash;
        bytes32 inputDataHash;
        uint256 score;
        uint256 confidence;
        string modelVersion;
        uint256 timestamp;
        address submitter;
        bool isValidated;
    }

    struct PhotoEvidence {
        bytes32 photoHash;
        uint256 productId;
        uint8 stage;
        string damageType;
        uint8 severity;
        uint256 timestamp;
        address submitter;
        bool isProcessed;
        bytes32 analysisResultHash;
    }

    struct QualityScoreHash {
        bytes32 scoreDataHash;
        uint256 score;
        uint256 confidence;
        bytes32 photoHash;
        bytes32 weatherHash;
        uint256 timestamp;
        bool isFinal;
    }

    // ============ CORE FUNCTIONS ============
    function submitMLResultHash(string calldata modelType, uint256 productId, bytes32 resultDataHash, bytes32 inputDataHash, uint256 score, uint256 confidence, string calldata modelVersion) external returns (bytes32 resultId);
    function submitPhotoHash(uint256 productId, uint8 stage, bytes32 photoHash, string calldata damageType, uint8 severity) external;
    function updateQualityScoreHash(uint256 productId, bytes32 scoreDataHash, uint256 score, uint256 confidence, bytes32 photoHash, bytes32 weatherHash) external;
    function linkWeatherDataHash(uint256 productId, bytes32 weatherDataHash) external;
    function getMLResultHash(bytes32 resultId) external view returns (MLResultHash memory);
    function getPhotoEvidence(uint256 productId, uint8 stage) external view returns (PhotoEvidence[] memory);
    function getQualityScoreHistory(uint256 productId) external view returns (QualityScoreHash[] memory);
    function verifyMLResultIntegrity(bytes32 resultId, bytes32 currentResultHash) external view returns (bool isValid);
    function verifyPhotoIntegrity(uint256 productId, uint8 stage, bytes32 photoHash) external view returns (bool isValid);
    function getLatestQualityScore(uint256 productId) external view returns (QualityScoreHash memory);
    function validateMLResult(bytes32 resultId, bool isValid) external;
}
