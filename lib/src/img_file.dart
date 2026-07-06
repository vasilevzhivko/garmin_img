import 'dart:typed_data';

import 'bit_reader.dart';
import 'byte_source.dart';
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
  final ByteSource _src;

  GarminImg._(this._src) {
    if (_src.u8(0) != 0) {
      throw const FormatException(
          'Locked/encrypted IMG (non-zero XOR byte) is not supported');
    }
  }

  /// Parses an in-memory image (best for small files / tests).
  factory GarminImg.fromBytes(Uint8List bytes) =>
      GarminImg._(MemoryByteSource(bytes));

  /// Opens the file at [path] with streaming, block-cached reads — large maps
  /// are NOT loaded into RAM. Call [close] when done.
  static Future<GarminImg> open(String path) async =>
      GarminImg._(await FileByteSource.open(path));

  /// Releases the underlying file handle (no-op for in-memory sources).
  void close() => _src.close();

  int _u16(int o) => _src.u16(o);
  int _u32(int o) => _src.u32(o);
  int _u24(int o) => _src.u24(o);
  int _s24(int o) => _src.s24(o);

  /// The sub-maps (one per GMP container), scanned once and cached. Enumerated by
  /// scanning for "GARMIN GMP" markers; a proper FAT walk is a follow-up.
  late final List<ImgMap> maps = _scanMaps();

  List<ImgMap> _scanMaps() {
    final result = <ImgMap>[];
    final needle = _ascii('GARMIN GMP');
    var from = 0;
    while (true) {
      final at = _src.indexOf(needle, from);
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

    // TRE1: map levels, 4 bytes each [zoom|inherited, bpc, subdivCount(2)].
    final levels = <MapLevel>[];
    for (var i = 0; i < tre1Size ~/ 4; i++) {
      final o = tre1 + i * 4;
      levels.add(MapLevel(_src.u8(o) & 0x0f, _src.u8(o + 1), _u16(o + 2)));
    }

    // TRE2: subdivisions. Every map level uses 16-byte records EXCEPT the last
    // (finest) level, which uses 14 bytes. Walk level-by-level so each
    // subdivision carries the correct bits-per-coord and we use the right stride.
    final subs = <Subdivision>[];
    var o = tre2;
    for (var li = 0; li < levels.length; li++) {
      final level = levels[li];
      final stride = (li == levels.length - 1) ? 14 : 16;
      for (var k = 0; k < level.subdivisionCount; k++) {
        final w = _u16(o + 10);
        subs.add(Subdivision(
          rgnOffset: _u24(o),
          elementFlags: _src.u8(o + 3),
          centerLon: _s24(o + 4),
          centerLat: _s24(o + 7),
          width: w & 0x7fff,
          height: _u16(o + 12),
          isLast: (w & 0x8000) != 0,
          bitsPerCoord: level.bitsPerCoord,
        ));
        o += stride;
      }
    }

    final rgnData0 = gmp + _u32(rgn + 0x15); // start of first subdivision data
    _expect(lbl + 2, 'GARMIN LBL');
    final lbl1 = gmp + _u32(lbl + 0x15); // label data (LBL1) start
    final lblMultiplier = _src.u8(lbl + 0x1D); // offset shift
    final lblCoding = _src.u8(lbl + 0x1E); // 6=6-bit, 9=8-bit, 10/11=multibyte
    return ImgMap._(this, bounds, levels, subs, rgnData0, lbl1, lblMultiplier, lblCoding);
  }

  // ---- helpers ----
  void _expect(int off, String tag) {
    final want = _ascii(tag);
    for (var i = 0; i < want.length; i++) {
      if (_src.u8(off + i) != want[i]) {
        throw FormatException('Expected "$tag" at 0x${off.toRadixString(16)}');
      }
    }
  }

  static List<int> _ascii(String s) => s.codeUnits;
}

/// One sub-map inside a GMP container.
class ImgMap {
  final GarminImg _img;
  final BoundingBox bounds;
  final List<MapLevel> levels;
  final List<Subdivision> subdivisions;
  final int _rgnData0;
  final int _lbl1;
  final int _lblMultiplier;
  final int _lblCoding;

  ImgMap._(this._img, this.bounds, this.levels, this.subdivisions,
      this._rgnData0, this._lbl1, this._lblMultiplier, this._lblCoding);

  /// Decodes the label at [rawOffset] (the low 22 bits are the offset into the
  /// LBL1 label block; high bits are flags). Returns null for offset 0 (no
  /// label). Supports 8-bit (coding 9) and 6-bit (coding 6) encodings.
  String? _label(int rawOffset) {
    final off = rawOffset & 0x3fffff;
    if (off == 0) return null;
    final addr = _lbl1 + (off << _lblMultiplier);
    if (addr >= _img._src.length) return null;
    if (_lblCoding == 6) return _decode6bit(addr);
    // coding 9 (8-bit) / 10-11 (multibyte, best-effort Latin-1): bytes to 0x00.
    final sb = StringBuffer();
    var a = addr;
    while (a < _img._src.length && _img._src.u8(a) != 0 && sb.length < 200) {
      sb.writeCharCode(_img._src.u8(a));
      a++;
    }
    return sb.isEmpty ? null : sb.toString();
  }

  static const _c6 = ' ABCDEFGHIJKLMNOPQRSTUVWXYZ     0123456789      ';
  String? _decode6bit(int addr) {
    final sb = StringBuffer();
    var bitbuf = 0, nbits = 0, a = addr;
    while (a < _img._src.length && sb.length < 200) {
      while (nbits < 6) {
        bitbuf = (bitbuf << 8) | _img._src.u8(a++);
        nbits += 8;
      }
      nbits -= 6;
      final v = (bitbuf >> nbits) & 0x3f;
      if (v == 0) break; // end of string
      sb.write(v < _c6.length ? _c6[v] : '?');
    }
    return sb.isEmpty ? null : sb.toString();
  }

  /// Sorted unique RGN offsets — used to bound a subdivision's data (its data
  /// ends where the next subdivision's begins).
  late final List<int> _sortedOffsets =
      (subdivisions.map((s) => s.rgnOffset).toSet().toList()..sort());

  /// Absolute end of the RGN data owned by the subdivision at [rgnOffset]
  /// (= the next larger offset, or the end of the buffer).
  int _dataEnd(int rgnOffset) {
    var lo = 0, hi = _sortedOffsets.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_sortedOffsets[mid] <= rgnOffset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < _sortedOffsets.length
        ? _rgnData0 + _sortedOffsets[lo]
        : _img._src.length;
  }

  /// Every polyline (all vertices) across all subdivisions. Contour lines
  /// (types 0x20–0x25 on topo maps) come through here.
  Iterable<ImgFeature> polylines() => _lines(2, FeatureKind.polyline);

  /// Every polygon (area fills: water, forest, land) — same bitstream encoding
  /// as polylines.
  Iterable<ImgFeature> polygons() => _lines(3, FeatureKind.polygon);

  /// Every point / POI (peaks, springs, etc.) — single-coordinate features.
  Iterable<ImgFeature> points() sync* {
    for (final sd in subdivisions) {
      // chunk index 0 = plain points, 1 = "indexed" points (city refs); both
      // share the point object layout.
      for (final wantType in const [0, 1]) {
        final chunk = _chunkStart(sd, wantType: wantType);
        if (chunk == null) continue;
        var p = chunk.start;
        var guard = 0;
        while (p + 8 <= chunk.end && guard++ < 20000) {
          final decoded = _decodePoint(p, sd);
          if (decoded == null) break;
          yield decoded.feature;
          p = decoded.next;
        }
      }
    }
  }

  /// All decoded features (points, polylines, polygons).
  Iterable<ImgFeature> features() sync* {
    yield* points();
    yield* polylines();
    yield* polygons();
  }

  Iterable<ImgFeature> _lines(int wantType, FeatureKind kind) sync* {
    for (final sd in subdivisions) {
      final chunk = _chunkStart(sd, wantType: wantType);
      if (chunk == null) continue;
      var p = chunk.start;
      var guard = 0;
      while (p + 9 <= chunk.end && guard++ < 20000) {
        // Stop the chunk as soon as an object doesn't look valid for this
        // subdivision — keeps us from spilling into adjacent data.
        final decoded = _decodeLine(p, sd, kind);
        if (decoded == null) break;
        yield decoded.feature;
        p = decoded.next;
      }
    }
  }

  /// Locates the RGN chunk of [wantType] (0=points,1=indexed,2=polylines,
  /// 3=polygons) for [sd], returning its [start] and a conservative [end].
  ({int start, int end})? _chunkStart(Subdivision sd, {required int wantType}) {
    final base = _rgnData0 + sd.rgnOffset;
    final present = <int>[];
    for (final (i, flag) in [sd.hasPoints, sd.hasIndexedPoints, sd.hasPolylines, sd.hasPolygons].indexed) {
      if (flag) present.add(i);
    }
    if (present.isEmpty || !present.contains(wantType)) return null;
    final headerLen = (present.length - 1) * 2; // 2-byte pointer per chunk after the first
    final idx = present.indexOf(wantType);
    final start = idx == 0 ? base + headerLen : base + _img._u16(base + (idx - 1) * 2);
    // End = start of the next chunk if any, else this subdivision's data end.
    final end = idx + 1 < present.length
        ? base + _img._u16(base + idx * 2)
        : _dataEnd(sd.rgnOffset);
    return (start: start, end: end);
  }

  /// Decodes a point/POI object: type(1), label(3), lon(2), lat(2), and — when
  /// the type's high bit is set — a trailing subtype byte.
  ({ImgFeature feature, int next})? _decodePoint(int p, Subdivision sd) {
    if (p + 8 > _img._src.length) return null;
    final typeByte = _img._src.u8(p);
    final hasSubtype = (typeByte & 0x80) != 0;
    final dLon = _img._src.s16(p + 4);
    final dLat = _img._src.s16(p + 6);
    final limitLon = (sd.width == 0 ? 0x2000 : sd.width) * 6 + 64;
    final limitLat = (sd.height == 0 ? 0x2000 : sd.height) * 6 + 64;
    if (dLon.abs() > limitLon || dLat.abs() > limitLat) return null;
    final shift = 24 - sd.bitsPerCoord;
    final lon = garminUnitsToDegrees(sd.centerLon + (dLon << shift));
    final lat = garminUnitsToDegrees(sd.centerLat + (dLat << shift));
    final subtype = hasSubtype ? _img._src.u8(p + 8) : 0;
    final type = ((typeByte & 0x7f) << 8) | subtype;
    return (
      feature: ImgFeature(
          kind: FeatureKind.point,
          type: type,
          points: [LatLng(lat, lon)],
          label: _label(_img._u24(p + 1))),
      next: p + (hasSubtype ? 9 : 8),
    );
  }

  ({ImgFeature feature, int next})? _decodeLine(int p, Subdivision sd, FeatureKind kind) {
    if (p + 9 > _img._src.length) return null;
    final type = _img._src.u8(p);
    final twoByteLen = (type & 0x80) != 0;
    final dLon = _img._src.s16(p + 4);
    final dLat = _img._src.s16(p + 6);
    final int blen;
    final int bs;
    if (twoByteLen) {
      blen = _img._u16(p + 8);
      bs = p + 10;
    } else {
      blen = _img._src.u8(p + 8);
      bs = p + 9;
    }
    if (blen < 1 || bs + blen > _img._src.length) return null;

    // Sanity terminator: a real polyline's first point sits within this
    // subdivision's box. The width/height are half-extents at this level's
    // resolution; allow generous slack. A wildly larger delta means we've run
    // off the end of the polyline chunk into unrelated bytes.
    final limitLon = (sd.width == 0 ? 0x2000 : sd.width) * 6 + 64;
    final limitLat = (sd.height == 0 ? 0x2000 : sd.height) * 6 + 64;
    if (dLon.abs() > limitLon || dLat.abs() > limitLat) return null;

    // Read the whole (small) bitstream once — one file read for the file source.
    final stream = _img._src.range(bs, blen);
    final info = stream[0];
    final lonBase = _baseBits(info & 0x0f);
    final latBase = _baseBits((info >> 4) & 0x0f);
    final br = BitReader(stream, 1, blen - 1);

    var lonVar = false, latVar = false, lonSign = 1, latSign = 1;
    if (br.get(1) != 0) {
      lonSign = br.get(1) != 0 ? -1 : 1;
    } else {
      lonVar = true;
    }
    if (br.get(1) != 0) {
      latSign = br.get(1) != 0 ? -1 : 1;
    } else {
      latVar = true;
    }
    final lonBits = 2 + lonBase + (lonVar ? 1 : 0);
    final latBits = 2 + latBase + (latVar ? 1 : 0);
    final shift = 24 - sd.bitsPerCoord;

    var x = sd.centerLon + (dLon << shift);
    var y = sd.centerLat + (dLat << shift);
    final pts = <LatLng>[LatLng(garminUnitsToDegrees(y), garminUnitsToDegrees(x))];
    while (br.remaining >= lonBits + latBits) {
      x += _signed(br, lonBits, lonVar, lonSign) << shift;
      y += _signed(br, latBits, latVar, latSign) << shift;
      pts.add(LatLng(garminUnitsToDegrees(y), garminUnitsToDegrees(x)));
    }

    final feature = ImgFeature(
        kind: kind, type: type & 0x3f, points: pts, label: _label(_img._u24(p + 1)));
    return (feature: feature, next: bs + blen);
  }

  static int _baseBits(int nibble) => nibble <= 9 ? nibble : 2 * nibble - 9;

  static int _signed(BitReader br, int bits, bool variable, int sign) {
    final v = br.get(bits);
    if (variable) {
      return (v & (1 << (bits - 1))) != 0 ? v - (1 << bits) : v;
    }
    return v * sign;
  }
}
