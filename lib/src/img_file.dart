import 'dart:convert';
import 'dart:typed_data';

import 'bit_reader.dart';
import 'byte_source.dart';
import 'model/feature.dart';
import 'model/geo.dart';
import 'model/tre.dart';

/// Entry point: parses a Garmin `.img` file into its sub-maps.
///
/// Decodes (validated end-to-end against a real NT/GMP topo): the IMG container
/// + GMP sub-maps, the TRE header (bounds, map levels, subdivisions), and the
/// full RGN basic-object data — every point of each polyline/polygon, points,
/// and labels (contour elevations, POI names). Extended-type objects are a
/// follow-up (this sample stores its contours as basic objects).
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

  /// Authentic polygon fill colors from the map's embedded **TYP** style
  /// subfile, keyed by polygon type code → 0xFFRRGGBB (opaque, day colors).
  /// Empty when the map has no TYP or it can't be parsed. Types defined as a
  /// pure-black "background/definition" area are omitted (they should not be
  /// filled). Consumers typically lighten these for a calmer look.
  late final Map<int, int> polygonColors = _parseTypPolygons();

  /// Parses the polygon section of the (single) `GARMIN TYP` subfile. Layout
  /// (validated against Locus' `TypFileHandler` header + empirically):
  ///   +0x15 u16 codepage
  ///   +0x27 u32 polygon-data offset, +0x2b u32 length   (TYP-relative)
  ///   +0x47 u32 polygon-index offset, +0x4b u8 record size, +0x4d u32 length
  /// Index record = u16 typecode + (recSize-2)-byte data offset; polygon
  /// type = typecode >> 5. Data entry = flag(1) + day BGR(3) [+ night/bitmap].
  Map<int, int> _parseTypPolygons() {
    try {
      final at = _src.indexOf(_ascii('GARMIN TYP'), 0);
      if (at < 2) return const {};
      final typ = at - 2;
      final dataOff = typ + _u32(typ + 0x27);
      final idxOff = typ + _u32(typ + 0x47);
      final rec = _src.u8(typ + 0x4b);
      final idxLen = _u32(typ + 0x4d);
      if (rec < 3 || idxLen <= 0 || idxLen > 1 << 20) return const {};
      final out = <int, int>{};
      final n = idxLen ~/ rec;
      for (var k = 0; k < n; k++) {
        final r = idxOff + k * rec;
        final typecode = _u16(r);
        var off = 0;
        for (var b = 0; b < rec - 2; b++) {
          off |= _src.u8(r + 2 + b) << (8 * b);
        }
        final type = typecode >> 5;
        final e = dataOff + off;
        if (e + 4 > _src.length) continue;
        // day color = BGR at entry+1
        final bl = _src.u8(e + 1), gr = _src.u8(e + 2), rd = _src.u8(e + 3);
        if (rd == 0 && gr == 0 && bl == 0) continue; // background — don't fill
        out[type] = 0xFF000000 | (rd << 16) | (gr << 8) | bl;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

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
    // Charset for 8-bit labels (u16 @ LBL+0xaa): 1251=Cyrillic, 1252/0/850=Latin,
    // 65001=UTF-8. Latin & Cyrillic editions of the same map differ only here.
    final lblHeaderLen = _u16(lbl);
    final lblCodepage = lblHeaderLen > 0xac ? _u16(lbl + 0xaa) : 0;
    return ImgMap._(this, bounds, levels, subs, rgnData0, lbl1, lblMultiplier,
        lblCoding, lblCodepage);
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

  /// LBL charset (1251 Cyrillic / 1252/0/850 Latin / 65001 UTF-8).
  final int _lblCodepage;

  ImgMap._(this._img, this.bounds, this.levels, this.subdivisions,
      this._rgnData0, this._lbl1, this._lblMultiplier, this._lblCoding,
      this._lblCodepage);

  /// Decodes the label at [rawOffset] (the low 22 bits are the offset into the
  /// LBL1 label block; high bits are flags). Returns null for offset 0 (no
  /// label). Supports 8-bit (coding 9, charset per codepage) and 6-bit (coding 6).
  String? _label(int rawOffset) {
    final off = rawOffset & 0x3fffff;
    if (off == 0) return null;
    final addr = _lbl1 + (off << _lblMultiplier);
    if (addr >= _img._src.length) return null;
    if (_lblCoding == 6) return _decode6bit(addr);
    // coding 9 (8-bit) / 10-11 (multibyte, best-effort): read bytes to 0x00,
    // then decode per the map's codepage so Cyrillic (1251) editions read right.
    final bytes = <int>[];
    var a = addr;
    while (a < _img._src.length && _img._src.u8(a) != 0 && bytes.length < 200) {
      bytes.add(_img._src.u8(a));
      a++;
    }
    if (bytes.isEmpty) return null;
    return _decodeBytes(bytes);
  }

  String _decodeBytes(List<int> bytes) {
    switch (_lblCodepage) {
      case 65001:
        try {
          return const Utf8Decoder(allowMalformed: true).convert(bytes);
        } catch (_) {
          return String.fromCharCodes(bytes);
        }
      case 1251:
        final sb = StringBuffer();
        for (final b in bytes) {
          sb.writeCharCode(b < 0x80
              ? b
              : b >= 0xc0
                  ? 0x410 + (b - 0xc0) // А-я block is contiguous
                  : _cp1251Hi[b - 0x80]); // 0x80-0xbf specials
        }
        return sb.toString();
      default: // 1252 / 0 / 850 — Latin; ASCII passes through unchanged.
        return String.fromCharCodes(bytes);
    }
  }

  /// Windows-1251 → Unicode for bytes 0x80–0xBF (0xC0–0xFF computed inline).
  static const List<int> _cp1251Hi = [
    0x0402, 0x0403, 0x201a, 0x0453, 0x201e, 0x2026, 0x2020, 0x2021, //
    0x20ac, 0x2030, 0x0409, 0x2039, 0x040a, 0x040c, 0x040b, 0x040f,
    0x0452, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
    0x003f, 0x2122, 0x0459, 0x203a, 0x045a, 0x045c, 0x045b, 0x045f,
    0x00a0, 0x040e, 0x045e, 0x0408, 0x00a4, 0x0490, 0x00a6, 0x00a7,
    0x0401, 0x00a9, 0x0404, 0x00ab, 0x00ac, 0x00ad, 0x00ae, 0x0407,
    0x00b0, 0x00b1, 0x0406, 0x0456, 0x0491, 0x00b5, 0x00b6, 0x00b7,
    0x0451, 0x2116, 0x0454, 0x00bb, 0x0458, 0x0405, 0x0455, 0x0457,
  ];

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
  Iterable<ImgFeature> polylines() =>
      _forEachSub((sd) => _linesOf(sd, 2, FeatureKind.polyline));

  /// Every polygon (area fills: water, forest, land) — same bitstream encoding.
  Iterable<ImgFeature> polygons() =>
      _forEachSub((sd) => _linesOf(sd, 3, FeatureKind.polygon));

  /// Every point / POI (peaks, springs, etc.) — single-coordinate features.
  Iterable<ImgFeature> points() => _forEachSub(_pointsOf);

  /// All decoded features (points, polylines, polygons).
  Iterable<ImgFeature> features() => _forEachSub(_featuresOf);

  /// Features whose subdivision overlaps [query]. Optionally restrict to map
  /// levels with the given bits-per-coord ([onlyBpc]) — pick these by zoom so a
  /// viewport only decodes the appropriate level of detail (fast on mobile).
  Iterable<ImgFeature> featuresInBounds(BoundingBox query, {Set<int>? onlyBpc}) sync* {
    for (final sd in subdivisions) {
      if (onlyBpc != null && !onlyBpc.contains(sd.bitsPerCoord)) continue;
      if (!_overlaps(_subBounds(sd), query)) continue;
      yield* _featuresOf(sd);
    }
  }

  Iterable<ImgFeature> _forEachSub(
      Iterable<ImgFeature> Function(Subdivision) decode) sync* {
    for (final sd in subdivisions) {
      yield* decode(sd);
    }
  }

  Iterable<ImgFeature> _featuresOf(Subdivision sd) sync* {
    yield* _pointsOf(sd);
    yield* _linesOf(sd, 2, FeatureKind.polyline);
    yield* _linesOf(sd, 3, FeatureKind.polygon);
  }

  Iterable<ImgFeature> _linesOf(Subdivision sd, int wantType, FeatureKind kind) sync* {
    final chunk = _chunkStart(sd, wantType: wantType);
    if (chunk == null) return;
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

  Iterable<ImgFeature> _pointsOf(Subdivision sd) sync* {
    // chunk index 0 = plain points, 1 = "indexed" points (city refs).
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

  /// The geographic box a subdivision covers (center ± half width/height).
  BoundingBox _subBounds(Subdivision sd) {
    final shift = 24 - sd.bitsPerCoord;
    final hw = sd.width << shift, hh = sd.height << shift;
    return BoundingBox(
      garminUnitsToDegrees(sd.centerLat - hh),
      garminUnitsToDegrees(sd.centerLon - hw),
      garminUnitsToDegrees(sd.centerLat + hh),
      garminUnitsToDegrees(sd.centerLon + hw),
    );
  }

  static bool _overlaps(BoundingBox a, BoundingBox b) =>
      a.west <= b.east && a.east >= b.west && a.south <= b.north && a.north >= b.south;

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
    // The length byte counts the bitstream DATA bytes only — the leading info
    // byte is separate — so the bitstream spans blen+1 bytes total and the next
    // object begins at bs + blen + 1. (Getting this off by one desyncs every
    // object after the first.)
    final total = blen + 1;
    if (blen < 1 || bs + total > _img._src.length) return null;

    // Sanity terminator: a real polyline's first point sits within this
    // subdivision's box. The width/height are half-extents at this level's
    // resolution; allow generous slack. A wildly larger delta means we've run
    // off the end of the polyline chunk into unrelated bytes.
    final limitLon = (sd.width == 0 ? 0x2000 : sd.width) * 6 + 64;
    final limitLat = (sd.height == 0 ? 0x2000 : sd.height) * 6 + 64;
    if (dLon.abs() > limitLon || dLat.abs() > limitLat) return null;

    // Read the whole (small) bitstream once — one file read for the file source.
    final stream = _img._src.range(bs, total);
    final info = stream[0];
    final br = BitReader(stream, 1, blen);

    // Sign header: a leading 1-bit means "constant sign" (next bit gives it),
    // 0 means each delta carries its own sign (variable). Longitude first.
    int lonSign = 0, latSign = 0;
    if (br.get(1) != 0) lonSign = br.get(1) == 0 ? 1 : -1;
    if (br.get(1) != 0) latSign = br.get(1) == 0 ? 1 : -1;

    // The label's "extra bit" (bit 22) adds one bit of precision to LONGITUDE.
    final lonExtra = (_img._u24(p + 1) & 0x400000) != 0 ? 1 : 0;
    const latExtra = 0;
    final lonBits = _convertCoordLen(info & 0x0f, lonSign, lonExtra);
    final latBits = _convertCoordLen(info >> 4, latSign, latExtra);
    final bpc = sd.bitsPerCoord;

    var curLon = dLon, curLat = dLat;
    final pts = <LatLng>[
      LatLng(garminUnitsToDegrees(_coord(sd.centerLat, curLat, bpc, 0)),
          garminUnitsToDegrees(_coord(sd.centerLon, curLon, bpc, 0))),
    ];
    curLon <<= lonExtra;
    curLat <<= latExtra;
    while (br.remaining >= lonBits + latBits) {
      curLon += _readCoordOffset(br, lonBits, lonSign, lonExtra);
      curLat += _readCoordOffset(br, latBits, latSign, latExtra);
      pts.add(LatLng(
          garminUnitsToDegrees(_coord(sd.centerLat, curLat, bpc, latExtra)),
          garminUnitsToDegrees(_coord(sd.centerLon, curLon, bpc, lonExtra))));
    }

    final feature = ImgFeature(
        kind: kind, type: type & 0x3f, points: pts, label: _label(_img._u24(p + 1)));
    return (feature: feature, next: bs + total);
  }

  /// Bits per coordinate delta. Base from the info nibble (i, or 2i-9 above 9),
  /// +2, +1 when the sign is variable, +1 for the longitude "extra bit".
  static int _convertCoordLen(int i, int sign, int extraBit) {
    var add = 0;
    if (sign == 0) add++;
    add += extraBit;
    return (i <= 9 ? i : 2 * i - 9) + 2 + add;
  }

  /// garmin unit = center + (value << (24 - bpc - extra))  (>> if negative shift).
  static int _coord(int center, int value, int bpc, int extra) {
    final shift = 24 - bpc - extra;
    return center + (shift >= 0 ? value << shift : value >> -shift);
  }

  /// Decodes one signed coordinate delta from the bitstream. Ported faithfully
  /// from org.free.garminimg's `BitStreamReader.readCoordOffset`, including the
  /// variable-length "escape" case (sign-bit complement == 0 → read another
  /// group and combine) that a naive two's-complement read gets wrong — that
  /// omission produced occasional wild vertices (spikes/shards in polygons).
  static int _readCoordOffset(BitReader br, int nbBits, int sign, int extraBit) {
    if (sign == 0) {
      final value = br.get(nbBits);
      final signMask = 1 << (nbBits - 1);
      if ((value & signMask) != 0) {
        final comp = value ^ signMask;
        if (extraBit == 0) {
          if (comp != 0) return comp - signMask;
          final other = _readCoordOffset(br, nbBits, sign, extraBit);
          return other < 0 ? 1 - value + other : value - 1 + other;
        } else {
          if ((comp & 0xFFFFFE) != 0) return (comp & 0xFFFFFE) - signMask;
          final other = _readCoordOffset(br, nbBits - 1, sign, 0);
          return other < 0
              ? 1 - signMask + 1 + (other << 1)
              : signMask - 1 - 1 + (other << 1);
        }
      }
      return extraBit > 0 ? value & 0xFFFFFE : value;
    }
    final val = br.get(nbBits);
    return extraBit > 0 ? ((val >> 1) * sign) << 1 : val * sign;
  }
}
