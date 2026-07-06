import 'dart:io';
import 'dart:typed_data';

import 'model/feature.dart';
import 'model/geo.dart';
import 'model/tre.dart';

/// Entry point: parses a Garmin `.img` file into its sub-maps.
///
/// Milestone scope (validated end-to-end against a real NT/GMP topo): decodes
/// the IMG container + GMP sub-maps, the TRE header (bounds, map levels,
/// subdivisions) and the FIRST point of each polyline. The full RGN bitstream
/// (all points), labels, and extended types are the next step.
///
/// Only UNLOCKED images (XOR byte 0x00, "GARMIN" markers in the clear) are
/// supported — encrypted Garmin maps are out of scope.
class GarminImg {
  final Uint8List _b;
  final ByteData _d;

  GarminImg._(this._b) : _d = ByteData.sublistView(_b) {
    final xor = _b[0];
    if (xor != 0) {
      throw const FormatException(
          'Locked/encrypted IMG (non-zero XOR byte) is not supported');
    }
  }

  /// Parses [bytes]. For very large files prefer [open] once streaming lands.
  factory GarminImg.fromBytes(Uint8List bytes) => GarminImg._(bytes);

  /// Reads and parses the file at [path]. NOTE: currently loads the whole file
  /// into memory — fine on desktop; mobile/streaming is a follow-up.
  static Future<GarminImg> open(String path) async =>
      GarminImg._(await File(path).readAsBytes());

  int _u16(int o) => _d.getUint16(o, Endian.little);
  int _u32(int o) => _d.getUint32(o, Endian.little);
  int _u24(int o) => _b[o] | (_b[o + 1] << 8) | (_b[o + 2] << 16);
  int _s24(int o) {
    final v = _u24(o);
    return (v & 0x800000) != 0 ? v - (1 << 24) : v;
  }

  /// The sub-maps (one per GMP container). Milestone: enumerated by scanning for
  /// "GARMIN GMP" markers; a proper FAT walk replaces this next.
  List<ImgMap> get maps {
    final result = <ImgMap>[];
    final needle = _ascii('GARMIN GMP');
    var from = 0;
    while (true) {
      final at = _indexOf(needle, from);
      if (at < 0) break;
      final gmp = at - 2; // subfile start = 2 bytes before the "GARMIN GMP" tag
      result.add(_parseGmp(gmp));
      from = at + needle.length;
    }
    return result;
  }

  ImgMap _parseGmp(int gmp) {
    final tre = gmp + _u32(gmp + 0x19);
    final rgn = gmp + _u32(gmp + 0x1D);
    final lbl = gmp + _u32(gmp + 0x21);
    _expect(tre + 2, 'GARMIN TRE');
    _expect(rgn + 2, 'GARMIN RGN');

    // TRE header: bounds + section pointers (GMP-relative offsets).
    final bounds = BoundingBox(
      garminUnitsToDegrees(_s24(tre + 0x1B)), // south
      garminUnitsToDegrees(_s24(tre + 0x1E)), // west
      garminUnitsToDegrees(_s24(tre + 0x15)), // north
      garminUnitsToDegrees(_s24(tre + 0x18)), // east
    );
    final tre1 = gmp + _u32(tre + 0x21);
    final tre1Size = _u32(tre + 0x25);
    final tre2 = gmp + _u32(tre + 0x29);
    final tre2Size = _u32(tre + 0x2D);

    // TRE1: map levels, 4 bytes each [zoom|inherited, bpc, subdivCount(2)].
    final levels = <MapLevel>[];
    for (var i = 0; i < tre1Size ~/ 4; i++) {
      final o = tre1 + i * 4;
      levels.add(MapLevel(_b[o] & 0x0f, _b[o + 1], _u16(o + 2)));
    }

    // TRE2: subdivisions, 16 bytes each (last map level uses 14, but the extra 2
    // "next level" bytes are simply ignored here).
    final subs = <Subdivision>[];
    for (var i = 0; i < tre2Size ~/ 16; i++) {
      final o = tre2 + i * 16;
      final w = _u16(o + 10);
      subs.add(Subdivision(
        rgnOffset: _u24(o),
        elementFlags: _b[o + 3],
        centerLon: _s24(o + 4),
        centerLat: _s24(o + 7),
        width: w & 0x7fff,
        height: _u16(o + 12),
        isLast: (w & 0x8000) != 0,
      ));
    }

    final rgnData0 = gmp + _u32(rgn + 0x15); // start of first subdivision data
    return ImgMap._(this, bounds, levels, subs, rgnData0, lbl);
  }

  // ---- helpers ----
  void _expect(int off, String tag) {
    final want = _ascii(tag);
    for (var i = 0; i < want.length; i++) {
      if (_b[off + i] != want[i]) {
        throw FormatException('Expected "$tag" at 0x${off.toRadixString(16)}');
      }
    }
  }

  static List<int> _ascii(String s) => s.codeUnits;

  int _indexOf(List<int> needle, int from) {
    final n = needle.length;
    final end = _b.length - n;
    for (var i = from; i <= end; i++) {
      var ok = true;
      for (var j = 0; j < n; j++) {
        if (_b[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }
}

/// One sub-map inside a GMP container.
class ImgMap {
  final GarminImg _img;
  final BoundingBox bounds;
  final List<MapLevel> levels;
  final List<Subdivision> subdivisions;
  final int _rgnData0;
  // ignore: unused_field
  final int _lbl;

  ImgMap._(this._img, this.bounds, this.levels, this.subdivisions,
      this._rgnData0, this._lbl);

  /// Decodes the FIRST point of each polyline in every subdivision (the point
  /// stored explicitly before the bitstream). Validated to land in-bounds; the
  /// full bitstream (remaining points) is the next milestone.
  Iterable<ImgFeature> firstPoints() sync* {
    for (final sd in subdivisions) {
      if (!sd.hasPolylines) continue;
      final base = _rgnData0 + sd.rgnOffset;
      // Element chunks are ordered points, polylines, polygons. Pointers (2 bytes
      // each) precede the first chunk — one per present type beyond the first.
      final present = [sd.hasPoints, sd.hasIndexedPoints, sd.hasPolylines, sd.hasPolygons];
      final order = present.asMap().entries.where((e) => e.value).map((e) => e.key).toList();
      if (order.isEmpty) continue;
      int poly;
      if (order.first == 2) {
        poly = base + (order.length - 1) * 2; // polylines are first chunk
      } else if (order.contains(2)) {
        final ptrIndex = order.indexOf(2) - 1; // pointer to the polyline chunk
        poly = base + _img._u16(base + ptrIndex * 2);
      } else {
        continue;
      }
      final type = _img._b[poly];
      final dLon = _img._d.getInt16(poly + 4, Endian.little);
      final dLat = _img._d.getInt16(poly + 6, Endian.little);
      final lon = garminUnitsToDegrees(sd.centerLon + dLon);
      final lat = garminUnitsToDegrees(sd.centerLat + dLat);
      yield ImgFeature(
        kind: FeatureKind.polyline,
        type: type & 0x3f,
        points: [LatLng(lat, lon)],
      );
    }
  }
}
