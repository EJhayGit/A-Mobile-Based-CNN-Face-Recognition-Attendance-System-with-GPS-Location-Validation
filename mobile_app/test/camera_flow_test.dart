import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/camera_flow.dart';
import 'package:offline_trucking_attendance/src/capture_quality.dart';
import 'package:offline_trucking_attendance/src/liveness_runtime.dart';
import 'package:offline_trucking_attendance/src/secure_liveness_flow.dart';

FaceObservation validFace({
  double confidence = 0.95,
  double centerX = 0.5,
  double centerY = 0.5,
  double faceWidthRatio = 0.4,
}) => FaceObservation(
  productionFaceCount: 1,
  productionConfidence: confidence,
  debugCandidateCount: 1,
  highestDebugConfidence: confidence,
  geometryValid: true,
  centerX: centerX,
  centerY: centerY,
  faceWidthRatio: faceWidthRatio,
  noseOffsetEyeDistances: 0,
  rejectionReason: 'accepted',
  boxX: 0.3,
  boxY: 0.25,
  boxWidth: 0.4,
  boxHeight: 0.5,
);

const acceptableQuality = CaptureQuality(
  state: CaptureQualityState.acceptable,
  meanLuminance: 105,
  underexposedProportion: 0.02,
  overexposedProportion: 0,
  contrast: 30,
  focusVariance: 120,
  brightnessDelta: 1,
);

const lowLightQuality = CaptureQuality(
  state: CaptureQualityState.tooLow,
  meanLuminance: 35,
  underexposedProportion: 0.7,
  overexposedProportion: 0,
  contrast: 18,
  focusVariance: 80,
  brightnessDelta: 1,
);

const exposureStabilizingQuality = CaptureQuality(
  state: CaptureQualityState.exposureStabilizing,
  meanLuminance: 80,
  underexposedProportion: 0.1,
  overexposedProportion: 0,
  contrast: 28,
  focusVariance: 90,
  brightnessDelta: 30,
);

class FlowHarness {
  FlowHarness({
    ScanPurpose purpose = ScanPurpose.attendance,
    HeadTurnDirection direction = HeadTurnDirection.left,
  }) : flow = SecureLivenessController(
         purpose: purpose,
         nextRandomInt: (_) => direction.index,
       );

  final SecureLivenessController flow;
  DateTime now = DateTime.utc(2026, 8, 2);
  int timestamp = 1;

  SecureLivenessUpdate frame({
    FaceObservation? yunet,
    CaptureQuality? quality = acceptableQuality,
    double yaw = 0,
    double centerX = 0.5,
    double centerY = 0.5,
    double faceWidth = 0.4,
    String? sessionId,
    Duration advance = const Duration(milliseconds: 250),
  }) {
    final currentTimestamp = timestamp++;
    final observation = MediaPipeObservation(
      sessionId: sessionId ?? flow.sessionId,
      timestampMs: currentTimestamp,
      resultTimestampMs: currentTimestamp,
      inferenceMs: 15,
      faceCount: 1,
      landmarkCount: 478,
      transformationAvailable: true,
      yawDegrees: yaw,
      centerX: centerX,
      centerY: centerY,
      faceWidth: faceWidth,
      skinRegions: const {},
    );
    final update = flow.process(
      SecureLivenessEvidence(
        yunet: yunet ?? validFace(),
        quality: quality,
        mediaPipe: observation,
        now: now,
      ),
    );
    now = now.add(advance);
    return update;
  }

  void frames(int count, {double yaw = 0, FaceObservation? yunet}) {
    for (var index = 0; index < count; index++) {
      frame(yaw: yaw, yunet: yunet);
    }
  }

  void reachHeadTurn({double centeredYaw = 0}) {
    frames(3, yaw: centeredYaw);
    expect(flow.stage, SecureLivenessStage.headTurn);
  }

  void completePose({double centeredYaw = 0}) {
    reachHeadTurn(centeredYaw: centeredYaw);
    final turnYaw = flow.direction == HeadTurnDirection.left
        ? centeredYaw + 18
        : centeredYaw - 18;
    frames(2, yaw: turnYaw);
    expect(flow.stage, SecureLivenessStage.headReturn);
    frames(2, yaw: centeredYaw);
    expect(flow.stage, SecureLivenessStage.captureStabilizing);
    expect(flow.livenessCompleted, isTrue);
  }
}

void main() {
  test(
    'production YuNet boundary remains exact and diagnostics cannot pass',
    () {
      expect(CameraFlowRules.productionThreshold, 0.9);
      expect(CameraFlowRules.debugReportingThreshold, 0.3);
      expect(validFace(confidence: 0.9).hasProductionFace, isTrue);
      expect(validFace(confidence: 0.8999).hasProductionFace, isFalse);
      expect(validFace(faceWidthRatio: 0.75).inTargetRegion, isTrue);
      expect(validFace(faceWidthRatio: 0.86).inTargetRegion, isFalse);
      expect(validFace(faceWidthRatio: 0.86).inActiveLivenessRegion, isTrue);
      const diagnosticOnly = FaceObservation.none(
        debugCandidateCount: 1,
        highestDebugConfidence: 0.8,
        rejectionReason: 'below_production_threshold',
      );
      expect(diagnosticOnly.hasProductionFace, isFalse);
    },
  );

  test('frame gate drops overlap and always releases after failure', () async {
    final gate = FrameProcessingGate();
    final start = DateTime.utc(2026, 8, 2);
    expect(gate.tryAcquire(start), isTrue);
    expect(gate.tryAcquire(start.add(const Duration(seconds: 1))), isFalse);
    gate.release();
    expect(
      gate.tryAcquire(start.add(const Duration(milliseconds: 199))),
      isFalse,
    );
    await expectLater(
      gate.runIfAcquired(
        start.add(const Duration(milliseconds: 200)),
        () async => throw StateError('expected'),
      ),
      throwsStateError,
    );
    expect(gate.locked, isFalse);
  });

  test('fresh session randomizes only pose and has no color states', () {
    final harness = FlowHarness();
    final first = harness.flow.sessionId;
    expect(harness.flow.direction, HeadTurnDirection.left);
    final stages = SecureLivenessStage.values.map((stage) => stage.name);
    expect(stages, isNot(contains('colorBaseline')));
    expect(stages, isNot(contains('colorChallenge')));
    expect(ScreenIllumination.values, [
      ScreenIllumination.neutral,
      ScreenIllumination.white,
    ]);
    harness.flow.restart();
    expect(harness.flow.sessionId, isNot(first));
    expect(harness.flow.stage, SecureLivenessStage.quality);
  });

  test('stale session and face loss reset progress without capture', () {
    final harness = FlowHarness();
    harness.frames(2);
    harness.frame(sessionId: 'stale-session');
    expect(harness.flow.stage, SecureLivenessStage.quality);
    harness.frame(yunet: const FaceObservation.none(), quality: null);
    expect(harness.flow.stage, SecureLivenessStage.quality);
    expect(harness.flow.captureInFlight, isFalse);
  });

  test(
    'low-light illumination stays steady through exposure stabilization',
    () {
      final harness = FlowHarness();
      final low = harness.frame(quality: lowLightQuality);
      expect(low.screenIllumination, ScreenIllumination.white);
      final stabilizing = harness.frame(quality: exposureStabilizingQuality);
      expect(stabilizing.screenIllumination, ScreenIllumination.white);
      expect(stabilizing.raiseWindowBrightness, isTrue);
      expect(stabilizing.lowLightIllumination, isTrue);
      expect(harness.frame().screenIllumination, ScreenIllumination.white);
      expect(harness.frame().screenIllumination, ScreenIllumination.white);
      final stable = harness.frame();
      expect(stable.screenIllumination, ScreenIllumination.neutral);
      expect(stable.lowLightIllumination, isFalse);
      expect(harness.flow.stage, SecureLivenessStage.headTurn);
    },
  );

  test('operator-left pose completes directly into capture stabilization', () {
    final harness = FlowHarness()..reachHeadTurn(centeredYaw: 6);
    harness.frames(3, yaw: -12);
    expect(harness.flow.stage, SecureLivenessStage.headTurn);
    expect(harness.flow.guidance, contains('Wrong direction'));
    final first = harness.frame(yaw: 21);
    expect(first.headTurnDiagnostic?.baselineYaw, 6);
    expect(first.headTurnDiagnostic?.yawDelta, 15);
    expect(first.headTurnDiagnostic?.turnFrames, 1);
    harness.frame(yaw: 21);
    expect(harness.flow.stage, SecureLivenessStage.headReturn);
    harness.frames(2, yaw: 6);
    expect(harness.flow.stage, SecureLivenessStage.captureStabilizing);
    expect(harness.flow.guidance, 'Liveness complete; hold still');
  });

  test('operator-right pose uses negative yaw relative to center', () {
    final harness = FlowHarness(direction: HeadTurnDirection.right)
      ..reachHeadTurn(centeredYaw: -4);
    harness.frames(3, yaw: 12);
    expect(harness.flow.stage, SecureLivenessStage.headTurn);
    expect(harness.flow.guidance, contains('Wrong direction'));
    harness.frames(2, yaw: -19);
    expect(harness.flow.stage, SecureLivenessStage.headReturn);
    harness.frames(2, yaw: -4);
    expect(harness.flow.stage, SecureLivenessStage.captureStabilizing);
  });

  test('natural turn displacement pauses without restarting the challenge', () {
    final harness = FlowHarness()..reachHeadTurn();
    final displaced = validFace(centerX: 0.90, faceWidthRatio: 0.86);
    harness.frames(2, yaw: 18, yunet: displaced);
    expect(harness.flow.stage, SecureLivenessStage.headReturn);
    harness.frame(yaw: 18, yunet: validFace(faceWidthRatio: 0.95));
    expect(harness.flow.stage, SecureLivenessStage.headReturn);
    expect(harness.flow.guidance, 'Keep your full face inside the oval');
  });

  test('temporary active-stage quality loss pauses without resetting yaw', () {
    final harness = FlowHarness()..reachHeadTurn(centeredYaw: 4);
    final firstTurn = harness.frame(yaw: 19);
    expect(firstTurn.headTurnDiagnostic?.turnFrames, 1);
    final paused = harness.frame(yaw: 19, quality: lowLightQuality);
    expect(harness.flow.stage, SecureLivenessStage.headTurn);
    expect(paused.headTurnDiagnostic?.baselineYaw, 4);
    expect(paused.headTurnDiagnostic?.turnFrames, 1);
    expect(paused.guidance, contains('current step paused'));
    harness.frame(yaw: 19);
    expect(harness.flow.stage, SecureLivenessStage.headReturn);
  });

  test('attendance pose authorizes capture and resets partial consensus', () {
    final harness = FlowHarness()..completePose();
    harness.frames(3);
    expect(harness.flow.captureInFlight, isTrue);
    expect(harness.flow.stage, SecureLivenessStage.processing);
    harness.flow.captureCompleted(harness.now);
    expect(harness.flow.completedCaptures, 1);
    expect(harness.flow.stage, SecureLivenessStage.captureCooldown);
    final resetToken = harness.flow.enrollmentResetToken;
    harness.frame(yunet: const FaceObservation.none(), quality: null);
    expect(harness.flow.completedCaptures, 0);
    expect(harness.flow.enrollmentResetToken, resetToken + 1);
    expect(harness.flow.livenessCompleted, isFalse);
    expect(harness.flow.captureInFlight, isFalse);
  });

  test('quality retry after pose stays in capture stabilization', () {
    final harness = FlowHarness()..completePose();
    harness.frame();
    final paused = harness.frame(quality: exposureStabilizingQuality);
    expect(harness.flow.stage, SecureLivenessStage.captureStabilizing);
    expect(harness.flow.livenessCompleted, isTrue);
    expect(paused.guidance, contains('capture paused'));
    harness.frames(3);
    expect(harness.flow.stage, SecureLivenessStage.processing);
    expect(harness.flow.captureInFlight, isTrue);
  });

  test('capture positioning retry cannot restart completed pose', () {
    final harness = FlowHarness()..completePose();
    harness.frame(yunet: validFace(faceWidthRatio: 0.86));
    expect(harness.flow.stage, SecureLivenessStage.captureStabilizing);
    expect(harness.flow.livenessCompleted, isTrue);
    harness.frames(3);
    expect(harness.flow.stage, SecureLivenessStage.processing);
  });

  test('invalid continuity after liveness still resets fail closed', () {
    final harness = FlowHarness()..completePose();
    harness.frame(sessionId: 'stale-session');
    expect(harness.flow.stage, SecureLivenessStage.quality);
    expect(harness.flow.livenessCompleted, isFalse);
    expect(harness.flow.captureInFlight, isFalse);
  });

  test('registration pose authorizes three separated captures', () {
    final harness = FlowHarness(purpose: ScanPurpose.registration)
      ..completePose()
      ..frames(3);
    expect(harness.flow.captureInFlight, isTrue);
    harness.flow.captureCompleted(harness.now);
    expect(harness.flow.stage, SecureLivenessStage.captureCooldown);
    harness.frame();
    expect(harness.flow.captureInFlight, isFalse);
    harness.now = harness.now.add(CameraFlowRules.enrollmentCaptureSeparation);
    harness.frames(3);
    harness.flow.captureCompleted(harness.now);
    harness.now = harness.now.add(CameraFlowRules.enrollmentCaptureSeparation);
    harness.frames(3);
    harness.flow.captureCompleted(harness.now);
    expect(harness.flow.stage, SecureLivenessStage.completed);
    expect(harness.flow.completedCaptures, 3);
  });

  test('continuity loss discards enrollment samples before re-liveness', () {
    final harness = FlowHarness(purpose: ScanPurpose.registration)
      ..completePose()
      ..frames(3);
    harness.flow.captureCompleted(harness.now);
    final resetToken = harness.flow.enrollmentResetToken;
    harness.frame(yunet: const FaceObservation.none(), quality: null);
    expect(harness.flow.completedCaptures, 0);
    expect(harness.flow.enrollmentResetToken, resetToken + 1);
    expect(harness.flow.stage, SecureLivenessStage.quality);
  });

  test('timeout is terminal and never requests recognition', () {
    final harness = FlowHarness();
    harness.frame();
    harness.now = harness.now.add(SecureLivenessRules.sessionTimeout);
    final update = harness.frame();
    expect(harness.flow.stage, SecureLivenessStage.timedOut);
    expect(update.captureRequested, isFalse);
    harness.frame();
    expect(harness.flow.captureInFlight, isFalse);
  });
}
