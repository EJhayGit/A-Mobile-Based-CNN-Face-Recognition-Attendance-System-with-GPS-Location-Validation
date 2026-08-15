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

Map<String, SkinRegionColor> skin({
  double red = 100,
  double green = 100,
  double blue = 100,
}) => {
  for (final name in ['forehead', 'leftCheek', 'rightCheek', 'noseBridge'])
    name: SkinRegionColor(red: red, green: green, blue: blue),
};

int Function(int) fixedChallengeRandom(HeadTurnDirection direction) {
  var callIndex = 0;
  return (maximum) {
    final value = callIndex == 0 ? direction.index : 0;
    callIndex++;
    return value.clamp(0, maximum - 1);
  };
}

class FlowHarness {
  FlowHarness({
    ScanPurpose purpose = ScanPurpose.attendance,
    HeadTurnDirection direction = HeadTurnDirection.left,
  }) : flow = SecureLivenessController(
         purpose: purpose,
         nextRandomInt: fixedChallengeRandom(direction),
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
    Map<String, SkinRegionColor>? regions,
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
      skinRegions: regions ?? skin(),
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

  void reachColorChallenge() {
    reachHeadTurn();
    frames(2, yaw: 18);
    expect(flow.stage, SecureLivenessStage.headReturn);
    frames(2);
    expect(flow.stage, SecureLivenessStage.colorBaseline);
    frames(3);
    expect(flow.stage, SecureLivenessStage.colorChallenge);
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
        () async {
          throw StateError('expected');
        },
      ),
      throwsStateError,
    );
    expect(gate.locked, isFalse);
  });

  test('fresh randomized session never reuses its identifier', () {
    final harness = FlowHarness();
    final first = harness.flow.sessionId;
    expect(harness.flow.direction, HeadTurnDirection.left);
    expect(harness.flow.colorSequence, [ChallengeScreenColor.red]);
    harness.flow.restart();
    expect(harness.flow.sessionId, isNot(first));
    expect(harness.flow.stage, SecureLivenessStage.quality);
  });

  test('stale session and face loss reset progress without capture', () {
    final harness = FlowHarness();
    harness.frames(2);
    expect(harness.flow.stage, SecureLivenessStage.quality);
    harness.frame(sessionId: 'stale-session');
    expect(harness.flow.stage, SecureLivenessStage.quality);
    expect(harness.flow.captureInFlight, isFalse);
    harness.frame(yunet: const FaceObservation.none(), quality: null);
    expect(harness.flow.stage, SecureLivenessStage.quality);
    expect(harness.flow.captureInFlight, isFalse);
  });

  test(
    'low-light illumination stays steady through exposure stabilization',
    () {
      final harness = FlowHarness();
      final low = harness.frame(quality: lowLightQuality);
      expect(low.screenColor, ChallengeScreenColor.white);
      final stabilizing = harness.frame(quality: exposureStabilizingQuality);
      expect(stabilizing.screenColor, ChallengeScreenColor.white);
      expect(stabilizing.raiseWindowBrightness, isTrue);
      expect(stabilizing.lowLightIllumination, isTrue);
      expect(harness.frame().screenColor, ChallengeScreenColor.white);
      expect(harness.frame().screenColor, ChallengeScreenColor.white);
      final stable = harness.frame();
      expect(stable.screenColor, ChallengeScreenColor.neutral);
      expect(stable.lowLightIllumination, isFalse);
      expect(harness.flow.stage, SecureLivenessStage.headTurn);
    },
  );

  test('operator-left challenge uses positive yaw relative to center', () {
    final harness = FlowHarness()..reachHeadTurn(centeredYaw: 6);
    harness.frames(3, yaw: -12);
    expect(harness.flow.stage, SecureLivenessStage.headTurn);
    expect(harness.flow.guidance, contains('Wrong direction'));
    final first = harness.frame(yaw: 21);
    expect(first.headTurnDiagnostic?.baselineYaw, 6);
    expect(first.headTurnDiagnostic?.yawDelta, 15);
    expect(first.headTurnDiagnostic?.turnFrames, 1);
    final accepted = harness.frame(yaw: 21);
    expect(accepted.guidance, contains('Turn detected'));
    expect(harness.flow.stage, SecureLivenessStage.headReturn);
    harness.frames(2, yaw: 6);
    expect(harness.flow.stage, SecureLivenessStage.colorBaseline);
  });

  test('operator-right challenge uses negative yaw relative to center', () {
    final harness = FlowHarness(direction: HeadTurnDirection.right)
      ..reachHeadTurn(centeredYaw: -4);
    harness.frames(3, yaw: 12);
    expect(harness.flow.stage, SecureLivenessStage.headTurn);
    expect(harness.flow.guidance, contains('Wrong direction'));
    harness.frames(2, yaw: -19);
    expect(harness.flow.stage, SecureLivenessStage.headReturn);
  });

  test('natural turn displacement pauses without restarting the challenge', () {
    final harness = FlowHarness()..reachHeadTurn();
    final displaced = validFace(centerX: 0.90, faceWidthRatio: 0.86);
    harness.frames(2, yaw: 18, yunet: displaced);
    expect(harness.flow.stage, SecureLivenessStage.headReturn);

    final outsideActive = validFace(faceWidthRatio: 0.95);
    harness.frame(yaw: 18, yunet: outsideActive);
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

  test('neutral color baseline raises brightness before challenge color', () {
    final harness = FlowHarness()..reachHeadTurn();
    harness.frames(2, yaw: 18);
    harness.frames(2);
    expect(harness.flow.stage, SecureLivenessStage.colorBaseline);
    final baseline = harness.frame();
    expect(baseline.screenColor, ChallengeScreenColor.neutral);
    expect(baseline.raiseWindowBrightness, isTrue);
    expect(baseline.showPhotosensitivityWarning, isTrue);
  });

  test('one attendance color uses a monotonic aggregate sampling window', () {
    final harness = FlowHarness()..reachColorChallenge();
    expect(harness.flow.colorSequence.first, ChallengeScreenColor.red);
    harness.now = harness.now.add(SecureLivenessRules.colorTransitionDelay);

    final mismatchBefore = harness.frame(regions: skin(green: 115));
    expect(
      mismatchBefore.progress,
      1 / SecureLivenessRules.colorSampleWindowFrames,
    );
    expect(mismatchBefore.colorDiagnostic?.sampledFrames, 1);
    expect(mismatchBefore.colorDiagnostic?.matchingFrames, 0);

    final firstMatch = harness.frame(regions: skin(red: 115));
    expect(
      firstMatch.progress,
      2 / SecureLivenessRules.colorSampleWindowFrames,
    );
    expect(firstMatch.colorDiagnostic?.matchingFrames, 1);
    expect(firstMatch.colorDiagnostic?.bestCoherentRegions, 4);
    expect(firstMatch.colorDiagnostic?.bestTargetDelta, 15);
    expect(firstMatch.colorDiagnostic?.bestDominanceMargin, 15);

    final mismatchBetween = harness.frame(regions: skin(blue: 115));
    expect(
      mismatchBetween.progress,
      3 / SecureLivenessRules.colorSampleWindowFrames,
    );
    expect(mismatchBetween.colorDiagnostic?.matchingFrames, 1);
    expect(harness.flow.stage, SecureLivenessStage.colorChallenge);
    expect(harness.flow.colorSequence.first, ChallengeScreenColor.red);

    final secondMatch = harness.frame(regions: skin(red: 115));
    expect(secondMatch.colorDiagnostic?.sampledFrames, 4);
    expect(secondMatch.colorDiagnostic?.matchingFrames, 2);
    expect(harness.flow.stage, SecureLivenessStage.captureStabilizing);
    final first = harness.frame();
    final second = harness.frame();
    final third = harness.frame();
    expect(first.captureRequested, isFalse);
    expect(second.captureRequested, isFalse);
    expect(third.captureRequested, isTrue);
    expect(harness.flow.stage, SecureLivenessStage.processing);
  });

  test('temporary quality loss preserves a partial color response', () {
    final harness = FlowHarness()..reachColorChallenge();
    harness.now = harness.now.add(SecureLivenessRules.colorTransitionDelay);

    final firstMatch = harness.frame(regions: skin(red: 115));
    expect(firstMatch.colorDiagnostic?.sampledFrames, 1);
    expect(firstMatch.colorDiagnostic?.matchingFrames, 1);

    final paused = harness.frame(quality: null, regions: skin(red: 115));
    expect(harness.flow.stage, SecureLivenessStage.colorChallenge);
    expect(paused.colorDiagnostic?.sampledFrames, 1);
    expect(paused.colorDiagnostic?.matchingFrames, 1);
    expect(paused.screenColor, ChallengeScreenColor.red);
    expect(paused.guidance, contains('current step paused'));

    final secondMatch = harness.frame(regions: skin(red: 115));
    expect(secondMatch.colorDiagnostic?.sampledFrames, 2);
    expect(secondMatch.colorDiagnostic?.matchingFrames, 2);
    expect(harness.flow.stage, SecureLivenessStage.captureStabilizing);
  });

  test('quality retry after liveness stays in capture stabilization', () {
    final harness = FlowHarness()..reachColorChallenge();
    harness.now = harness.now.add(SecureLivenessRules.colorTransitionDelay);
    harness.frame(regions: skin(red: 115));
    harness.frame(regions: skin(red: 115));
    expect(harness.flow.stage, SecureLivenessStage.captureStabilizing);
    expect(harness.flow.livenessCompleted, isTrue);

    harness.frame();
    final paused = harness.frame(quality: exposureStabilizingQuality);
    expect(harness.flow.stage, SecureLivenessStage.captureStabilizing);
    expect(harness.flow.livenessCompleted, isTrue);
    expect(paused.guidance, contains('capture paused'));

    harness.frames(3);
    expect(harness.flow.stage, SecureLivenessStage.processing);
    expect(harness.flow.captureInFlight, isTrue);
  });

  test('capture positioning retry cannot restart the completed challenge', () {
    final harness = FlowHarness()..reachColorChallenge();
    harness.now = harness.now.add(SecureLivenessRules.colorTransitionDelay);
    harness.frame(regions: skin(red: 115));
    harness.frame(regions: skin(red: 115));
    expect(harness.flow.livenessCompleted, isTrue);

    harness.frame(yunet: validFace(faceWidthRatio: 0.86));
    expect(harness.flow.stage, SecureLivenessStage.captureStabilizing);
    expect(harness.flow.livenessCompleted, isTrue);
    harness.frames(3);
    expect(harness.flow.stage, SecureLivenessStage.processing);
  });

  test('invalid continuity after liveness still resets fail closed', () {
    final harness = FlowHarness()..reachColorChallenge();
    harness.now = harness.now.add(SecureLivenessRules.colorTransitionDelay);
    harness.frame(regions: skin(red: 115));
    harness.frame(regions: skin(red: 115));
    expect(harness.flow.livenessCompleted, isTrue);

    harness.frame(sessionId: 'stale-session');
    expect(harness.flow.stage, SecureLivenessStage.quality);
    expect(harness.flow.livenessCompleted, isFalse);
    expect(harness.flow.captureInFlight, isFalse);
  });

  test('invalid MediaPipe still resets an active color stage', () {
    final harness = FlowHarness()..reachColorChallenge();
    harness.now = harness.now.add(SecureLivenessRules.colorTransitionDelay);
    harness.frame(regions: skin(red: 115));

    final reset = harness.frame(
      quality: lowLightQuality,
      sessionId: 'stale-session',
    );
    expect(harness.flow.stage, SecureLivenessStage.quality);
    expect(reset.colorDiagnostic, isNull);
    expect(reset.guidance, 'Detailed liveness landmarks unavailable');
    expect(harness.flow.captureInFlight, isFalse);
  });

  test('one weak color window fails once without retrying or capture', () {
    final harness = FlowHarness()..reachColorChallenge();
    harness.now = harness.now.add(SecureLivenessRules.colorTransitionDelay);
    final oneRegionOnly = skin(green: 115)
      ..['forehead'] = const SkinRegionColor(red: 115, green: 100, blue: 100);

    SecureLivenessUpdate? update;
    for (
      var index = 0;
      index < SecureLivenessRules.colorSampleWindowFrames;
      index++
    ) {
      update = harness.frame(regions: oneRegionOnly);
      expect(
        update.progress,
        (index + 1) / SecureLivenessRules.colorSampleWindowFrames,
      );
    }

    expect(harness.flow.stage, SecureLivenessStage.failed);
    expect(harness.flow.captureInFlight, isFalse);
    expect(update?.captureRequested, isFalse);
    expect(update?.guidance, 'Color response not detected; please try again');
    expect(
      update?.colorDiagnostic?.sampledFrames,
      SecureLivenessRules.colorSampleWindowFrames,
    );
    expect(update?.colorDiagnostic?.matchingFrames, 0);
    expect(update?.colorDiagnostic?.bestCoherentRegions, 1);
    expect(update?.colorDiagnostic?.requiredCoherentRegions, 2);
  });

  test('registration skips color and authorizes three separated captures', () {
    final harness = FlowHarness(purpose: ScanPurpose.registration)
      ..reachHeadTurn()
      ..frames(2, yaw: 18)
      ..frames(2);
    expect(harness.flow.colorSequence, isEmpty);
    expect(harness.flow.stage, SecureLivenessStage.captureStabilizing);
    harness.frames(3);
    expect(harness.flow.captureInFlight, isTrue);
    harness.flow.captureCompleted(harness.now);
    expect(harness.flow.stage, SecureLivenessStage.captureCooldown);
    harness.frame();
    expect(harness.flow.captureInFlight, isFalse);
    harness.now = harness.now.add(CameraFlowRules.enrollmentCaptureSeparation);
    harness.frames(3);
    expect(harness.flow.captureInFlight, isTrue);
    harness.flow.captureCompleted(harness.now);
    harness.now = harness.now.add(CameraFlowRules.enrollmentCaptureSeparation);
    harness.frames(3);
    expect(harness.flow.captureInFlight, isTrue);
    harness.flow.captureCompleted(harness.now);
    expect(harness.flow.stage, SecureLivenessStage.completed);
    expect(harness.flow.completedCaptures, 3);
  });

  test('continuity loss discards enrollment samples before re-liveness', () {
    final harness = FlowHarness(purpose: ScanPurpose.registration)
      ..reachHeadTurn()
      ..frames(2, yaw: 18)
      ..frames(2)
      ..frames(3);
    harness.flow.captureCompleted(harness.now);
    expect(harness.flow.completedCaptures, 1);
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
