// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IStakeholder.sol";
import "../core/AgriAccessControl.sol";
import "../libraries/DateTimeLib.sol";

/**
 * @title ReputationSystem
 * @dev Trust scoring engine for stakeholder reputation management
 * @author AgriTrace Team
 */
contract ReputationSystem is AgriAccessControl {
    using DateTimeLib for uint256;

    // ============ EVENTS ============
    event ReputationUpdated(
        address indexed stakeholder,
        uint256 oldScore,
        uint256 newScore,
        string reason,
        address indexed updater,
        uint256 timestamp
    );

    event ReputationFactorAdded(
        address indexed stakeholder,
        string factorType,
        int256 impact,
        bytes32 evidenceHash,
        uint256 timestamp
    );

    event ReputationReview(
        address indexed stakeholder,
        address indexed reviewer,
        uint256 rating,
        string category,
        bytes32 reviewHash,
        uint256 timestamp
    );

    event ReputationPenalty(
        address indexed stakeholder,
        uint256 penaltyPoints,
        string reason,
        address indexed penalizer,
        uint256 timestamp
    );

    event ReputationBonus(
        address indexed stakeholder,
        uint256 bonusPoints,
        string reason,
        address indexed grantor,
        uint256 timestamp
    );

    // ============ STRUCTS ============
    struct ReputationScore {
        uint256 currentScore;
        uint256 baseScore;
        uint256 totalTransactions;
        uint256 successfulTransactions;
        uint256 penaltyPoints;
        uint256 bonusPoints;
        uint256 lastUpdated;
        bool isActive;
    }

    struct ReputationFactor {
        string factorType;
        int256 impact; // Can be negative or positive
        bytes32 evidenceHash;
        uint256 timestamp;
        address recorder;
        bool isActive;
    }

    struct Review {
        address reviewer;
        uint256 rating; // 1-5 stars
        string category;
        bytes32 reviewHash;
        uint256 timestamp;
        bool isVerified;
    }

    struct ReputationMetrics {
        uint256 qualityScore;
        uint256 timelinessScore;
        uint256 communicationScore;
        uint256 complianceScore;
        uint256 sustainabilityScore;
        uint256 lastCalculated;
    }

    // ============ STATE VARIABLES ============
    mapping(address => ReputationScore) private _reputationScores;
    mapping(address => ReputationFactor[]) private _reputationFactors;
    mapping(address => Review[]) private _reviews;
    mapping(address => ReputationMetrics) private _detailedMetrics;
    mapping(address => mapping(address => bool)) private _hasReviewed; // reviewer => stakeholder => bool
    mapping(string => uint256) private _factorWeights;

    IStakeholder public stakeholderContract;
    
    // Reputation constants
    uint256 public constant MIN_REPUTATION = 0;
    uint256 public constant MAX_REPUTATION = 1000;
    uint256 public constant DEFAULT_REPUTATION = 500;
    uint256 public constant PENALTY_THRESHOLD = 100;
    uint256 public constant REVIEW_WEIGHT = 10;
    uint256 public constant TRANSACTION_WEIGHT = 5;

    // ============ MODIFIERS ============
    modifier stakeholderExists(address stakeholder) {
        require(address(stakeholderContract) != address(0), "ReputationSystem: Stakeholder contract not set");
        require(stakeholderContract.isVerifiedAndIntact(stakeholder), "ReputationSystem: Stakeholder not verified");
        _;
    }

    modifier canUpdateReputation() {
        require(
            hasRole(AUDITOR_ROLE, msg.sender) ||
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
            hasRole(FARMER_ROLE, msg.sender) ||
            hasRole(PROCESSOR_ROLE, msg.sender) ||
            hasRole(DISTRIBUTOR_ROLE, msg.sender) ||
            hasRole(RETAILER_ROLE, msg.sender),
            "ReputationSystem: Not authorized to update reputation"
        );
        _;
    }

    modifier validRating(uint256 rating) {
        require(rating >= 1 && rating <= 5, "ReputationSystem: Rating must be 1-5");
        _;
    }

    modifier validScore(uint256 score) {
        require(score <= MAX_REPUTATION, "ReputationSystem: Score exceeds maximum");
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        // Initialize factor weights
        _factorWeights["QUALITY"] = 25;
        _factorWeights["TIMELINESS"] = 20;
        _factorWeights["COMMUNICATION"] = 15;
        _factorWeights["COMPLIANCE"] = 25;
        _factorWeights["SUSTAINABILITY"] = 15;
    }

    // ============ SETUP FUNCTIONS ============
    function setStakeholderContract(address _stakeholderContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakeholderContract != address(0), "ReputationSystem: Invalid stakeholder contract");
        stakeholderContract = IStakeholder(_stakeholderContract);
    }

    // ============ REPUTATION CALCULATION ============
    /**
     * @notice Initialize reputation for new stakeholder
     */
    function initializeReputation(address stakeholder) external stakeholderExists(stakeholder) {
        require(_reputationScores[stakeholder].lastUpdated == 0, "ReputationSystem: Reputation already initialized");

        _reputationScores[stakeholder] = ReputationScore({
            currentScore: DEFAULT_REPUTATION,
            baseScore: DEFAULT_REPUTATION,
            totalTransactions: 0,
            successfulTransactions: 0,
            penaltyPoints: 0,
            bonusPoints: 0,
            lastUpdated: block.timestamp,
            isActive: true
        });

        _detailedMetrics[stakeholder] = ReputationMetrics({
            qualityScore: DEFAULT_REPUTATION,
            timelinessScore: DEFAULT_REPUTATION,
            communicationScore: DEFAULT_REPUTATION,
            complianceScore: DEFAULT_REPUTATION,
            sustainabilityScore: DEFAULT_REPUTATION,
            lastCalculated: block.timestamp
        });

        _updateStakeholderReputation(stakeholder, DEFAULT_REPUTATION, "Initial reputation");
    }

    /**
     * @notice Record transaction outcome
     */
    function recordTransaction(
        address stakeholder,
        bool wasSuccessful,
        string calldata category
    ) external canUpdateReputation stakeholderExists(stakeholder) {
        ReputationScore storage score = _reputationScores[stakeholder];
        
        if (score.lastUpdated == 0) {
            this.initializeReputation(stakeholder);
        }

        score.totalTransactions++;
        if (wasSuccessful) {
            score.successfulTransactions++;
        }

        // Calculate impact based on success rate
        uint256 successRate = (score.successfulTransactions * 100) / score.totalTransactions;
        int256 impact = 0;
        
        if (successRate >= 95) {
            impact = 5; // Excellent
        } else if (successRate >= 85) {
            impact = 2; // Good
        } else if (successRate >= 70) {
            impact = 0; // Neutral
        } else if (successRate >= 50) {
            impact = -3; // Poor
        } else {
            impact = -10; // Very poor
        }

        _addReputationFactor(
            stakeholder,
            category,
            impact,
            keccak256(abi.encodePacked(stakeholder, wasSuccessful, block.timestamp))
        );

        _recalculateReputation(stakeholder);
    }

    /**
     * @notice Add reputation factor
     */
    function addReputationFactor(
        address stakeholder,
        string calldata factorType,
        int256 impact,
        bytes32 evidenceHash
    ) external canUpdateReputation stakeholderExists(stakeholder) {
        require(bytes(factorType).length > 0, "ReputationSystem: Factor type required");
        require(impact >= -100 && impact <= 100, "ReputationSystem: Impact out of range");
        require(evidenceHash != bytes32(0), "ReputationSystem: Evidence hash required");

        _addReputationFactor(stakeholder, factorType, impact, evidenceHash);
        _recalculateReputation(stakeholder);
    }

    /**
     * @notice Submit review for stakeholder
     */
    function submitReview(
        address stakeholder,
        uint256 rating,
        string calldata category,
        bytes32 reviewHash
    ) external validRating(rating) stakeholderExists(stakeholder) {
        require(msg.sender != stakeholder, "ReputationSystem: Cannot review self");
        require(!_hasReviewed[msg.sender][stakeholder], "ReputationSystem: Already reviewed");
        require(reviewHash != bytes32(0), "ReputationSystem: Review hash required");
        require(bytes(category).length > 0, "ReputationSystem: Category required");

        Review memory review = Review({
            reviewer: msg.sender,
            rating: rating,
            category: category,
            reviewHash: reviewHash,
            timestamp: block.timestamp,
            isVerified: false
        });

        _reviews[stakeholder].push(review);
        _hasReviewed[msg.sender][stakeholder] = true;

        // Calculate impact from review
        int256 impact = int256(rating * REVIEW_WEIGHT) - int256(REVIEW_WEIGHT * 3); // Normalize around 3-star rating

        _addReputationFactor(
            stakeholder,
            string(abi.encodePacked("REVIEW_", category)),
            impact,
            reviewHash
        );

        _recalculateReputation(stakeholder);

        emit ReputationReview(stakeholder, msg.sender, rating, category, reviewHash, block.timestamp);
    }

    /**
     * @notice Apply penalty to stakeholder
     */
    function applyPenalty(
        address stakeholder,
        uint256 penaltyPoints,
        string calldata reason
    ) external onlyRole(AUDITOR_ROLE) stakeholderExists(stakeholder) {
        require(penaltyPoints > 0 && penaltyPoints <= PENALTY_THRESHOLD, "ReputationSystem: Invalid penalty points");
        require(bytes(reason).length > 0, "ReputationSystem: Reason required");

        ReputationScore storage score = _reputationScores[stakeholder];
        score.penaltyPoints += penaltyPoints;

        _addReputationFactor(
            stakeholder,
            "PENALTY",
            -int256(penaltyPoints),
            keccak256(abi.encodePacked(reason, block.timestamp))
        );

        _recalculateReputation(stakeholder);

        emit ReputationPenalty(stakeholder, penaltyPoints, reason, msg.sender, block.timestamp);
    }

    /**
     * @notice Grant bonus to stakeholder
     */
    function grantBonus(
        address stakeholder,
        uint256 bonusPoints,
        string calldata reason
    ) external onlyRole(AUDITOR_ROLE) stakeholderExists(stakeholder) {
        require(bonusPoints > 0 && bonusPoints <= 50, "ReputationSystem: Invalid bonus points");
        require(bytes(reason).length > 0, "ReputationSystem: Reason required");

        ReputationScore storage score = _reputationScores[stakeholder];
        score.bonusPoints += bonusPoints;

        _addReputationFactor(
            stakeholder,
            "BONUS",
            int256(bonusPoints),
            keccak256(abi.encodePacked(reason, block.timestamp))
        );

        _recalculateReputation(stakeholder);

        emit ReputationBonus(stakeholder, bonusPoints, reason, msg.sender, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get reputation score
     */
    function getReputationScore(address stakeholder) external view returns (uint256) {
        return _reputationScores[stakeholder].currentScore;
    }

    /**
     * @notice Get detailed reputation score
     */
    function getDetailedReputation(address stakeholder) 
        external view 
        returns (ReputationScore memory) {
        return _reputationScores[stakeholder];
    }

    /**
     * @notice Get reputation metrics
     */
    function getReputationMetrics(address stakeholder) 
        external view 
        returns (ReputationMetrics memory) {
        return _detailedMetrics[stakeholder];
    }

    /**
     * @notice Get reputation factors
     */
    function getReputationFactors(address stakeholder) 
        external view 
        returns (ReputationFactor[] memory) {
        return _reputationFactors[stakeholder];
    }

    /**
     * @notice Get reviews for stakeholder
     */
    function getReviews(address stakeholder) external view returns (Review[] memory) {
        return _reviews[stakeholder];
    }

    /**
     * @notice Calculate average rating
     */
    function getAverageRating(address stakeholder) external view returns (uint256) {
        Review[] memory reviews = _reviews[stakeholder];
        if (reviews.length == 0) return 0;

        uint256 totalRating = 0;
        uint256 validReviews = 0;

        for (uint256 i = 0; i < reviews.length; i++) {
            if (reviews[i].isVerified || block.timestamp <= reviews[i].timestamp + 30 days) {
                totalRating += reviews[i].rating;
                validReviews++;
            }
        }

        return validReviews > 0 ? (totalRating * 100) / validReviews : 0; // Return percentage
    }

    /**
     * @notice Get success rate
     */
    function getSuccessRate(address stakeholder) external view returns (uint256) {
        ReputationScore memory score = _reputationScores[stakeholder];
        if (score.totalTransactions == 0) return 0;
        return (score.successfulTransactions * 100) / score.totalTransactions;
    }

    /**
     * @notice Check if stakeholder can review another
     */
    function canReview(address reviewer, address stakeholder) external view returns (bool) {
        return !_hasReviewed[reviewer][stakeholder] && reviewer != stakeholder;
    }

    /**
     * @notice Get reputation tier
     */
    function getReputationTier(address stakeholder) external view returns (string memory) {
        uint256 score = _reputationScores[stakeholder].currentScore;
        
        if (score >= 900) return "PLATINUM";
        if (score >= 800) return "GOLD";
        if (score >= 700) return "SILVER";
        if (score >= 600) return "BRONZE";
        if (score >= 500) return "STANDARD";
        return "PROBATION";
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Verify review
     */
    function verifyReview(
        address stakeholder,
        uint256 reviewIndex
    ) external onlyRole(AUDITOR_ROLE) {
        require(reviewIndex < _reviews[stakeholder].length, "ReputationSystem: Invalid review index");
        
        _reviews[stakeholder][reviewIndex].isVerified = true;
    }

    /**
     * @notice Update factor weight
     */
    function updateFactorWeight(
        string calldata factorType,
        uint256 weight
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(weight <= 100, "ReputationSystem: Weight cannot exceed 100");
        require(bytes(factorType).length > 0, "ReputationSystem: Factor type required");
        
        _factorWeights[factorType] = weight;
    }

    /**
     * @notice Recalculate all reputations
     */
    function recalculateAllReputations(address[] calldata stakeholders) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) {
        
        for (uint256 i = 0; i < stakeholders.length; i++) {
            if (_reputationScores[stakeholders[i]].isActive) {
                _recalculateReputation(stakeholders[i]);
            }
        }
    }

    /**
     * @notice Reset reputation (emergency only)
     */
    function resetReputation(address stakeholder, string calldata reason) 
        external 
        onlyRole(EMERGENCY_ROLE) {
        require(bytes(reason).length > 0, "ReputationSystem: Reason required");
        
        _reputationScores[stakeholder].currentScore = DEFAULT_REPUTATION;
        _reputationScores[stakeholder].penaltyPoints = 0;
        _reputationScores[stakeholder].bonusPoints = 0;
        _reputationScores[stakeholder].lastUpdated = block.timestamp;
        
        _updateStakeholderReputation(stakeholder, DEFAULT_REPUTATION, reason);
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Add reputation factor
     */
    function _addReputationFactor(
        address stakeholder,
        string memory factorType,
        int256 impact,
        bytes32 evidenceHash
    ) internal {
        ReputationFactor memory factor = ReputationFactor({
            factorType: factorType,
            impact: impact,
            evidenceHash: evidenceHash,
            timestamp: block.timestamp,
            recorder: msg.sender,
            isActive: true
        });

        _reputationFactors[stakeholder].push(factor);

        emit ReputationFactorAdded(stakeholder, factorType, impact, evidenceHash, block.timestamp);
    }

    /**
     * @dev Recalculate reputation score
     */
    function _recalculateReputation(address stakeholder) internal {
        ReputationScore storage score = _reputationScores[stakeholder];
        ReputationFactor[] memory factors = _reputationFactors[stakeholder];

        int256 totalImpact = 0;
        uint256 factorCount = 0;

        // Calculate weighted impact
        for (uint256 i = 0; i < factors.length; i++) {
            if (factors[i].isActive && block.timestamp <= factors[i].timestamp + 180 days) {
                uint256 weight = _factorWeights[factors[i].factorType];
                if (weight == 0) weight = 10; // Default weight
                
                totalImpact += factors[i].impact * int256(weight) / 10;
                factorCount++;
            }
        }

        // Apply penalties and bonuses
        totalImpact -= int256(score.penaltyPoints);
        totalImpact += int256(score.bonusPoints);

        // Calculate new score
        int256 newScore = int256(score.baseScore) + totalImpact;
        
        // Ensure score stays within bounds
        if (newScore < int256(MIN_REPUTATION)) {
            newScore = int256(MIN_REPUTATION);
        } else if (newScore > int256(MAX_REPUTATION)) {
            newScore = int256(MAX_REPUTATION);
        }

        uint256 oldScore = score.currentScore;
        score.currentScore = uint256(newScore);
        score.lastUpdated = block.timestamp;

        _updateStakeholderReputation(stakeholder, uint256(newScore), "Automatic recalculation");

        emit ReputationUpdated(stakeholder, oldScore, uint256(newScore), "Recalculated", address(this), block.timestamp);
    }

    /**
     * @dev Update reputation in stakeholder contract
     */
    function _updateStakeholderReputation(
        address stakeholder,
        uint256 newScore,
        string memory reason
    ) internal {
        if (address(stakeholderContract) != address(0)) {
            bytes32 reputationHash = keccak256(abi.encodePacked(
                stakeholder,
                newScore,
                reason,
                block.timestamp
            ));
            
            stakeholderContract.updateReputationHash(stakeholder, newScore, reputationHash);
        }
    }
}
