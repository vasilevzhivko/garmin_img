/// A WGS84 coordinate in decimal degrees.
class LatLng {
  final double lat;
  final double lng;
  const LatLng(this.lat, this.lng);

  @override
  String toString() => '($lat, $lng)';
}

/// A geographic bounding box in decimal degrees.
class BoundingBox {
  final double south;
  final double west;
  final double north;
  final double east;
  const BoundingBox(this.south, this.west, this.north, this.east);

  bool contains(LatLng p) =>
      p.lat >= south && p.lat <= north && p.lng >= west && p.lng <= east;

  @override
  String toString() =>
      'BBox(S=$south W=$west N=$north E=$east)';
}

/// Garmin stores coordinates as 24-bit units where a full circle is 2^24.
/// This converts a raw Garmin coordinate unit to decimal degrees.
double garminUnitsToDegrees(int units) => units * 360.0 / (1 << 24);
