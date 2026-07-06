/// A pure-Dart reader for unlocked Garmin `.img` map files.
///
/// ```dart
/// final img = await GarminImg.open('gmapsupp.img');
/// for (final map in img.maps) {
///   print(map.bounds);
///   for (final f in map.firstPoints()) print(f);
/// }
/// ```
library;

export 'src/img_file.dart';
export 'src/model/feature.dart';
export 'src/model/geo.dart';
export 'src/model/tre.dart';
