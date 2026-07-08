// Extract peaks from BOTH editions of a Garmin .img (Cyrillic + Latin) and join
// them by coordinate into one bilingual record:
//   { name_bg, name_en, lat, lng, elevation }   (elevation in metres)
// Both editions share identical geometry, so points match on exact lat/lng.
//
// Usage: dart run example/extract_peaks_bilingual.dart <cyr.img> <lat.img> [out.json]
import 'dart:convert';
import 'dart:io';
import 'package:garmin_img/garmin_img.dart';

/// Strip control chars (< 0x20, e.g. the 0x1F name/elevation separator) and trim.
String _clean(String s) =>
    s.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

final _split = RegExp(r'^(.*?)(\d+)?\s*$');

/// key -> {name, ele} for every summit point, keyed by exact coordinate.
Future<Map<String, Map<String, dynamic>>> _peaks(String path) async {
  final img = await GarminImg.open(path);
  final full = img.maps.fold<List<double>>([90, 180, -90, -180], (a, m) {
    final b = m.bounds;
    return [a[0] < b.south ? a[0] : b.south, a[1] < b.west ? a[1] : b.west,
            a[2] > b.north ? a[2] : b.north, a[3] > b.east ? a[3] : b.east];
  });
  final q = BoundingBox(full[0], full[1], full[2], full[3]);
  final out = <String, Map<String, dynamic>>{};
  for (final m in img.maps) {
    for (final f in m.featuresInBounds(q)) {
      if (f.kind != FeatureKind.point) continue;
      if (f.type != 0x6616 && f.type != 0x6300) continue;
      final p = f.points.first;
      final mm = _split.firstMatch(_clean(f.label ?? ''))!;
      final name = _clean(mm.group(1) ?? '');
      final feet = mm.group(2);
      final ele = feet != null ? (int.parse(feet) * 0.3048).round() : null;
      if (ele != null && ele > 3000) continue;
      final key = '${p.lat.toStringAsFixed(6)},${p.lng.toStringAsFixed(6)}';
      out[key] = {'name': name, 'lat': p.lat, 'lng': p.lng, if (ele != null) 'ele': ele};
    }
  }
  img.close();
  return out;
}

Future<void> main(List<String> args) async {
  final cyrPath = args.isNotEmpty ? args[0] : '/Users/zhivkovasilev/Downloads/gmapsupp-2.img';
  final latPath = args.length > 1 ? args[1] : '/Users/zhivkovasilev/Downloads/gmapsupp.img';
  final out = args.length > 2 ? args[2] : '/Users/zhivkovasilev/Downloads/bg_peaks.json';

  final cyr = await _peaks(cyrPath);
  final lat = await _peaks(latPath);

  final seen = <String>{};
  final peaks = <Map<String, dynamic>>[];
  for (final e in cyr.entries) {
    final bg = e.value['name'] as String;
    if (bg.isEmpty) continue; // named only
    final en = lat[e.key]?['name'] as String?; // same coord in Latin edition
    final ele = e.value['ele'] ?? lat[e.key]?['ele'];
    final p = e.value;
    // Dedup by name + ~2 km cell (peaks repeat across levels/sub-maps).
    final key = '$bg@${(p['lat'] / 0.02).round()},${(p['lng'] / 0.02).round()}';
    if (!seen.add(key)) continue;
    peaks.add({
      'name_bg': bg,
      'name_en': (en != null && en.isNotEmpty) ? en : null,
      'lat': double.parse((p['lat'] as double).toStringAsFixed(6)),
      'lng': double.parse((p['lng'] as double).toStringAsFixed(6)),
      'elevation': ele,
    });
  }
  peaks.sort((a, b) => ((b['elevation'] ?? 0) as int).compareTo((a['elevation'] ?? 0) as int));

  File(out).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(peaks));
  final withEn = peaks.where((p) => p['name_en'] != null).length;
  final withEle = peaks.where((p) => p['elevation'] != null).length;
  print('wrote ${peaks.length} peaks -> $out  (name_en: $withEn, elevation: $withEle)');
  for (final p in peaks.take(6)) {
    print('  ${p['name_bg']} / ${p['name_en']}  ${p['elevation']} m');
  }
}
