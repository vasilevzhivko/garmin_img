## 0.0.1

- Initial skeleton: IMG container + GMP sub-maps, TRE (bounds, map levels,
  subdivisions), and polyline first-point decode. Validated against a real
  NT/GMP topo sample.

## 0.0.2

- Full polyline bitstream decode (all vertices), per-level subdivision walk
  with bits-per-coord, sanity-terminated chunk iteration. Decodes topo contour
  lines. Added example/img2geojson.dart. Validated against a real ~294MB topo.

## 0.0.3

- Polygons (area fills) + points/POIs decoding (same RGN bitstream / point
  layout). example/img2geojson.dart now emits Point/LineString/Polygon. Tests
  cover all three feature kinds against the real sample.

## 0.0.4

- LBL labels: POI/feature names and contour elevation labels. Supports 8-bit
  (coding 9) and 6-bit (coding 6) label encodings. Features now carry `label`.

## 0.0.5

- Streaming reads: ByteSource abstraction with a file-backed, block-cached
  source (FileByteSource) so large maps are not loaded into RAM. GarminImg.open
  now streams; GarminImg.fromBytes stays in-memory. maps are scanned once/cached.
  Added close(). All decode tests pass via the streaming path.

## 0.0.6

- featuresInBounds(query, {onlyBpc}): decode only subdivisions overlapping a
  viewport (optionally a single map level), for fast on-device rendering.
  Per-subdivision decoders; subdivision bbox from center + width/height.
