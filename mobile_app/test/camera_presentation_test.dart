import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/camera_flow.dart';
import 'package:offline_trucking_attendance/src/camera_scan_screen.dart';
import 'package:offline_trucking_attendance/src/secure_liveness_flow.dart';

void main() {
  test('normal guidance hides technical state while debug preserves it', () {
    const technical = 'Sampling the green response 1/8';
    expect(
      cameraGuidanceFor(
        debugMode: false,
        stage: SecureLivenessStage.colorChallenge,
        detailedGuidance: technical,
        purpose: ScanPurpose.attendance,
      ),
      'Checking liveness',
    );
    expect(
      cameraGuidanceFor(
        debugMode: true,
        stage: SecureLivenessStage.colorChallenge,
        detailedGuidance: technical,
        purpose: ScanPurpose.attendance,
      ),
      technical,
    );
    expect(
      cameraGuidanceFor(
        debugMode: false,
        stage: SecureLivenessStage.headReturn,
        detailedGuidance: 'Return your head to center',
        purpose: ScanPurpose.attendance,
      ),
      'Turn back to center',
    );
  });

  test('challenge perimeter is opaque while the camera oval stays clear', () {
    const size = Size(400, 800);
    const guide = Rect.fromLTWH(60, 120, 280, 520);
    final perimeter = buildLivenessPerimeterPath(size, guide);

    expect(perimeter.contains(const Offset(10, 10)), isTrue);
    expect(perimeter.contains(guide.center), isFalse);
    expect(
      resolveLivenessPerimeterColor(
        illuminated: false,
        screenColor: ChallengeScreenColor.red,
        colorBaselineActive: false,
      ),
      const Color(0xFFFF0000),
    );
  });

  test('normal mask is solid white outside a clear oval with slim edge', () {
    const size = Size(400, 800);
    const guide = Rect.fromLTWH(60, 120, 280, 520);
    final mask = buildLivenessPerimeterPath(size, guide);

    expect(mask.contains(const Offset(10, 10)), isTrue);
    expect(mask.contains(guide.center), isFalse);
    expect(faceGuideOutlineWidth, 4);
    expect(
      resolveLivenessPerimeterColor(
        illuminated: false,
        screenColor: ChallengeScreenColor.neutral,
        colorBaselineActive: false,
      ),
      Colors.white,
    );
    expect(
      resolveLivenessPerimeterColor(
        illuminated: true,
        screenColor: ChallengeScreenColor.white,
        colorBaselineActive: false,
      ),
      Colors.white,
    );
  });

  test('active camera session keeps maximum brightness across stages', () {
    final source = File('lib/src/camera_scan_screen.dart').readAsStringSync();

    expect(source, isNot(contains('update.raiseWindowBrightness')));
    expect(
      RegExp(r'await _ensureMaximumBrightness\(\);').allMatches(source).length,
      greaterThanOrEqualTo(3),
    );
    expect(source, contains('await _brightnessRuntime.setForIllumination();'));
  });

  test('color baseline is neutral and each challenge channel is pure', () {
    expect(
      resolveLivenessPerimeterColor(
        illuminated: false,
        screenColor: ChallengeScreenColor.neutral,
        colorBaselineActive: true,
      ),
      const Color(0xFF202020),
    );
    expect(
      resolveLivenessPerimeterColor(
        illuminated: false,
        screenColor: ChallengeScreenColor.green,
        colorBaselineActive: false,
      ),
      const Color(0xFF00FF00),
    );
    expect(
      resolveLivenessPerimeterColor(
        illuminated: false,
        screenColor: ChallengeScreenColor.blue,
        colorBaselineActive: false,
      ),
      const Color(0xFF0000FF),
    );
  });
}
