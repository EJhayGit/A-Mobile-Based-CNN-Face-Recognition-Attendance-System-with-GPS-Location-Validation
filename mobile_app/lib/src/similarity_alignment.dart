import 'dart:math' as math;

class Point2d {
  const Point2d(this.x, this.y);

  final double x;
  final double y;
}

const frozenAlignmentTarget = <Point2d>[
  Point2d(76.5892, 103.3926),
  Point2d(147.0636, 103.0028),
  Point2d(112.0504, 143.4732),
  Point2d(83.0986, 184.7310),
  Point2d(141.4598, 184.4082),
];

/// Returns the OpenCV 2x3 matrix for a least-squares, non-reflective
/// similarity transform: `[a, -b, tx, b, a, ty]`.
List<double> solveSimilarityTransform(
  List<Point2d> source,
  List<Point2d> target,
) {
  if (source.length != 5 || target.length != 5) {
    throw ArgumentError(
      'Exactly five source and target landmarks are required.',
    );
  }
  if ([
    ...source,
    ...target,
  ].any((point) => !point.x.isFinite || !point.y.isFinite)) {
    throw ArgumentError('Landmarks must be finite.');
  }
  final sourceMeanX = source.fold<double>(0, (sum, point) => sum + point.x) / 5;
  final sourceMeanY = source.fold<double>(0, (sum, point) => sum + point.y) / 5;
  final targetMeanX = target.fold<double>(0, (sum, point) => sum + point.x) / 5;
  final targetMeanY = target.fold<double>(0, (sum, point) => sum + point.y) / 5;

  var denominator = 0.0;
  var aNumerator = 0.0;
  var bNumerator = 0.0;
  for (var index = 0; index < 5; index++) {
    final sx = source[index].x - sourceMeanX;
    final sy = source[index].y - sourceMeanY;
    final tx = target[index].x - targetMeanX;
    final ty = target[index].y - targetMeanY;
    denominator += sx * sx + sy * sy;
    aNumerator += sx * tx + sy * ty;
    bNumerator += sx * ty - sy * tx;
  }
  if (!denominator.isFinite || denominator <= 1e-8) {
    throw ArgumentError('Landmarks do not define a stable transform.');
  }
  final a = aNumerator / denominator;
  final b = bNumerator / denominator;
  final scale = math.sqrt(a * a + b * b);
  if (!scale.isFinite || scale <= 1e-8) {
    throw ArgumentError('Computed similarity scale is invalid.');
  }
  final translateX = targetMeanX - a * sourceMeanX + b * sourceMeanY;
  final translateY = targetMeanY - b * sourceMeanX - a * sourceMeanY;
  return [a, -b, translateX, b, a, translateY];
}
