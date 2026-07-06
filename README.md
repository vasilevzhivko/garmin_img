# garmin_img

A **pure-Dart** reader for **unlocked** Garmin `.img` map files (topographic and
vector maps). It decodes the IMG container, GMP sub-maps, the TRE index (map
levels, subdivisions, bounds) and RGN geometry into typed features — with **no
Flutter or mapsforge dependency**, so you can use it with mapsforge_flutter,
flutter_map, a CLI, or a server.

There is currently no other Garmin IMG reader on pub.dev.

## Status

Early. **Validated end-to-end against a real Bulgarian NT/GMP topo map**
(`gmapsupp.img`): the container, GMP sub-maps, TRE bounds/levels/subdivisions and
polyline first-points all decode correctly and in-bounds.

Implemented:
- IMG container + GMP sub-map location
- TRE: bounding box, map levels (bits-per-coord), subdivisions
- RGN: **points/POIs, polylines and polygons — full geometry (all vertices)** via
  the bit-packed bitstream (topo contour lines, types 0x20–0x25, come through)
- LBL: **labels** — POI/feature names and **contour elevations** (8-bit & 6-bit)
- `example/img2geojson.dart` — dump features to GeoJSON (view in geojson.io)

Next:
- Extended types (0x10000+); non-Latin label codepages (Cyrillic)
- FAT-based subfile enumeration (streaming reads already done ✅)

## Usage

```dart
import 'package:garmin_img/garmin_img.dart';

final img = await GarminImg.open('gmapsupp.img');
for (final map in img.maps) {
  print(map.bounds);                 // BBox(S=… W=… N=… E=…)
  print(map.levels);                 // [MapLevel(zoom bpc n)…]
  for (final f in map.polylines()) // decoded polyline start points
    print(f);
}
```

## Scope

- **Unlocked images only** (XOR byte `0x00`, "GARMIN" markers in the clear).
  Encrypted Garmin maps are out of scope.
- Web-Mercator / Garmin 24-bit coordinates.

## License

MIT.
