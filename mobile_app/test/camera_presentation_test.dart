import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/camera_diagnostics.dart';
import 'package:offline_trucking_attendance/src/camera_flow.dart';
import 'package:offline_trucking_attendance/src/camera_scan_screen.dart';
import 'package:offline_trucking_attendance/src/secure_liveness_flow.dart';

void main() {
  test(
    'normal guidance hides technical pose state while debug preserves it',
    () {
      const technical = 'Turn detected — return your head to center';
      expect(
        cameraGuidanceFor(
          debugMode: false,
          stage: SecureLivenessStage.headReturn,
          detailedGuidance: technical,
          purpose: ScanPurpose.attendance,
        ),
        'Turn back to center',
      );
      expect(
        cameraGuidanceFor(
          debugMode: true,
          stage: SecureLivenessStage.headReturn,
          detailedGuidance: technical,
          purpose: ScanPurpose.attendance,
        ),
        technical,
      );
    },
  );

  test('normal attendance failures are specific and non-technical', () {
    expect(
      normalAttendanceMessage('Position your face'),
      'No face detected. Position your face inside the guide.',
    );
    expect(
      normalAttendanceMessage('Multiple faces detected'),
      'Only one person should be visible.',
    );
    expect(
      normalAttendanceMessage('Move closer'),
      'Move closer to the camera.',
    );
    expect(
      normalAttendanceMessage('Keep your full face inside the oval'),
      'Move slightly farther from the camera.',
    );
    expect(
      normalAttendanceMessage('Hold the phone and your face still'),
      'Your face image is unclear. Move to a brighter area and hold still.',
    );
    expect(
      normalAttendanceMessage('Verification failed'),
      'Face not recognized. Please try again.',
    );
    expect(
      normalAttendanceMessage('GPS validation failed'),
      'Your location could not be verified. Please enable location services and try again.',
    );
    expect(
      normalAttendanceMessage(
        'Attendance saved offline. It will sync when internet is available.',
      ),
      'Attendance saved offline. It will sync when internet is available.',
    );
    expect(
      normalCameraFailureMessage(CameraScanFailureKind.embeddingInference),
      isNot(contains('Embedding')),
    );
  });

  test('Debug Mode continues to expose the existing technical guidance', () {
    const technical = 'Multiple faces detected';
    expect(
      cameraGuidanceFor(
        debugMode: true,
        stage: SecureLivenessStage.quality,
        detailedGuidance: technical,
        purpose: ScanPurpose.attendance,
      ),
      technical,
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
        screenIllumination: ScreenIllumination.neutral,
      ),
      Colors.white,
    );
    expect(
      resolveLivenessPerimeterColor(
        illuminated: true,
        screenIllumination: ScreenIllumination.white,
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

  test('presentation contains no color-response states or prompts', () {
    final controller = File(
      'lib/src/secure_liveness_flow.dart',
    ).readAsStringSync();
    final screen = File('lib/src/camera_scan_screen.dart').readAsStringSync();
    final activeSource = '$controller\n$screen'.toLowerCase();

    for (final obsolete in [
      'colorbaseline',
      'colorchallenge',
      'color response',
      'sampling the green',
      'sampling the red',
      'sampling the blue',
      'photosensitivity',
    ]) {
      expect(activeSource, isNot(contains(obsolete)));
    }
  });
}
