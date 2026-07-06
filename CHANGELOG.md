## 0.0.1

- Initial skeleton: IMG container + GMP sub-maps, TRE (bounds, map levels,
  subdivisions), and polyline first-point decode. Validated against a real
  NT/GMP topo sample.

## 0.0.2

- Full polyline bitstream decode (all vertices), per-level subdivision walk
  with bits-per-coord, sanity-terminated chunk iteration. Decodes topo contour
  lines. Added example/img2geojson.dart. Validated against a real ~294MB topo.
