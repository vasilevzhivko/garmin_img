/// A map "level" — a zoom band. [bitsPerCoord] (bpc) sets coordinate accuracy at
/// this level; [subdivisionCount] is how many subdivisions belong to it.
class MapLevel {
  final int zoom;
  final int bitsPerCoord;
  final int subdivisionCount;
  const MapLevel(this.zoom, this.bitsPerCoord, this.subdivisionCount);

  @override
  String toString() =>
      'MapLevel(zoom=$zoom bpc=$bitsPerCoord n=$subdivisionCount)';
}

/// A subdivision — a spatial cell whose geometry lives in the RGN subfile.
/// [rgnOffset] is the offset (into the RGN data region) of this cell's element
/// chunks. [elementFlags] bit 0x10=points, 0x20=indexed points, 0x40=polylines,
/// 0x80=polygons. [centerLon]/[centerLat] are raw Garmin coordinate units.
class Subdivision {
  final int rgnOffset;
  final int elementFlags;
  final int centerLon;
  final int centerLat;
  final int width;
  final int height;
  final bool isLast;

  const Subdivision({
    required this.rgnOffset,
    required this.elementFlags,
    required this.centerLon,
    required this.centerLat,
    required this.width,
    required this.height,
    required this.isLast,
  });

  bool get hasPoints => elementFlags & 0x10 != 0;
  bool get hasIndexedPoints => elementFlags & 0x20 != 0;
  bool get hasPolylines => elementFlags & 0x40 != 0;
  bool get hasPolygons => elementFlags & 0x80 != 0;
}
