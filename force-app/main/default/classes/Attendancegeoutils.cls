/**
 * Utility for geofence distance calculation.
 * Used to validate that a check-in's GPS coordinates are within
 * the allowed radius of the configured office location.
 */
public class Attendancegeoutils{

    private static final Double EARTH_RADIUS_METERS = 6371000.0;

    /**
     * Returns the great-circle distance between two lat/long points, in meters.
     */
    public static Double distanceMeters(Double lat1, Double lon1, Double lat2, Double lon2) {
        Double dLat = toRadians(lat2 - lat1);
        Double dLon = toRadians(lon2 - lon1);

        Double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                 + Math.cos(toRadians(lat1)) * Math.cos(toRadians(lat2))
                 * Math.sin(dLon / 2) * Math.sin(dLon / 2);

        Double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return EARTH_RADIUS_METERS * c;
    }

    private static Double toRadians(Double degrees) {
        return degrees * Math.PI / 180.0;
    }
}