// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../core/AgriAccessControl.sol";
import "../interfaces/IStakeholder.sol";

/**
 * @title ConsumerReviews
 * @dev Consumer feedback system for products
 * @author AgriTrace Team
 */
contract ConsumerReviews is AgriAccessControl {

    // ============ EVENTS ============
    event ReviewSubmitted(
        uint256 indexed productId,
        bytes32 indexed reviewHash,
        address indexed reviewer,
        uint8 rating,
        uint256 timestamp
    );

    event ReviewVerified(
        uint256 indexed productId,
        bytes32 indexed reviewHash,
        address verifier,
        uint256 timestamp
    );

    event ReviewFlagged(
        uint256 indexed productId,
        bytes32 indexed reviewHash,
        address flagger,
        string reason,
        uint256 timestamp
    );

    event ReviewRemoved(
        uint256 indexed productId,
        bytes32 indexed reviewHash,
        string reason,
        uint256 timestamp
    );

    // ============ ENUMS ============
    enum ReviewStatus {
        PENDING,     // 0 - Awaiting moderation
        APPROVED,    // 1 - Approved and visible
        FLAGGED,     // 2 - Flagged for review
        REMOVED      // 3 - Removed by moderator
    }

    // ============ STRUCTS ============
    struct Review {
        bytes32 reviewHash;
        uint256 productId;
        address reviewer;
        uint8 rating; // 1-5 stars
        bytes32 commentHash;
        uint256 timestamp;
        ReviewStatus status;
        bool isVerifiedPurchase;
        uint256 helpfulVotes;
        uint256 reportCount;
        bool isVerified;
    }

    struct ReviewSummary {
        uint256 totalReviews;
        uint256 averageRating;
        uint256 fiveStarCount;
        uint256 fourStarCount;
        uint256 threeStarCount;
        uint256 twoStarCount;
        uint256 oneStarCount;
        uint256 lastUpdated;
    }

    struct ReviewerProfile {
        address reviewer;
        uint256 totalReviews;
        uint256 verifiedReviews;
        uint256 helpfulVotes;
        uint256 reputation;
        bool isVerifiedBuyer;
        uint256 joinDate;
    }

    struct ReviewInteraction {
        address user;
        bytes32 reviewHash;
        bool isHelpful;
        bool isReported;
        string reportReason;
        uint256 timestamp;
    }

    // ============ STATE VARIABLES ============
    mapping(uint256 => Review[]) private _productReviews;
    mapping(bytes32 => Review) private _reviewByHash;
    mapping(uint256 => ReviewSummary) private _reviewSummaries;
    mapping(address => ReviewerProfile) private _reviewerProfiles;
    mapping(address => uint256[]) private _userReviews;
    mapping(bytes32 => ReviewInteraction[]) private _reviewInteractions;
    mapping(address => mapping(uint256 => bool)) private _hasReviewed;
    
    // Contract references
    IStakeholder public stakeholderContract;
    address public qrCodeManagerContract;
    
    // Review parameters
    uint256 public constant MIN_RATING = 1;
    uint256 public constant MAX_RATING = 5;
    uint256 public constant REVIEW_COOLDOWN = 24 hours;
    uint256 public constant MIN_REPUTATION_TO_REVIEW = 10;

    // ============ MODIFIERS ============
    modifier validProductId(uint256 productId) {
        require(productId > 0, "ConsumerReviews: Invalid product ID");
        _;
    }

    modifier validRating(uint8 rating) {
        require(rating >= MIN_RATING && rating <= MAX_RATING, "ConsumerReviews: Invalid rating");
        _;
    }

    modifier reviewExists(bytes32 reviewHash) {
        require(_reviewByHash[reviewHash].reviewHash != bytes32(0), "ConsumerReviews: Review not found");
        _;
    }

    modifier onlyReviewer(bytes32 reviewHash) {
        require(_reviewByHash[reviewHash].reviewer == msg.sender, "ConsumerReviews: Not review author");
        _;
    }

    modifier canReview() {
        require(
            address(stakeholderContract) == address(0) || 
            stakeholderContract.isVerifiedAndIntact(msg.sender) ||
            hasRole(CONSUMER_ROLE, msg.sender),
            "ConsumerReviews: Not authorized to review"
        );
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

    function setQRCodeManagerContract(address _qrCodeManagerContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        qrCodeManagerContract = _qrCodeManagerContract;
    }

    // ============ REVIEW FUNCTIONS ============
    /**
     * @notice Submit product review
     */
    function submitReview(
        uint256 productId,
        uint8 rating,
        bytes32 commentHash,
        bool isVerifiedPurchase
    ) external validProductId(productId) validRating(rating) canReview returns (bytes32 reviewHash) {
        require(commentHash != bytes32(0), "ConsumerReviews: Comment hash required");
        require(!_hasReviewed[msg.sender][productId], "ConsumerReviews: Already reviewed this product");

        // Check reviewer reputation if stakeholder contract is set
        if (address(stakeholderContract) != address(0)) {
            uint256 reputation = stakeholderContract.getReputation(msg.sender);
            require(reputation >= MIN_REPUTATION_TO_REVIEW, "ConsumerReviews: Insufficient reputation");
        }

        reviewHash = keccak256(abi.encodePacked(
            productId,
            msg.sender,
            rating,
            commentHash,
            block.timestamp
        ));

        Review memory review = Review({
            reviewHash: reviewHash,
            productId: productId,
            reviewer: msg.sender,
            rating: rating,
            commentHash: commentHash,
            timestamp: block.timestamp,
            status: ReviewStatus.PENDING,
            isVerifiedPurchase: isVerifiedPurchase,
            helpfulVotes: 0,
            reportCount: 0,
            isVerified: false
        });

        _productReviews[productId].push(review);
        _reviewByHash[reviewHash] = review;
        _userReviews[msg.sender].push(productId);
        _hasReviewed[msg.sender][productId] = true;

        // Update reviewer profile
        _updateReviewerProfile(msg.sender, isVerifiedPurchase);

        // Update review summary
        _updateReviewSummary(productId);

        emit ReviewSubmitted(productId, reviewHash, msg.sender, rating, block.timestamp);
        return reviewHash;
    }

    /**
     * @notice Vote review as helpful
     */
    function voteHelpful(bytes32 reviewHash, bool isHelpful) external reviewExists(reviewHash) {
        Review storage review = _reviewByHash[reviewHash];
        require(review.reviewer != msg.sender, "ConsumerReviews: Cannot vote on own review");

        // Check if user already interacted with this review
        ReviewInteraction[] storage interactions = _reviewInteractions[reviewHash];
        bool hasInteracted = false;
        
        for (uint256 i = 0; i < interactions.length; i++) {
            if (interactions[i].user == msg.sender) {
                // Update existing interaction
                interactions[i].isHelpful = isHelpful;
                interactions[i].timestamp = block.timestamp;
                hasInteracted = true;
                break;
            }
        }

        if (!hasInteracted) {
            // Create new interaction
            ReviewInteraction memory interaction = ReviewInteraction({
                user: msg.sender,
                reviewHash: reviewHash,
                isHelpful: isHelpful,
                isReported: false,
                reportReason: "",
                timestamp: block.timestamp
            });
            interactions.push(interaction);
        }

        // Recalculate helpful votes
        _recalculateHelpfulVotes(reviewHash);
    }

    /**
     * @notice Report review
     */
    function reportReview(bytes32 reviewHash, string calldata reason) external reviewExists(reviewHash) {
        require(bytes(reason).length > 0, "ConsumerReviews: Report reason required");
        
        Review storage review = _reviewByHash[reviewHash];
        require(review.reviewer != msg.sender, "ConsumerReviews: Cannot report own review");

        ReviewInteraction memory interaction = ReviewInteraction({
            user: msg.sender,
            reviewHash: reviewHash,
            isHelpful: false,
            isReported: true,
            reportReason: reason,
            timestamp: block.timestamp
        });

        _reviewInteractions[reviewHash].push(interaction);
        review.reportCount++;

        // Auto-flag if too many reports
        if (review.reportCount >= 5) {
            review.status = ReviewStatus.FLAGGED;
        }

        emit ReviewFlagged(review.productId, reviewHash, msg.sender, reason, block.timestamp);
    }

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Get approved reviews for product
     */
    function getProductReviews(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (Review[] memory) {
        
        Review[] memory allReviews = _productReviews[productId];
        Review[] memory temp = new Review[](allReviews.length);
        uint256 count = 0;

        for (uint256 i = 0; i < allReviews.length; i++) {
            if (allReviews[i].status == ReviewStatus.APPROVED) {
                temp[count] = allReviews[i];
                count++;
            }
        }

        Review[] memory result = new Review[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }

        return result;
    }

    /**
     * @notice Get review by hash
     */
    function getReview(bytes32 reviewHash) external view reviewExists(reviewHash) returns (Review memory) {
        return _reviewByHash[reviewHash];
    }

    /**
     * @notice Get review summary for product
     */
    function getReviewSummary(uint256 productId) 
        external view 
        validProductId(productId) 
        returns (ReviewSummary memory) {
        return _reviewSummaries[productId];
    }

    /**
     * @notice Get reviewer profile
     */
    function getReviewerProfile(address reviewer) external view returns (ReviewerProfile memory) {
        return _reviewerProfiles[reviewer];
    }

    /**
     * @notice Get user's reviews
     */
    function getUserReviews(address user) external view returns (uint256[] memory) {
        return _userReviews[user];
    }

    /**
     * @notice Get review interactions
     */
    function getReviewInteractions(bytes32 reviewHash) 
        external view 
        reviewExists(reviewHash) 
        returns (ReviewInteraction[] memory) {
        return _reviewInteractions[reviewHash];
    }

    /**
     * @notice Check if user has reviewed product
     */
    function hasUserReviewed(address user, uint256 productId) external view returns (bool) {
        return _hasReviewed[user][productId];
    }

    /**
     * @notice Get pending reviews for moderation
     */
    function getPendingReviews() external view returns (Review[] memory) {
        // This is a simplified implementation
        // In production, maintain a separate mapping for efficiency
        uint256 totalPending = 0;
        
        // Count pending reviews across all products
        // Implementation would be optimized in production
        
        Review[] memory result = new Review[](totalPending);
        return result;
    }

    /**
     * @notice Verify review integrity
     */
    function verifyReviewIntegrity(
        bytes32 reviewHash,
        bytes32 currentCommentHash
    ) external view reviewExists(reviewHash) returns (bool) {
        return _reviewByHash[reviewHash].commentHash == currentCommentHash;
    }

    // ============ ADMIN FUNCTIONS ============
    /**
     * @notice Approve review
     */
    function approveReview(bytes32 reviewHash) external onlyRole(AUDITOR_ROLE) reviewExists(reviewHash) {
        Review storage review = _reviewByHash[reviewHash];
        review.status = ReviewStatus.APPROVED;
        review.isVerified = true;

        // Update review in product array
        _updateReviewInProductArray(review.productId, reviewHash, ReviewStatus.APPROVED);
        
        // Update summary
        _updateReviewSummary(review.productId);

        emit ReviewVerified(review.productId, reviewHash, msg.sender, block.timestamp);
    }

    /**
     * @notice Remove review
     */
    function removeReview(bytes32 reviewHash, string calldata reason) 
        external 
        onlyRole(AUDITOR_ROLE) 
        reviewExists(reviewHash) {
        
        require(bytes(reason).length > 0, "ConsumerReviews: Removal reason required");
        
        Review storage review = _reviewByHash[reviewHash];
        review.status = ReviewStatus.REMOVED;

        // Update review in product array
        _updateReviewInProductArray(review.productId, reviewHash, ReviewStatus.REMOVED);
        
        // Update summary
        _updateReviewSummary(review.productId);

        emit ReviewRemoved(review.productId, reviewHash, reason, block.timestamp);
    }

    /**
     * @notice Batch approve reviews
     */
    function batchApproveReviews(bytes32[] calldata reviewHashes) external onlyRole(AUDITOR_ROLE) {
        for (uint256 i = 0; i < reviewHashes.length; i++) {
            if (_reviewByHash[reviewHashes[i]].reviewHash != bytes32(0)) {
                this.approveReview(reviewHashes[i]);
            }
        }
    }

    // ============ INTERNAL FUNCTIONS ============
    /**
     * @dev Update reviewer profile
     */
    function _updateReviewerProfile(address reviewer, bool isVerifiedPurchase) internal {
        ReviewerProfile storage profile = _reviewerProfiles[reviewer];
        
        if (profile.joinDate == 0) {
            profile.reviewer = reviewer;
            profile.joinDate = block.timestamp;
        }
        
        profile.totalReviews++;
        if (isVerifiedPurchase) {
            profile.verifiedReviews++;
            profile.isVerifiedBuyer = true;
        }
        
        // Calculate reputation based on verified reviews ratio
        if (profile.totalReviews > 0) {
            profile.reputation = (profile.verifiedReviews * 100) / profile.totalReviews;
        }
    }

    /**
     * @dev Update review summary
     */
    function _updateReviewSummary(uint256 productId) internal {
        Review[] memory reviews = _productReviews[productId];
        ReviewSummary storage summary = _reviewSummaries[productId];
        
        summary.totalReviews = 0;
        summary.fiveStarCount = 0;
        summary.fourStarCount = 0;
        summary.threeStarCount = 0;
        summary.twoStarCount = 0;
        summary.oneStarCount = 0;
        
        uint256 totalRating = 0;
        
        for (uint256 i = 0; i < reviews.length; i++) {
            if (reviews[i].status == ReviewStatus.APPROVED) {
                summary.totalReviews++;
                totalRating += reviews[i].rating;
                
                if (reviews[i].rating == 5) summary.fiveStarCount++;
                else if (reviews[i].rating == 4) summary.fourStarCount++;
                else if (reviews[i].rating == 3) summary.threeStarCount++;
                else if (reviews[i].rating == 2) summary.twoStarCount++;
                else if (reviews[i].rating == 1) summary.oneStarCount++;
            }
        }
        
        summary.averageRating = summary.totalReviews > 0 ? totalRating / summary.totalReviews : 0;
        summary.lastUpdated = block.timestamp;
    }

    /**
     * @dev Recalculate helpful votes
     */
    function _recalculateHelpfulVotes(bytes32 reviewHash) internal {
        ReviewInteraction[] memory interactions = _reviewInteractions[reviewHash];
        uint256 helpfulCount = 0;
        
        for (uint256 i = 0; i < interactions.length; i++) {
            if (interactions[i].isHelpful && !interactions[i].isReported) {
                helpfulCount++;
            }
        }
        
        _reviewByHash[reviewHash].helpfulVotes = helpfulCount;
        
        // Update reviewer profile helpful votes
        address reviewer = _reviewByHash[reviewHash].reviewer;
        _reviewerProfiles[reviewer].helpfulVotes = helpfulCount;
    }

    /**
     * @dev Update review status in product array
     */
    function _updateReviewInProductArray(uint256 productId, bytes32 reviewHash, ReviewStatus newStatus) internal {
        Review[] storage reviews = _productReviews[productId];
        
        for (uint256 i = 0; i < reviews.length; i++) {
            if (reviews[i].reviewHash == reviewHash) {
                reviews[i].status = newStatus;
                if (newStatus == ReviewStatus.APPROVED) {
                    reviews[i].isVerified = true;
                }
                break;
            }
        }
    }
}