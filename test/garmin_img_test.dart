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
  }, skip: sample == null ? 'no sample .img (set GARMIN_IMG_SAMPLE)' : false);

  test('rejects a locked (non-zero XOR) image', () {
    final locked = Uint8List(64);
    locked[0] = 0x55; // non-zero XOR byte
    expect(() => GarminImg.fromBytes(locked),
        throwsA(isA<FormatException>()));
  });
}
