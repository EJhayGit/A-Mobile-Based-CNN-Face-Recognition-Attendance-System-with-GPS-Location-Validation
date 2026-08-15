import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/similarity_alignment.dart';

void main() {
  test('five-point solver reproduces an exact similarity transform', () {
    const source = [
      Point2d(0, 0),
      Point2d(2, 0),
      Point2d(1, 1),
      Point2d(0, 2),
      Point2d(2, 2),
    ];
    final target = source
        .map(
          (point) => Point2d(
            2 * point.x - 3 * point.y + 7,
            3 * point.x + 2 * point.y - 4,
          ),
        )
        .toList();
    final matrix = solveSimilarityTransform(source, target);
    expect(matrix, orderedEquals([2, -3, 7, 3, 2, -4]));
  });

  test('degenerate landmarks stop alignment', () {
    const points = [
      Point2d(1, 1),
      Point2d(1, 1),
      Point2d(1, 1),
      Point2d(1, 1),
      Point2d(1, 1),
    ];
    expect(
      () => solveSimilarityTransform(points, frozenAlignmentTarget),
      throwsArgumentError,
    );
  });
}
