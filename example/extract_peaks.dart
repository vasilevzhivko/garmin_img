// Extract all peaks (type 0x6616/0x6300) from a Garmin .img as JSON:
//   { name, lat, lng, ele }  (ele in metres; label is NAME+FEET)
// Usage: dart run example/extract_peaks.dart <file.img> [out.json]
import 'dart:convert';
import 'dart:io';
import 'package:garmin_img/garmin_img.dart';

final _split = RegExp(r'^(.*?)(\d+)?\s*$');

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '/Users/zhivkovasilev/Downloads/gmapsupp.img';
  final img = await GarminImg.open(path);
  final full = img.maps.fold<List<double>>([90, 180, -90, -180], (a, m) {
    final b = m.bounds;
    return [a[0] < b.south ? a[0] : b.south, a[1] < b.west ? a[1] : b.west,
            a[2] > b.north ? a[2] : b.north, a[3] > b.east ? a[3] : b.east];
  });
  final q = BoundingBox(full[0], full[1], full[2], full[3]);

  final seen = <String>{};
  final peaks = <Map<String, dynamic>>[];
  for (final m in img.maps) {
    for (final f in m.featuresInBounds(q)) {
      if (f.kind != FeatureKind.point) continue;
      if (f.type != 0x6616 && f.type != 0x6300) continue;
      final p = f.points.first;
      final raw = f.label?.trim() ?? '';
      final mm = _split.firstMatch(raw)!;
      final name = mm.group(1)!.trim();
      final feet = mm.group(2);
      final ele = feet != null ? (int.parse(feet) * 0.3048).round() : null;
      // Drop implausible elevations (Bulgaria tops out at 2925 m).
      if (ele != null && ele > 3000) continue;
      // Dedup by name + ~2 km cell (peaks repeat across levels/sub-maps).
      final key = '$name@${(p.lat / 0.02).round()},${(p.lng / 0.02).round()}';
      if (!seen.add(key)) continue;
      peaks.add({
        'name': name,
        'lat': double.parse(p.lat.toStringAsFixed(6)),
        'lng': double.parse(p.lng.toStringAsFixed(6)),
        if (ele != null) 'ele': ele,
      });
    }
  }
  peaks.sort((a, b) => (b['ele'] ?? 0).compareTo(a['ele'] ?? 0));
  final named = peaks.where((p) => (p['name'] as String).isNotEmpty).length;
  print('peaks: ${peaks.length} total, $named named');
  print('highest:');
  for (final p in peaks.take(8)) {
    print('  ${p['name']}  ${p['ele']} m  (${p['lat']}, ${p['lng']})');
  }
  if (args.length > 1) {
    File(args[1]).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(peaks));
    print('wrote ${peaks.length} -> ${args[1]}');
  }
  img.close();
}
