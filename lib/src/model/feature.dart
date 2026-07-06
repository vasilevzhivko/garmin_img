import 'geo.dart';

/// The kind of a decoded map element.
enum FeatureKind { point, polyline, polygon }

/// A decoded map feature. [type] is the Garmin type code (e.g. 0x20–0x25 are
/// contour lines for topo maps; extended types are 0x10000+). [points] is the
/// decoded geometry (a single point for [FeatureKind.point]). [label] is the
/// text/elevation when resolved from LBL (null until LBL decoding is wired).
class ImgFeature {
  final FeatureKind kind;
  final int type;
  final List<LatLng> points;
  final String? label;

  const ImgFeature({
    required this.kind,
    required this.type,
    required this.points,
    this.label,
  });

  @override
  String toString() =>
      'ImgFeature(${kind.name} type=0x${type.toRadixString(16)} '
      'pts=${points.length}${label != null ? ' "$label"' : ''})';
}
