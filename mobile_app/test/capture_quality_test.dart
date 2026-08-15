import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/camera_flow.dart';
import 'package:offline_trucking_attendance/src/camera_geometry.dart';
import 'package:offline_trucking_attendance/src/capture_quality.dart';

final face = FaceObservation(
  productionFaceCount: 1,
  productionConfidence: 0.95,
  debugCandidateCount: 1,
  highestDebugConfidence: 0.95,
  geometryValid: true,
  centerX: 0.5,
  centerY: 0.5,
  faceWidthRatio: 0.5,
  noseOffsetEyeDistances: 0,
  rejectionReason: 'accepted',
  boxX: 0.1,
  boxY: 0.1,
  boxWidth: 0.8,
  boxHeight: 0.8,
);

UprightBgrFrame checkerFrame(int low, int high) {
  const width = 40;
  const height = 40;
  final bytes = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final value = ((x ~/ 2) + (y ~/ 2)).isEven ? low : high;
      final index = (y * width + x) * 3;
      bytes[index] = value;
      bytes[index + 1] = value;
      bytes[index + 2] = value;
    }
  }
  return UprightBgrFrame(width: width, height: height, bytes: bytes);
}

void main() {
  test('quality distinguishes stabilizing, acceptable, and low light', () {
    final analyzer = CaptureQualityAnalyzer();
    final first = analyzer.analyze(checkerFrame(70, 130), face);
    expect(first.state, CaptureQualityState.exposureStabilizing);
    final stable = analyzer.analyze(checkerFrame(70, 130), face);
    expect(stable.state, CaptureQualityState.acceptable);

    analyzer.reset();
    final dark = analyzer.analyze(checkerFrame(5, 35), face);
    expect(dark.state, CaptureQualityState.tooLow);
    expect(dark.needsIllumination, isTrue);
  });

  test('quality distinguishes glare, marginal light, and blur', () {
    final glareAnalyzer = CaptureQualityAnalyzer();
    final glare = glareAnalyzer.analyze(checkerFrame(245, 255), face);
    expect(glare.state, CaptureQualityState.glare);

    final marginalAnalyzer = CaptureQualityAnalyzer();
    marginalAnalyzer.analyze(checkerFrame(50, 80), face);
    final marginal = marginalAnalyzer.analyze(checkerFrame(50, 80), face);
    expect(marginal.state, CaptureQualityState.marginal);

    final blurAnalyzer = CaptureQualityAnalyzer();
    blurAnalyzer.analyze(checkerFrame(100, 100), face);
    final blur = blurAnalyzer.analyze(checkerFrame(100, 100), face);
    expect(blur.state, CaptureQualityState.blurry);
  });

  test('quality refuses absent YuNet authorization', () {
    final analyzer = CaptureQualityAnalyzer();
    expect(
      () =>
          analyzer.analyze(checkerFrame(70, 130), const FaceObservation.none()),
      throwsStateError,
    );
  });
}
