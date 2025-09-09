// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title GeolocationLib
 * @dev Library for GPS coordinate validation and location-based calculations
 * @author AgriTrace Team
 */
library GeolocationLib {
    struct GPSCoordinate {
        int256 latitude;  // Latitude * 1000000 (6 decimal places)
        int256 longitude; // Longitude * 1000000 (6 decimal places)
        uint256 accuracy; // Accuracy in meters
        uint256 timestamp;
    }

    struct LocationBounds {
        int256 minLatitude;
        int256 maxLatitude;
        int256 minLongitude;
        int256 maxLongitude;
    }

    // Constants for calculations
    int256 private constant EARTH_RADIUS = 6371000; // Earth radius in meters
    int256 private constant MAX_LATITUDE = 90000000;   // 90 degrees * 1000000
    int256 private constant MIN_LATITUDE = -90000000;  // -90 degrees * 1000000
    int256 private constant MAX_LONGITUDE = 180000000; // 180 degrees * 1000000
    int256 private constant MIN_LONGITUDE = -180000000; // -180 degrees * 1000000

    /**
     * @dev Validate GPS coordinates
     * @param coordinate GPS coordinate to validate
     * @return isValid True if coordinates are within valid range
     */
    function validateCoordinates(GPSCoordinate memory coordinate) internal pure returns (bool isValid) {
        return (
            coordinate.latitude >= MIN_LATITUDE &&
            coordinate.latitude <= MAX_LATITUDE &&
            coordinate.longitude >= MIN_LONGITUDE &&
            coordinate.longitude <= MAX_LONGITUDE &&
            coordinate.accuracy > 0 &&
            coordinate.accuracy <= 1000 // Max 1km accuracy
        );
    }

    /**
     * @dev Check if coordinate is within specified bounds
     * @param coordinate GPS coordinate to check
     * @param bounds Location bounds
     * @return isWithin True if coordinate is within bounds
     */
    function isWithinBounds(
        GPSCoordinate memory coordinate, 
        LocationBounds memory bounds
    ) internal pure returns (bool isWithin) {
        return (
            coordinate.latitude >= bounds.minLatitude &&
            coordinate.latitude <= bounds.maxLatitude &&
            coordinate.longitude >= bounds.minLongitude &&
            coordinate.longitude <= bounds.maxLongitude
        );
    }

    /**
     * @dev Calculate distance between two GPS coordinates (Haversine formula)
     * @param coord1 First GPS coordinate
     * @param coord2 Second GPS coordinate
     * @return distance Distance in meters
     */
    function calculateDistance(
        GPSCoordinate memory coord1,
        GPSCoordinate memory coord2
    ) internal pure returns (uint256 distance) {
        require(validateCoordinates(coord1), "GeolocationLib: Invalid first coordinate");
        require(validateCoordinates(coord2), "GeolocationLib: Invalid second coordinate");

        // Convert to radians (multiply by π/180)
        int256 lat1Rad = (coord1.latitude * 314159) / (180 * 100000);
        int256 lat2Rad = (coord2.latitude * 314159) / (180 * 100000);
        int256 deltaLatRad = ((coord2.latitude - coord1.latitude) * 314159) / (180 * 100000);
        int256 deltaLonRad = ((coord2.longitude - coord1.longitude) * 314159) / (180 * 100000);

        // Simplified Haversine calculation (approximation for smart contract)
        int256 a = (deltaLatRad * deltaLatRad / 1000000) + 
                   (deltaLonRad * deltaLonRad / 1000000);
        
        int256 c = 2 * sqrtApprox(a);
        distance = uint256((EARTH_RADIUS * c) / 1000000);
    }

    /**
     * @dev Generate location hash for verification
     * @param coordinate GPS coordinate
     * @param locationName Human-readable location name
     * @return Location data hash
     */
    function generateLocationHash(
        GPSCoordinate memory coordinate,
        string memory locationName
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            coordinate.latitude,
            coordinate.longitude,
            coordinate.accuracy,
            coordinate.timestamp,
            locationName
        ));
    }

    /**
     * @dev Check if movement is reasonable for agricultural transport
     * @param startCoord Starting GPS coordinate
     * @param endCoord Ending GPS coordinate
     * @param timeElapsed Time elapsed in seconds
     * @param maxSpeed Maximum reasonable speed in m/s
     * @return isReasonable True if movement is within reasonable limits
     */
    function validateMovement(
        GPSCoordinate memory startCoord,
        GPSCoordinate memory endCoord,
        uint256 timeElapsed,
        uint256 maxSpeed
    ) internal pure returns (bool isReasonable) {
        require(timeElapsed > 0, "GeolocationLib: Time elapsed must be positive");
        
        uint256 distance = calculateDistance(startCoord, endCoord);
        uint256 averageSpeed = distance / timeElapsed;
        
        return averageSpeed <= maxSpeed;
    }

    /**
     * @dev Create location bounds around a center point
     * @param center Center GPS coordinate
     * @param radiusMeters Radius in meters
     * @return bounds Location bounds structure
     */
    function createBounds(
        GPSCoordinate memory center,
        uint256 radiusMeters
    ) internal pure returns (LocationBounds memory bounds) {
        require(validateCoordinates(center), "GeolocationLib: Invalid center coordinate");
        
        // Approximate conversion: 1 degree ≈ 111km
        // For precision, using 111000 meters per degree
        int256 latOffset = int256(radiusMeters * 1000000 / 111000);
        int256 lonOffset = (int256(radiusMeters) * 1000000) / (111000 * cosApprox(center.latitude));

        
        bounds.minLatitude = center.latitude - latOffset;
        bounds.maxLatitude = center.latitude + latOffset;
        bounds.minLongitude = center.longitude - lonOffset;
        bounds.maxLongitude = center.longitude + lonOffset;
        
        // Ensure bounds don't exceed valid coordinate ranges
        if (bounds.minLatitude < MIN_LATITUDE) bounds.minLatitude = MIN_LATITUDE;
        if (bounds.maxLatitude > MAX_LATITUDE) bounds.maxLatitude = MAX_LATITUDE;
        if (bounds.minLongitude < MIN_LONGITUDE) bounds.minLongitude = MIN_LONGITUDE;
        if (bounds.maxLongitude > MAX_LONGITUDE) bounds.maxLongitude = MAX_LONGITUDE;
    }

    /**
     * @dev Approximate square root function for smart contracts
     * @param x Input value
     * @return Square root approximation
     */
    function sqrtApprox(int256 x) internal pure returns (int256) {
        if (x <= 0) return 0;
        
        int256 z = (x + 1) / 2;
        int256 y = x;
        
        // Newton's method approximation (limited iterations for gas efficiency)
        for (uint i = 0; i < 10; i++) {
            if (z >= y) break;
            y = z;
            z = (x / z + z) / 2;
        }
        
        return y;
    }

    /**
     * @dev Approximate cosine function for latitude adjustments
     * @param latitudeE6 Latitude in E6 format (degrees * 1000000)
     * @return Cosine approximation scaled by 1000000
     */
    function cosApprox(int256 latitudeE6) internal pure returns (int256) {
        // Simple cosine approximation for small angles
        // cos(x) ≈ 1 - x²/2 for small x (in radians)
        int256 latRad = (latitudeE6 * 314159) / (180 * 1000000); // Convert to radians
        int256 latRadSquared = (latRad * latRad) / 1000000;
        
        return 1000000 - (latRadSquared / 2);
    }
}
