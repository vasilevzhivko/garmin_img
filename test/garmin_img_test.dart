import 'dart:io';
import 'dart:typed_data';

import 'package:garmin_img/garmin_img.dart';
import 'package:test/test.dart';

/// These run against a real sample if present. Point GARMIN_IMG_SAMPLE at an
/// unlocked .img, or drop one at ~/Downloads/gmapsupp.img. Skipped otherwise so
/// the package still `dart test`s clean without a (large) fixture in the repo.
String? _sample() {
  final env = Platform.environment['GARMIN_IMG_SAMPLE'];
  if (env != null && File(env).existsSync()) return env;
  final home = Platform.environment['HOME'];
  if (home != null) {
    final p = '$home/Downloads/gmapsupp.img';
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  final sample = _sample();

  group('GarminImg (real sample)', () {
    test('parses container + at least one sub-map', () async {
      final img = await GarminImg.open(sample!);
      expect(img.maps, isNotEmpty);
    });

    test('bounds, levels and subdivisions are sane', () async {
      final img = await GarminImg.open(sample!);
      final map = img.maps.first;
      // Bounds are a valid box.
      expect(map.bounds.south, lessThan(map.bounds.north));
      expect(map.bounds.west, lessThan(map.bounds.east));
      // Map levels have increasing bits-per-coord and non-zero subdivisions.
      expect(map.levels, isNotEmpty);
      expect(map.levels.last.bitsPerCoord, inInclusiveRange(20, 24));
      expect(map.subdivisions, isNotEmpty);
    });

    test('decoded polylines are multi-point, in-bounds and coherent', () async {
      final img = await GarminImg.open(sample!);
      final map = img.maps.first;
      final lines = map.polylines().take(500).toList();
      expect(lines, isNotEmpty, reason: 'expected some polylines');

      // Allow a tiny slack for boundary features; the vast majority must be
      // in-bounds and geometrically coherent (no wild jumps between vertices).
      final b = map.bounds;
      var multiPoint = 0, bad = 0;
      for (final f in lines) {
        if (f.points.length >= 2) multiPoint++;
        var maxStep = 0.0;
        for (var i = 1; i < f.points.length; i++) {
          maxStep = [
            maxStep,
            (f.points[i].lat - f.points[i - 1].lat).abs(),
            (f.points[i].lng - f.points[i - 1].lng).abs(),
          ].reduce((a, c) => a > c ? a : c);
        }
        final inBounds = f.points.every((p) =>
            p.lat >= b.south - 0.05 &&
            p.lat <= b.north + 0.05 &&
            p.lng >= b.west - 0.05 &&
            p.lng <= b.east + 0.05);
        if (!inBounds || maxStep > 0.05) bad++;
      }
      expect(multiPoint, greaterThan(lines.length ~/ 2),
          reason: 'most polylines should have >1 decoded vertex');
      expect(bad, lessThan((lines.length * 0.03).ceil()),
          reason: '$bad/${lines.length} polylines out-of-bounds or incoherent');
    });

    test('polygons decode as multi-point areas, in-bounds', () async {
      final img = await GarminImg.open(sample!);
      final map = img.maps.first;
      final b = map.bounds;
      final polys = map.polygons().take(500).toList();
      expect(polys, isNotEmpty);
      var multi = 0, bad = 0;
      for (final f in polys) {
        if (f.points.length >= 3) multi++;
        final inB = f.points.every((p) =>
            p.lat >= b.south - 0.05 &&
            p.lat <= b.north + 0.05 &&
            p.lng >= b.west - 0.05 &&
            p.lng <= b.east + 0.05);
        if (!inB) bad++;
      }
      expect(multi, greaterThan(polys.length ~/ 2));
      expect(bad, lessThan((polys.length * 0.04).ceil()), reason: '$bad bad');
    });

    test('points/POIs decode as single in-bounds coordinates', () async {
      final img = await GarminImg.open(sample!);
      final map = img.maps.first;
      final b = map.bounds;
      final pts = map.points().take(500).toList();
      expect(pts, isNotEmpty);
      var bad = 0;
      for (final f in pts) {
        expect(f.points.length, 1);
        final p = f.points.first;
        if (p.lat < b.south - 0.05 ||
            p.lat > b.north + 0.05 ||
            p.lng < b.west - 0.05 ||
            p.lng > b.east + 0.05) {
          bad++;
        }
      }
      expect(bad, lessThan((pts.length * 0.03).ceil()), reason: '$bad bad');
    });

    test('labels decode: POI names + contour elevations', () async {
      final img = await GarminImg.open(sample!);
      final map = img.maps.first;

      // Some POIs carry human-readable names.
      final named = map.points().where((f) => f.label != null).take(50).toList();
      expect(named, isNotEmpty, reason: 'expected some labelled POIs');
      expect(named.map((f) => f.label!).any((s) => RegExp(r'[A-Za-z]{3,}').hasMatch(s)),
          isTrue, reason: 'expected at least one alphabetic POI name');

      // Contour polylines (type 0x22) carry a numeric elevation label.
      final elevs = map
          .polylines()
          .where((f) => f.type == 0x22 && f.label != null)
          .take(50)
          .toList();
      expect(elevs, isNotEmpty, reason: 'expected labelled contour lines');
      expect(elevs.map((f) => f.label!).any((s) => RegExp(r'^\d+$').hasMatch(s.trim())),
          isTrue, reason: 'expected a numeric contour elevation');
    });

    test('featuresInBounds returns far fewer features, near the query box', () async {
      final img = await GarminImg.open(sample!);
      final map = img.maps.first;
      final b = map.bounds;
      // A small central window (~1/6 of the map each way).
      final cLat = (b.south + b.north) / 2, cLng = (b.west + b.east) / 2;
      final hLat = (b.north - b.south) / 12, hLng = (b.east - b.west) / 12;
      final q = BoundingBox(cLat - hLat, cLng - hLng, cLat + hLat, cLng + hLng);

      // Restrict to the finest level: its subdivisions are small, so a
      // subdivision that overlaps the window keeps its features genuinely near
      // it. (Coarse levels have huge subdivisions whose features spread across
      // the whole map, so "near the box" is only a meaningful invariant here.)
      final fineBpc =
          (map.levels.map((l) => l.bitsPerCoord).toSet().toList()..sort()).last;
      final windowed =
          map.featuresInBounds(q, onlyBpc: {fineBpc}).take(3000).toList();
      expect(windowed, isNotEmpty);
      var near = 0;
      for (final f in windowed) {
        if (f.points.any((p) =>
            p.lat >= q.south - 0.05 &&
            p.lat <= q.north + 0.05 &&
            p.lng >= q.west - 0.05 &&
            p.lng <= q.east + 0.05)) {
          near++;
        }
      }
      expect(near, greaterThan(windowed.length ~/ 2),
          reason: 'most windowed fine-level features should sit in/near the query box');
    });

    test('reads polygon colors from the embedded TYP style table', () async {
      final img = await GarminImg.open(sample!);
      final colors = img.polygonColors;
      expect(colors, isNotEmpty,
          reason: 'sample has a GARMIN TYP subfile with polygon styles');
      // Every value is opaque 0xFFRRGGBB and non-black (black = background, skipped).
      for (final v in colors.values) {
        expect(v >> 24 & 0xFF, 0xFF);
        expect(v & 0xFFFFFF, isNot(0));
      }
    });

    test('decodes many objects per subdivision (stride off-by-one regression)',
        () async {
      // The RGN object length byte counts DATA bytes only (info byte separate),
      // so the next object begins at bs + blen + 1. An off-by-one there desyncs
      // after the FIRST object of every subdivision, collapsing the finest level
      // to ~1 object each (~95% data loss). Assert a small central window of the
      // densest map's finest level yields many features — impossible if the
      // per-subdivision decode stops after one object.
      final img = await GarminImg.open(sample!);
      // Max central-window fine-level count across all maps — at least one map
      // has data at its centre; the count there must be far above 1/subdivision.
      var best = 0;
      for (final map in img.maps) {
        if (map.levels.isEmpty) continue;
        final bb = map.bounds;
        final cLat = (bb.south + bb.north) / 2, cLng = (bb.west + bb.east) / 2;
        const h = 0.01;
        final q = BoundingBox(cLat - h, cLng - h, cLat + h, cLng + h);
        final fineBpc = (map.levels.map((l) => l.bitsPerCoord).toSet().toList()
              ..sort())
            .last;
        final n = map.featuresInBounds(q, onlyBpc: {fineBpc}).take(2000).length;
        if (n > best) best = n;
      }
      expect(best, greaterThan(50),
          reason: 'off-by-one would cap this at ~1 object per subdivision');
    });
  }, skip: sample == null ? 'no sample .img (set GARMIN_IMG_SAMPLE)' : false);

  test('rejects a locked (non-zero XOR) image', () {
    final locked = Uint8List(64);
    locked[0] = 0x55; // non-zero XOR byte
    expect(() => GarminImg.fromBytes(locked),
        throwsA(isA<FormatException>()));
  });
}
