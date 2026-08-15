import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/camera_diagnostics.dart';

void main() {
  test('embedding exception receives its own sanitized classification', () {
    final privatePath = ['C:', 'Users', 'private', 'aligned.png'].join(r'\');
    final privateSource = ['C:', 'Users', 'private', 'source.dart'].join(r'\');
    final wrapped = CameraPipelineException(
      stage: CameraProcessingStage.embeddingInference,
      cause: StateError('$privatePath failed'),
      causeStackTrace: StackTrace.fromString('#0 $privateSource:12'),
    );
    final failure = CameraScanFailure.classify(
      wrapped,
      StackTrace.empty,
      activeStage: CameraProcessingStage.idle,
    );

    expect(failure.kind, CameraScanFailureKind.embeddingInference);
    expect(failure.userMessage, 'Embedding inference failed');
    expect(failure.exceptionType, 'StateError');
    expect(failure.sanitizedMessage, isNot(contains(privatePath)));
    expect(failure.sanitizedStackTrace, isNot(contains(privateSource)));
  });

  test('debug record includes bounded state and operation flags', () {
    final failure = CameraScanFailure.classify(
      StateError('detector stopped'),
      StackTrace.fromString('#0 FacePipeline.detect (package:test.dart:1)'),
      activeStage: CameraProcessingStage.yunetInference,
    );
    final record = CameraScanDebugRecord(
      failure: failure,
      flowStateBeforeFailure: 'stabilizing',
      mostRecentSuccessfulTransition: 'camera_initialized -> streaming',
      imageStreamingActive: true,
      stillCaptureRequested: false,
      yunetInferenceActive: true,
      embeddingInferenceActive: false,
      livenessEvaluationActive: false,
      controllerInitialized: true,
      widgetMounted: true,
      processingLockActive: true,
      rawWidth: 720,
      rawHeight: 480,
      uprightWidth: 480,
      uprightHeight: 720,
      imageFormat: 'yuv420',
      elapsedMilliseconds: 1250,
    );
    final text = record.toSanitizedText();
    expect(text, contains('failure=detectorRuntime'));
    expect(text, contains('flow_before=stabilizing'));
    expect(text, contains('streaming=true'));
    expect(text, contains('still_capture=false'));
    expect(text, contains('raw=720x480'));
    expect(text, contains('upright=480x720'));
  });

  test('stream source copies frames and never requests a still picture', () {
    final source = File('lib/src/camera_scan_screen.dart').readAsStringSync();
    expect(source, isNot(contains('takePicture(')));
    expect(source, contains('copyCameraFrame('));
    expect(source, contains('analyzeOwnedCameraFrame('));
    expect(
      source.indexOf('copyCameraFrame('),
      lessThan(source.indexOf('analyzeOwnedCameraFrame(')),
    );
  });

  test('aligned image remains leased until native inference completes', () {
    final source = File('lib/src/face_pipeline.dart').readAsStringSync();
    final awaitedInference = source.indexOf(
      'return await _runtime.inferAlignedImage(alignedFile.path);',
    );
    final deletion = source.indexOf('await alignedFile.delete();');
    expect(awaitedInference, greaterThanOrEqualTo(0));
    expect(deletion, greaterThan(awaitedInference));
  });
}
