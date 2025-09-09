// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title DateTimeLib
 * @dev Library for date/time calculations and agricultural season management
 * @author AgriTrace Team
 */
library DateTimeLib {
    // Constants
    uint256 private constant SECONDS_PER_DAY = 86400;
    uint256 private constant SECONDS_PER_HOUR = 3600;
    uint256 private constant DAYS_PER_YEAR = 365;
    uint256 private constant EPOCH_YEAR = 1970;

    struct DateTime {
        uint256 year;
        uint256 month;
        uint256 day;
        uint256 hour;
        uint256 minute;
        uint256 second;
    }

    struct Season {
        string name;
        uint256 startMonth;
        uint256 startDay;
        uint256 endMonth;
        uint256 endDay;
    }

    struct CropCycle {
        uint256 plantingTimestamp;
        uint256 expectedHarvestTimestamp;
        uint256 actualHarvestTimestamp;
        uint256 growingPeriodDays;
        bool isCompleted;
    }

    /**
     * @dev Convert timestamp to DateTime structure
     * @param timestamp Unix timestamp
     * @return dateTime DateTime structure
     */
    function timestampToDateTime(uint256 timestamp) internal pure returns (DateTime memory dateTime) {
        uint256 secondsInDay = timestamp % SECONDS_PER_DAY;
        uint256 daysSinceEpoch = timestamp / SECONDS_PER_DAY;
        
        dateTime.hour = secondsInDay / SECONDS_PER_HOUR;
        dateTime.minute = (secondsInDay % SECONDS_PER_HOUR) / 60;
        dateTime.second = secondsInDay % 60;
        
        // Simplified year/month/day calculation
        dateTime.year = EPOCH_YEAR + (daysSinceEpoch / DAYS_PER_YEAR);
        uint256 daysInYear = daysSinceEpoch % DAYS_PER_YEAR;
        
        // Simplified month calculation (30 days per month average)
        dateTime.month = (daysInYear / 30) + 1;
        dateTime.day = (daysInYear % 30) + 1;
        
        // Adjust if month > 12
        if (dateTime.month > 12) {
            dateTime.year++;
            dateTime.month = dateTime.month - 12;
        }
    }

    /**
     * @dev Calculate age in days
     * @param startTimestamp Start timestamp
     * @param endTimestamp End timestamp
     * @return ageInDays Age in days
     */
    function calculateAgeInDays(uint256 startTimestamp, uint256 endTimestamp) 
        internal 
        pure 
        returns (uint256 ageInDays) 
    {
        require(endTimestamp >= startTimestamp, "DateTimeLib: End timestamp must be after start");
        return (endTimestamp - startTimestamp) / SECONDS_PER_DAY;
    }

    /**
     * @dev Get current agricultural season
     * @param timestamp Current timestamp
     * @param hemisphere 0 for Northern, 1 for Southern hemisphere
     * @return seasonName Name of current season
     */
    function getCurrentSeason(uint256 timestamp, uint8 hemisphere) 
        internal 
        pure 
        returns (string memory seasonName) 
    {
        DateTime memory dt = timestampToDateTime(timestamp);
        uint256 monthDay = dt.month * 100 + dt.day;
        
        if (hemisphere == 0) { // Northern hemisphere
            if (monthDay >= 321 && monthDay < 621) return "Spring";
            if (monthDay >= 621 && monthDay < 923) return "Summer";
            if (monthDay >= 923 && monthDay < 1221) return "Autumn";
            return "Winter";
        } else { // Southern hemisphere
            if (monthDay >= 321 && monthDay < 621) return "Autumn";
            if (monthDay >= 621 && monthDay < 923) return "Winter";
            if (monthDay >= 923 && monthDay < 1221) return "Spring";
            return "Summer";
        }
    }

    /**
     * @dev Calculate optimal planting window
     * @param cropType Hash of crop type for lookup
     * @param location Hash of location for climate lookup
     * @param currentTimestamp Current timestamp
     * @return startWindow Start of planting window
     * @return endWindow End of planting window
     */
    function calculatePlantingWindow(
        bytes32 cropType,
        bytes32 location,
        uint256 currentTimestamp
    ) internal pure returns (uint256 startWindow, uint256 endWindow) {
        // Simplified calculation based on crop and location hash
        uint256 cropModifier = uint256(cropType) % 90; // 0-89 days offset
        uint256 locationModifier = uint256(location) % 30; // 0-29 days offset
        
        DateTime memory current = timestampToDateTime(currentTimestamp);
        
        // Base planting season start (simplified)
        uint256 baseStart = currentTimestamp + (cropModifier * SECONDS_PER_DAY);
        uint256 windowDuration = (30 + locationModifier) * SECONDS_PER_DAY; // 30-59 day window
        
        startWindow = baseStart;
        endWindow = baseStart + windowDuration;
    }

    /**
     * @dev Validate harvest timing
     * @param plantingTimestamp When crop was planted
     * @param harvestTimestamp When crop was harvested
     * @param expectedGrowingDays Expected growing period in days
     * @param tolerance Tolerance in days
     * @return isValid True if harvest timing is reasonable
     */
    function validateHarvestTiming(
        uint256 plantingTimestamp,
        uint256 harvestTimestamp,
        uint256 expectedGrowingDays,
        uint256 tolerance
    ) internal pure returns (bool isValid) {
        require(harvestTimestamp > plantingTimestamp, "DateTimeLib: Harvest must be after planting");
        
        uint256 actualGrowingDays = calculateAgeInDays(plantingTimestamp, harvestTimestamp);
        uint256 minDays = expectedGrowingDays > tolerance ? expectedGrowingDays - tolerance : 0;
        uint256 maxDays = expectedGrowingDays + tolerance;
        
        return actualGrowingDays >= minDays && actualGrowingDays <= maxDays;
    }

    /**
     * @dev Generate timestamp hash for verification
     * @param timestamp Timestamp to hash
     * @param eventType Type of event
     * @param location Location identifier
     * @return Timestamp verification hash
     */
    function generateTimestampHash(
        uint256 timestamp,
        string memory eventType,
        bytes32 location
    ) internal pure returns (bytes32) {
        DateTime memory dt = timestampToDateTime(timestamp);
        
        return keccak256(abi.encodePacked(
            timestamp,
            dt.year,
            dt.month,
            dt.day,
            dt.hour,
            eventType,
            location
        ));
    }

    /**
     * @dev Check if timestamp is within reasonable range
     * @param timestamp Timestamp to validate
     * @param currentTimestamp Current reference timestamp
     * @return isValid True if timestamp is reasonable
     */
    function validateTimestamp(uint256 timestamp, uint256 currentTimestamp) 
        internal 
        pure 
        returns (bool isValid) 
    {
        // Allow timestamps from 2020 onwards and up to 1 day in the future
        uint256 year2020 = 1577836800; // January 1, 2020
        uint256 futureLimit = currentTimestamp + SECONDS_PER_DAY;
        
        return timestamp >= year2020 && timestamp <= futureLimit;
    }

    /**
     * @dev Calculate crop maturity percentage
     * @param plantingTimestamp When crop was planted
     * @param currentTimestamp Current timestamp
     * @param expectedGrowingDays Expected growing period
     * @return maturityPercentage Maturity percentage (0-10000, where 10000 = 100%)
     */
    function calculateMaturityPercentage(
        uint256 plantingTimestamp,
        uint256 currentTimestamp,
        uint256 expectedGrowingDays
    ) internal pure returns (uint256 maturityPercentage) {
        require(currentTimestamp >= plantingTimestamp, "DateTimeLib: Current time before planting");
        
        uint256 actualGrowingDays = calculateAgeInDays(plantingTimestamp, currentTimestamp);
        
        if (actualGrowingDays >= expectedGrowingDays) {
            return 10000; // 100% mature
        }
        
        return (actualGrowingDays * 10000) / expectedGrowingDays;
    }

    /**
     * @dev Generate seasonal adjustment factor for quality
     * @param timestamp Assessment timestamp
     * @param hemisphere 0 for Northern, 1 for Southern
     * @return adjustmentFactor Factor to multiply quality score (0-12000, where 10000 = no adjustment)
     */
    function getSeasonalQualityAdjustment(uint256 timestamp, uint8 hemisphere) 
        internal 
        pure 
        returns (uint256 adjustmentFactor) 
    {
        string memory season = getCurrentSeason(timestamp, hemisphere);
        
        // Different seasons affect quality differently
        if (keccak256(bytes(season)) == keccak256(bytes("Summer"))) {
            return 11000; // +10% for peak growing season
        } else if (keccak256(bytes(season)) == keccak256(bytes("Spring"))) {
            return 10500; // +5% for growing season
        } else if (keccak256(bytes(season)) == keccak256(bytes("Autumn"))) {
            return 9500; // -5% for harvest season stress
        } else { // Winter
            return 8500; // -15% for off-season
        }
    }
}
