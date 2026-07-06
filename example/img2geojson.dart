// Converts the polylines of a Garmin .img map to GeoJSON on stdout.
//
//   dart run example/img2geojson.dart path/to/gmapsupp.img > out.geojson
//
// Paste out.geojson into https://geojson.io to see the decoded geometry.
import 'dart:convert';
import 'dart:io';

import 'package:garmin_img/garmin_img.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/img2geojson.dart <file.img> [maxFeatures]');
    exit(64);
  }
  final max = args.length > 1 ? int.parse(args[1]) : 20000;

  final img = await GarminImg.open(args[0]);
  final features = <Map<String, dynamic>>[];
  outer:
  for (final map in img.maps) {
    for (final f in map.features()) {
      final coords = [
        for (final p in f.points) [p.lng, p.lat] // GeoJSON is [lng, lat]
      ];
      final Map<String, dynamic> geometry;
      switch (f.kind) {
        case FeatureKind.point:
          geometry = {'type': 'Point', 'coordinates': coords.first};
        case FeatureKind.polyline:
          if (f.points.length < 2) continue;
          geometry = {'type': 'LineString', 'coordinates': coords};
        case FeatureKind.polygon:
          if (f.points.length < 3) continue;
          // Close the ring for a valid GeoJSON Polygon.
          final ring = [...coords, coords.first];
          geometry = {'type': 'Polygon', 'coordinates': [ring]};
      }
      features.add({
        'type': 'Feature',
        'properties': {
          'kind': f.kind.name,
          'garminType': '0x${f.type.toRadixString(16)}',
        },
        'geometry': geometry,
      });
      if (features.length >= max) break outer;
    }
  }

  stdout.writeln(jsonEncode({'type': 'FeatureCollection', 'features': features}));
  stderr.writeln('wrote ${features.length} polylines');
}
