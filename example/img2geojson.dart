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
  for (final map in img.maps) {
    for (final f in map.polylines()) {
      if (f.points.length < 2) continue;
      features.add({
        'type': 'Feature',
        'properties': {'garminType': '0x${f.type.toRadixString(16)}'},
        'geometry': {
          'type': 'LineString',
          // GeoJSON is [lng, lat].
          'coordinates': [
            for (final p in f.points) [p.lng, p.lat]
          ],
        },
      });
      if (features.length >= max) break;
    }
    if (features.length >= max) break;
  }

  stdout.writeln(jsonEncode({'type': 'FeatureCollection', 'features': features}));
  stderr.writeln('wrote ${features.length} polylines');
}
