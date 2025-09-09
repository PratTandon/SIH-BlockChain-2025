// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IHashVerification
 * @dev Interface for data integrity verification and QR code generation support
 * @author AgriTrace Team
 */
interface IHashVerification {
    // ============ EVENTS ============
    event IntegrityCheckPerformed(
        uint256 indexed productId,
        address indexed checker,
        bool isValid,
        uint256 timestamp
    );
    
    event QRDataGenerated(
        uint256 indexed productId,
        bytes32 indexed qrDataHash,
        uint256 timestamp
    );
    
    event ConsumerVerification(
        uint256 indexed productId,
        address indexed consumer,
        bool verificationPassed,
        uint256 timestamp
    );

    event TamperDetected(
        uint256 indexed productId,
        uint8 stageAffected,
        bytes32 expectedHash,
        bytes32 foundHash,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct VerificationResult {
        bool isValid;
        uint256 productId;
        uint8 stagesVerified;
        uint8 totalStages;
        bytes32[] hashChain;
        uint256 verificationTimestamp;
        address verifier;
    }

    struct QRVerificationData {
        uint256 productId;
        string batchId;
        bytes32 latestHash;
        uint8 currentStage;
        uint256 totalStages;
        bool integrityStatus;
        uint256 lastUpdated;
    }

    struct TamperReport {
        uint256 productId;
        uint8 stage;
        bytes32 expectedHash;
        bytes32 actualHash;
        uint256 detectionTime;
        address reporter;
        bool isResolved;
    }

    // ============ CORE FUNCTIONS ============
    function performIntegrityCheck(uint256 productId, bytes32[] calldata stageHashes) external returns (VerificationResult memory);
    function generateQRVerificationData(uint256 productId) external view returns (QRVerificationData memory);
    function verifyProductAuthenticity(uint256 productId, bytes32[] calldata providedHashes) external view returns (bool isAuthentic);
    function batchVerifyProducts(uint256[] calldata productIds, bytes32[][] calldata allStageHashes) external view returns (VerificationResult[] memory);
    function reportTamperDetection(uint256 productId, uint8 stage, bytes32 expectedHash, bytes32 actualHash) external;
    function getTamperReports(uint256 productId) external view returns (TamperReport[] memory);
    function hasIntegrityViolations(uint256 productId) external view returns (bool hasViolations);
    function calculateCombinedHash(bytes32[] calldata dataHashes) external pure returns (bytes32 combinedHash);
    function verifyHashChainOrder(uint256 productId) external view returns (bool isChronological);
    function getVerificationStats(uint256 fromTimestamp, uint256 toTimestamp) external view returns (uint256 totalChecks, uint256 passedChecks, uint256 failedChecks);
}
