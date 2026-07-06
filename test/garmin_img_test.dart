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

    test('decoded polyline first-points fall inside the map bounds', () async {
      final img = await GarminImg.open(sample!);
      final map = img.maps.first;
      final pts = map.firstPoints().take(50).toList();
      expect(pts, isNotEmpty, reason: 'expected some polylines');
      for (final f in pts) {
        expect(map.bounds.contains(f.points.first), isTrue,
            reason: 'point ${f.points.first} outside ${map.bounds}');
      }
    });
  }, skip: sample == null ? 'no sample .img (set GARMIN_IMG_SAMPLE)' : false);

  test('rejects a locked (non-zero XOR) image', () {
    final locked = Uint8List(64);
    locked[0] = 0x55; // non-zero XOR byte
    expect(() => GarminImg.fromBytes(locked),
        throwsA(isA<FormatException>()));
  });
}
