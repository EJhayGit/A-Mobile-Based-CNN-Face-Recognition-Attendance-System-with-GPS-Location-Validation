import 'dart:math' as math;

import 'camera_flow.dart';
import 'capture_quality.dart';
import 'liveness_runtime.dart';

enum HeadTurnDirection { left, right }

enum ChallengeScreenColor { neutral, white, red, green, blue }

enum SecureLivenessStage {
  quality,
  headTurn,
  headReturn,
  colorBaseline,
  colorChallenge,
  captureStabilizing,
  captureCooldown,
  processing,
  completed,
  timedOut,
  failed,
}

class SecureLivenessRules {
  const SecureLivenessRules._();

  // Initial engineering constants. Only the approved bona fide calibration may
  // produce one documented adjustment set before these are frozen.
  static const sessionTimeout = Duration(seconds: 35);
  static const headTurnDegrees = 15.0;
  static const oppositeTurnDegrees = 10.0;
  static const centeredYawDegrees = 8.0;
  static const directionalFrames = 2;
  static const centeredReturnFrames = 2;
  static const colorBaselineFrames = 3;
  static const colorSampleWindowFrames = 8;
  static const colorRequiredMatchingFrames = 2;
  static const colorTransitionDelay = Duration(milliseconds: 700);
  static const minimumColorDelta = 8.0;
  static const colorDominanceMargin = 3.0;
  static const minimumColorBaselineRegions = 3;
  static const colorRequiredCoherentRegions = 2;
  static const maximumCenterDisplacement = 0.12;
  static const maximumWidthChangeFraction = 0.20;
}

class ColorResponseDiagnostic {
  const ColorResponseDiagnostic({
    required this.color,
    required this.sampledFrames,
    required this.sampleWindowFrames,
    required this.matchingFrames,
    required this.requiredMatchingFrames,
    required this.bestCoherentRegions,
    required this.requiredCoherentRegions,
    required this.bestTargetDelta,
    required this.bestDominanceMargin,
  });

  final ChallengeScreenColor color;
  final int sampledFrames;
  final int sampleWindowFrames;
  final int matchingFrames;
  final int requiredMatchingFrames;
  final int bestCoherentRegions;
  final int requiredCoherentRegions;
  final double? bestTargetDelta;
  final double? bestDominanceMargin;
}

class HeadTurnDiagnostic {
  const HeadTurnDiagnostic({
    required this.direction,
    required this.baselineYaw,
    required this.currentYaw,
    required this.yawDelta,
    required this.requiredYawDelta,
    required this.turnFrames,
    required this.requiredTurnFrames,
    required this.returnFrames,
    required this.requiredReturnFrames,
  });

  final HeadTurnDirection direction;
  final double baselineYaw;
  final double currentYaw;
  final double yawDelta;
  final double requiredYawDelta;
  final int turnFrames;
  final int requiredTurnFrames;
  final int returnFrames;
  final int requiredReturnFrames;
}

class SecureLivenessEvidence {
  const SecureLivenessEvidence({
    required this.yunet,
    required this.quality,
    required this.mediaPipe,
    required this.now,
  });

  final FaceObservation yunet;
  final CaptureQuality? quality;
  final MediaPipeObservation? mediaPipe;
  final DateTime now;
}

class SecureLivenessUpdate {
  const SecureLivenessUpdate({
    required this.captureRequested,
    required this.guidance,
    required this.progress,
    required this.screenColor,
    required this.raiseWindowBrightness,
    required this.lowLightIllumination,
    required this.showPhotosensitivityWarning,
    required this.colorDiagnostic,
    required this.headTurnDiagnostic,
  });

  final bool captureRequested;
  final String guidance;
  final double progress;
  final ChallengeScreenColor screenColor;
  final bool raiseWindowBrightness;
  final bool lowLightIllumination;
  final bool showPhotosensitivityWarning;
  final ColorResponseDiagnostic? colorDiagnostic;
  final HeadTurnDiagnostic? headTurnDiagnostic;
}

class SecureLivenessController {
  SecureLivenessController({
    required this.purpose,
    int Function(int max)? nextRandomInt,
  }) : _nextRandomInt = nextRandomInt ?? math.Random.secure().nextInt {
    _createFreshChallenge();
  }

  final ScanPurpose purpose;
  final int Function(int max) _nextRandomInt;

  late String _sessionId;
  late HeadTurnDirection _direction;
  late List<ChallengeScreenColor> _colorSequence;
  SecureLivenessStage _stage = SecureLivenessStage.quality;
  DateTime? _startedAt;
  DateTime? _nextCaptureAt;
  DateTime? _colorShownAt;
  MediaPipeObservation? _previousMediaPipe;
  double? _illuminationBaseline;
  double? _centerYawBaseline;
  int _qualityFrames = 0;
  int _headFrames = 0;
  int _returnFrames = 0;
  HeadTurnDiagnostic? _headTurnDiagnostic;
  int _colorBaselineCount = 0;
  final Map<String, List<double>> _colorBaselineSums = {};
  Map<String, SkinRegionColor> _colorBaseline = const {};
  int _colorIndex = 0;
  int _colorSampleFrames = 0;
  int _colorMatchingFrames = 0;
  _ColorFrameAssessment? _bestColorAssessment;
  ColorResponseDiagnostic? _colorDiagnostic;
  int _captureFrames = 0;
  int _completedCaptures = 0;
  int _enrollmentResetToken = 0;
  bool _captureInFlight = false;
  bool _livenessCompleted = false;
  bool _completionLock = false;
  String _guidance = 'Position your face';
  int _lastMediaPipeTimestamp = -1;

  String get sessionId => _sessionId;
  HeadTurnDirection get direction => _direction;
  List<ChallengeScreenColor> get colorSequence =>
      List.unmodifiable(_colorSequence);
  SecureLivenessStage get stage => _stage;
  int get completedCaptures => _completedCaptures;
  int get enrollmentResetToken => _enrollmentResetToken;
  bool get captureInFlight => _captureInFlight;
  bool get livenessCompleted => _livenessCompleted;
  bool get completionLocked => _completionLock;
  String get guidance => _guidance;

  SecureLivenessUpdate process(SecureLivenessEvidence evidence) {
    if (_completionLock ||
        _stage == SecureLivenessStage.completed ||
        _stage == SecureLivenessStage.failed ||
        _stage == SecureLivenessStage.timedOut) {
      return _update();
    }
    if (_captureInFlight || _stage == SecureLivenessStage.processing) {
      return _update();
    }
    _startedAt ??= evidence.now;
    if (evidence.now.difference(_startedAt!) >=
        SecureLivenessRules.sessionTimeout) {
      _stage = SecureLivenessStage.timedOut;
      _guidance = 'Liveness challenge timed out';
      return _update();
    }
    if (!evidence.yunet.hasProductionFace) {
      _resetActiveProgress(
        evidence.yunet.productionFaceCount > 1
            ? 'Multiple faces detected'
            : 'Position your face',
      );
      return _update();
    }
    final activeLivenessStage = _usesActiveLivenessPosition;
    final preserveCompletedLiveness = _livenessCompleted;
    final progressPreservingStage =
        activeLivenessStage || preserveCompletedLiveness;
    final mediaPipe = evidence.mediaPipe;
    if (progressPreservingStage && !_acceptMediaPipe(mediaPipe)) {
      return _update();
    }
    if (activeLivenessStage) {
      if (!evidence.yunet.inActiveLivenessRegion) {
        _pauseForActivePosition(evidence.yunet);
        return _update();
      }
    } else if (preserveCompletedLiveness) {
      if (!evidence.yunet.inTargetRegion) {
        _pauseForCapturePosition(evidence.yunet);
        return _update();
      }
    } else if (!evidence.yunet.inTargetRegion) {
      _resetActiveProgress(_positionGuidance(evidence.yunet));
      return _update();
    }
    final quality = evidence.quality;
    if (quality == null) {
      if (progressPreservingStage) {
        _pauseForProgressQuality('Lighting measurement unavailable');
        return _update();
      }
      _resetActiveProgress('Lighting measurement unavailable');
      return _update();
    }
    if (!quality.acceptable) {
      if (progressPreservingStage) {
        _pauseForProgressQuality(quality.guidance);
        return _update();
      }
      _qualityFrames = 0;
      _stage = SecureLivenessStage.quality;
      _guidance = quality.guidance;
      if (quality.needsIllumination) {
        _illuminationBaseline ??= quality.meanLuminance;
      } else if (quality.state == CaptureQualityState.glare) {
        _illuminationBaseline = null;
      }
      return _update();
    }
    final illuminationBaseline = _illuminationBaseline;
    if (illuminationBaseline != null &&
        quality.meanLuminance <
            illuminationBaseline +
                CaptureQualityRules.requiredIlluminationImprovement) {
      if (progressPreservingStage) {
        _pauseForProgressQuality(
          'Hold still while screen illumination stabilizes',
        );
        return _update();
      }
      _qualityFrames = 0;
      _stage = SecureLivenessStage.quality;
      _guidance = 'Hold still while screen illumination stabilizes';
      return _update();
    }

    if (!progressPreservingStage && !_acceptMediaPipe(mediaPipe)) {
      return _update();
    }

    switch (_stage) {
      case SecureLivenessStage.quality:
        _advanceQuality(mediaPipe!);
      case SecureLivenessStage.headTurn:
        _advanceHeadTurn(mediaPipe!);
      case SecureLivenessStage.headReturn:
        _advanceHeadReturn(mediaPipe!);
      case SecureLivenessStage.colorBaseline:
        _advanceColorBaseline(mediaPipe!, evidence.now);
      case SecureLivenessStage.colorChallenge:
        _advanceColorResponse(mediaPipe!, evidence.now);
      case SecureLivenessStage.captureCooldown:
        if (!evidence.now.isBefore(_nextCaptureAt!)) {
          _stage = SecureLivenessStage.captureStabilizing;
          _captureFrames = 0;
          _advanceCapture(mediaPipe!);
        } else {
          _guidance = 'Hold still for the next enrollment sample';
        }
      case SecureLivenessStage.captureStabilizing:
        _advanceCapture(mediaPipe!);
      case SecureLivenessStage.processing:
      case SecureLivenessStage.completed:
      case SecureLivenessStage.timedOut:
      case SecureLivenessStage.failed:
        break;
    }
    return _update(captureRequested: _captureInFlight);
  }

  void captureCompleted(DateTime now) {
    if (!_captureInFlight || _stage != SecureLivenessStage.processing) {
      throw StateError('No liveness-authorized capture is in progress.');
    }
    _captureInFlight = false;
    _completedCaptures++;
    final requiredCaptures = purpose == ScanPurpose.registration ? 3 : 1;
    if (_completedCaptures >= requiredCaptures) {
      _completionLock = true;
      _stage = SecureLivenessStage.completed;
      _guidance = purpose == ScanPurpose.registration
          ? 'Registration complete'
          : 'Processing';
      return;
    }
    _nextCaptureAt = now.add(CameraFlowRules.enrollmentCaptureSeparation);
    _stage = SecureLivenessStage.captureCooldown;
    _captureFrames = 0;
    _guidance = 'Enrollment sample ${_completedCaptures + 1} of 3';
  }

  void captureFailed(String message) {
    _captureInFlight = false;
    _completionLock = true;
    _stage = SecureLivenessStage.failed;
    _guidance = message;
  }

  void setCompletedMessage(String message) {
    if (!_completionLock || _stage != SecureLivenessStage.completed) {
      throw StateError('The scan has not completed.');
    }
    _guidance = message;
  }

  void restart() {
    _stage = SecureLivenessStage.quality;
    _startedAt = null;
    _nextCaptureAt = null;
    _previousMediaPipe = null;
    _illuminationBaseline = null;
    _centerYawBaseline = null;
    _qualityFrames = 0;
    _headFrames = 0;
    _returnFrames = 0;
    _headTurnDiagnostic = null;
    _resetColorBaseline();
    _colorIndex = 0;
    _resetColorResponse();
    _colorShownAt = null;
    _captureFrames = 0;
    _completedCaptures = 0;
    _captureInFlight = false;
    _livenessCompleted = false;
    _completionLock = false;
    _lastMediaPipeTimestamp = -1;
    _guidance = 'Position your face';
    _createFreshChallenge();
  }

  void _createFreshChallenge() {
    final random = math.Random.secure();
    final entropy = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _sessionId = '${DateTime.now().microsecondsSinceEpoch}-$entropy';
    _direction = HeadTurnDirection.values[_nextRandomInt(2)];
    final colors = <ChallengeScreenColor>[
      ChallengeScreenColor.red,
      ChallengeScreenColor.green,
      ChallengeScreenColor.blue,
    ];
    _colorSequence = purpose == ScanPurpose.attendance
        ? List.unmodifiable([colors[_nextRandomInt(colors.length)]])
        : const [];
  }

  bool _validMediaPipe(MediaPipeObservation? observation) =>
      observation != null &&
      observation.sessionId == _sessionId &&
      observation.timestampMs > _lastMediaPipeTimestamp &&
      observation.resultTimestampMs == observation.timestampMs &&
      observation.hasCompleteLivenessSignals;

  bool _continuous(MediaPipeObservation observation) {
    final previous = _previousMediaPipe;
    if (previous == null) return true;
    final dx = observation.centerX! - previous.centerX!;
    final dy = observation.centerY! - previous.centerY!;
    final displacement = math.sqrt(dx * dx + dy * dy);
    final widthChange =
        (observation.faceWidth! - previous.faceWidth!).abs() /
        previous.faceWidth!;
    return displacement <= SecureLivenessRules.maximumCenterDisplacement &&
        widthChange <= SecureLivenessRules.maximumWidthChangeFraction;
  }

  bool _acceptMediaPipe(MediaPipeObservation? observation) {
    if (!_validMediaPipe(observation)) {
      _resetActiveProgress('Detailed liveness landmarks unavailable');
      return false;
    }
    if (!_continuous(observation!)) {
      _resetActiveProgress('Face continuity changed; start again');
      _previousMediaPipe = observation;
      return false;
    }
    _previousMediaPipe = observation;
    _lastMediaPipeTimestamp = observation.timestampMs;
    return true;
  }

  void _advanceQuality(MediaPipeObservation observation) {
    _qualityFrames++;
    _guidance = 'Hold still while quality stabilizes';
    if (_qualityFrames < CaptureQualityRules.requiredStableFrames) return;
    _illuminationBaseline = null;
    _centerYawBaseline = observation.yawDegrees!;
    _headTurnDiagnostic = _headDiagnosticFor(observation.yawDegrees!);
    _stage = SecureLivenessStage.headTurn;
    _guidance = _headGuidance();
  }

  void _advanceHeadTurn(MediaPipeObservation observation) {
    final yaw = observation.yawDegrees!;
    final baseline = _centerYawBaseline ??= yaw;
    final yawDelta = yaw - baseline;
    // On the upright, unmirrored front-camera feed, MediaPipe's positive
    // matrix yaw corresponds to the operator turning toward their left.
    final desired = switch (_direction) {
      HeadTurnDirection.left => yawDelta >= SecureLivenessRules.headTurnDegrees,
      HeadTurnDirection.right =>
        yawDelta <= -SecureLivenessRules.headTurnDegrees,
    };
    final opposite = switch (_direction) {
      HeadTurnDirection.left =>
        yawDelta <= -SecureLivenessRules.oppositeTurnDegrees,
      HeadTurnDirection.right =>
        yawDelta >= SecureLivenessRules.oppositeTurnDegrees,
    };
    if (opposite) {
      _headFrames = 0;
      _headTurnDiagnostic = _headDiagnosticFor(yaw);
      _guidance = 'Wrong direction; ${_headGuidance().toLowerCase()}';
      return;
    }
    _headFrames = desired ? _headFrames + 1 : 0;
    _headTurnDiagnostic = _headDiagnosticFor(yaw);
    _guidance = _headGuidance();
    if (_headFrames >= SecureLivenessRules.directionalFrames) {
      _stage = SecureLivenessStage.headReturn;
      _returnFrames = 0;
      _guidance = 'Turn detected — return your head to center';
    }
  }

  void _advanceHeadReturn(MediaPipeObservation observation) {
    final baseline = _centerYawBaseline ??= observation.yawDegrees!;
    _returnFrames =
        (observation.yawDegrees! - baseline).abs() <=
            SecureLivenessRules.centeredYawDegrees
        ? _returnFrames + 1
        : 0;
    _headTurnDiagnostic = _headDiagnosticFor(observation.yawDegrees!);
    _guidance = 'Return your head to center';
    if (_returnFrames >= SecureLivenessRules.centeredReturnFrames) {
      if (purpose == ScanPurpose.registration) {
        _livenessCompleted = true;
        _stage = SecureLivenessStage.captureStabilizing;
        _captureFrames = 0;
        _guidance = 'Liveness complete; hold still';
        return;
      }
      _stage = SecureLivenessStage.colorBaseline;
      _resetColorBaseline();
      _guidance = 'Colors will change slowly; keep looking at the screen';
    }
  }

  void _advanceColorBaseline(MediaPipeObservation observation, DateTime now) {
    if (observation.skinRegions.length <
        SecureLivenessRules.minimumColorBaselineRegions) {
      _resetColorBaseline();
      _guidance = 'Keep your forehead and cheeks visible';
      return;
    }
    for (final entry in observation.skinRegions.entries) {
      final sums = _colorBaselineSums.putIfAbsent(entry.key, () => [0, 0, 0]);
      sums[0] += entry.value.red;
      sums[1] += entry.value.green;
      sums[2] += entry.value.blue;
    }
    _colorBaselineCount++;
    _guidance = 'Preparing gentle color check';
    if (_colorBaselineCount < SecureLivenessRules.colorBaselineFrames) return;
    _colorBaseline = Map.unmodifiable(
      _colorBaselineSums.map(
        (name, sums) => MapEntry(
          name,
          SkinRegionColor(
            red: sums[0] / _colorBaselineCount,
            green: sums[1] / _colorBaselineCount,
            blue: sums[2] / _colorBaselineCount,
          ),
        ),
      ),
    );
    _stage = SecureLivenessStage.colorChallenge;
    _colorIndex = 0;
    _resetColorResponse();
    _colorShownAt = now;
    _guidance = _colorGuidance(_colorSequence.first);
  }

  void _advanceColorResponse(MediaPipeObservation observation, DateTime now) {
    if (now.difference(_colorShownAt!) <
        SecureLivenessRules.colorTransitionDelay) {
      _guidance = 'Hold still during the gentle color change';
      return;
    }
    final color = _colorSequence[_colorIndex];
    final assessment = _assessColorResponse(color, observation.skinRegions);
    _colorSampleFrames++;
    if (assessment.matches) _colorMatchingFrames++;
    final best = _bestColorAssessment;
    if (best == null || assessment.responseScore > best.responseScore) {
      _bestColorAssessment = assessment;
    }
    final bestAssessment = _bestColorAssessment!;
    _colorDiagnostic = ColorResponseDiagnostic(
      color: color,
      sampledFrames: _colorSampleFrames,
      sampleWindowFrames: SecureLivenessRules.colorSampleWindowFrames,
      matchingFrames: _colorMatchingFrames,
      requiredMatchingFrames: SecureLivenessRules.colorRequiredMatchingFrames,
      bestCoherentRegions: bestAssessment.coherentRegions,
      requiredCoherentRegions: SecureLivenessRules.colorRequiredCoherentRegions,
      bestTargetDelta: bestAssessment.requiredRegionTargetDelta,
      bestDominanceMargin: bestAssessment.requiredRegionDominanceMargin,
    );
    _guidance =
        'Sampling the ${color.name} response '
        '$_colorSampleFrames/${SecureLivenessRules.colorSampleWindowFrames}';
    if (_colorMatchingFrames <
        SecureLivenessRules.colorRequiredMatchingFrames) {
      if (_colorSampleFrames >= SecureLivenessRules.colorSampleWindowFrames) {
        _completionLock = true;
        _stage = SecureLivenessStage.failed;
        _guidance = 'Color response not detected; please try again';
      }
      return;
    }
    _colorIndex++;
    if (_colorIndex >= _colorSequence.length) {
      _livenessCompleted = true;
      _stage = SecureLivenessStage.captureStabilizing;
      _captureFrames = 0;
      _guidance = 'Liveness complete; hold still';
      return;
    }
    _resetColorResponse();
    _colorShownAt = now;
    _guidance = _colorGuidance(_colorSequence[_colorIndex]);
  }

  _ColorFrameAssessment _assessColorResponse(
    ChallengeScreenColor color,
    Map<String, SkinRegionColor> current,
  ) {
    final regions = <_ColorRegionAssessment>[];
    for (final entry in _colorBaseline.entries) {
      final observed = current[entry.key];
      if (observed == null) continue;
      final red = observed.red - entry.value.red;
      final green = observed.green - entry.value.green;
      final blue = observed.blue - entry.value.blue;
      final (targetDelta, competitorDelta) = switch (color) {
        ChallengeScreenColor.red => (red, math.max(green, blue)),
        ChallengeScreenColor.green => (green, math.max(red, blue)),
        ChallengeScreenColor.blue => (blue, math.max(red, green)),
        ChallengeScreenColor.white || ChallengeScreenColor.neutral => (
          double.negativeInfinity,
          double.infinity,
        ),
      };
      final dominanceMargin = targetDelta - competitorDelta;
      final responseScore = math.min(
        targetDelta / SecureLivenessRules.minimumColorDelta,
        dominanceMargin / SecureLivenessRules.colorDominanceMargin,
      );
      regions.add(
        _ColorRegionAssessment(
          targetDelta: targetDelta,
          dominanceMargin: dominanceMargin,
          responseScore: responseScore,
        ),
      );
    }
    regions.sort(
      (left, right) => right.responseScore.compareTo(left.responseScore),
    );
    final coherentRegions = regions
        .where((region) => region.responseScore >= 1)
        .length;
    final requiredIndex = SecureLivenessRules.colorRequiredCoherentRegions - 1;
    final requiredRegion = regions.length > requiredIndex
        ? regions[requiredIndex]
        : null;
    return _ColorFrameAssessment(
      coherentRegions: coherentRegions,
      responseScore: requiredRegion?.responseScore ?? double.negativeInfinity,
      requiredRegionTargetDelta: requiredRegion?.targetDelta,
      requiredRegionDominanceMargin: requiredRegion?.dominanceMargin,
    );
  }

  void _advanceCapture(MediaPipeObservation observation) {
    final baseline = _centerYawBaseline ?? observation.yawDegrees!;
    if ((observation.yawDegrees! - baseline).abs() >
        SecureLivenessRules.centeredYawDegrees) {
      _captureFrames = 0;
      _guidance = 'Center your head';
      return;
    }
    _captureFrames++;
    _guidance = purpose == ScanPurpose.registration
        ? 'Enrollment sample ${_completedCaptures + 1} of 3'
        : 'Capturing automatically';
    if (_captureFrames >= CameraFlowRules.requiredConsecutiveFrames) {
      _captureFrames = 0;
      _captureInFlight = true;
      _stage = SecureLivenessStage.processing;
      _guidance = 'Processing';
    }
  }

  bool get _usesActiveLivenessPosition =>
      _stage == SecureLivenessStage.headTurn ||
      _stage == SecureLivenessStage.headReturn ||
      _stage == SecureLivenessStage.colorBaseline ||
      _stage == SecureLivenessStage.colorChallenge;

  void _pauseForActivePosition(FaceObservation observation) {
    switch (_stage) {
      case SecureLivenessStage.headTurn:
        _headFrames = 0;
        break;
      case SecureLivenessStage.headReturn:
        _returnFrames = 0;
        break;
      case SecureLivenessStage.colorBaseline:
        _resetColorBaseline();
        break;
      case SecureLivenessStage.colorChallenge:
      case SecureLivenessStage.quality:
      case SecureLivenessStage.captureStabilizing:
      case SecureLivenessStage.captureCooldown:
      case SecureLivenessStage.processing:
      case SecureLivenessStage.completed:
      case SecureLivenessStage.timedOut:
      case SecureLivenessStage.failed:
        break;
    }
    _guidance =
        observation.faceWidthRatio! >
            CameraFlowRules.maximumActiveFaceWidthRatio
        ? 'Keep your full face inside the oval'
        : 'Keep your face within the oval';
  }

  void _pauseForActiveQuality(String guidance) {
    _guidance = '$guidance; current step paused';
  }

  void _pauseForProgressQuality(String guidance) {
    if (_livenessCompleted) {
      _captureFrames = 0;
      _guidance = '$guidance; capture paused';
      return;
    }
    _pauseForActiveQuality(guidance);
  }

  void _pauseForCapturePosition(FaceObservation observation) {
    _captureFrames = 0;
    _guidance = _positionGuidance(observation);
  }

  void _resetActiveProgress(String guidance) {
    if (purpose == ScanPurpose.registration && _completedCaptures > 0) {
      _completedCaptures = 0;
      _nextCaptureAt = null;
      _enrollmentResetToken++;
    }
    _stage = SecureLivenessStage.quality;
    _previousMediaPipe = null;
    _illuminationBaseline = null;
    _centerYawBaseline = null;
    _qualityFrames = 0;
    _headFrames = 0;
    _returnFrames = 0;
    _headTurnDiagnostic = null;
    _resetColorBaseline();
    _colorIndex = 0;
    _resetColorResponse();
    _colorShownAt = null;
    _captureFrames = 0;
    _livenessCompleted = false;
    _guidance = guidance;
  }

  void _resetColorBaseline() {
    _colorBaselineCount = 0;
    _colorBaselineSums.clear();
    _colorBaseline = const {};
  }

  void _resetColorResponse() {
    _colorSampleFrames = 0;
    _colorMatchingFrames = 0;
    _bestColorAssessment = null;
    _colorDiagnostic = null;
  }

  String _positionGuidance(FaceObservation observation) {
    if (observation.faceWidthRatio! < CameraFlowRules.minimumFaceWidthRatio) {
      return 'Move closer';
    }
    if (observation.faceWidthRatio! > CameraFlowRules.maximumFaceWidthRatio) {
      return 'Keep your full face inside the oval';
    }
    return 'Center your full face';
  }

  HeadTurnDiagnostic _headDiagnosticFor(double currentYaw) {
    final baseline = _centerYawBaseline ?? currentYaw;
    return HeadTurnDiagnostic(
      direction: _direction,
      baselineYaw: baseline,
      currentYaw: currentYaw,
      yawDelta: currentYaw - baseline,
      requiredYawDelta: SecureLivenessRules.headTurnDegrees,
      turnFrames: _headFrames,
      requiredTurnFrames: SecureLivenessRules.directionalFrames,
      returnFrames: _returnFrames,
      requiredReturnFrames: SecureLivenessRules.centeredReturnFrames,
    );
  }

  String _headGuidance() => switch (_direction) {
    HeadTurnDirection.left => 'Turn your head left',
    HeadTurnDirection.right => 'Turn your head right',
  };

  String _colorGuidance(ChallengeScreenColor color) =>
      'Hold still for the ${color.name} light';

  ChallengeScreenColor get _screenColor {
    if (_stage == SecureLivenessStage.quality &&
        _illuminationBaseline != null) {
      return ChallengeScreenColor.white;
    }
    if (_stage == SecureLivenessStage.colorChallenge &&
        _colorIndex < _colorSequence.length) {
      return _colorSequence[_colorIndex];
    }
    return ChallengeScreenColor.neutral;
  }

  SecureLivenessUpdate _update({bool captureRequested = false}) {
    final progress = switch (_stage) {
      SecureLivenessStage.quality =>
        _qualityFrames / CaptureQualityRules.requiredStableFrames,
      SecureLivenessStage.headTurn =>
        _headFrames / SecureLivenessRules.directionalFrames,
      SecureLivenessStage.headReturn =>
        _returnFrames / SecureLivenessRules.centeredReturnFrames,
      SecureLivenessStage.colorBaseline =>
        _colorBaselineCount / SecureLivenessRules.colorBaselineFrames,
      SecureLivenessStage.colorChallenge =>
        (_colorIndex +
                _colorSampleFrames /
                    SecureLivenessRules.colorSampleWindowFrames) /
            _colorSequence.length,
      SecureLivenessStage.captureStabilizing =>
        _captureFrames / CameraFlowRules.requiredConsecutiveFrames,
      SecureLivenessStage.captureCooldown => 0,
      SecureLivenessStage.processing ||
      SecureLivenessStage.completed ||
      SecureLivenessStage.timedOut ||
      SecureLivenessStage.failed => 1,
    };
    final screenColor = _screenColor;
    final lowLightIllumination =
        _stage == SecureLivenessStage.quality && _illuminationBaseline != null;
    final colorIllumination =
        _stage == SecureLivenessStage.colorBaseline ||
        _stage == SecureLivenessStage.colorChallenge;
    return SecureLivenessUpdate(
      captureRequested: captureRequested,
      guidance: _guidance,
      progress: progress.clamp(0.0, 1.0).toDouble(),
      screenColor: screenColor,
      raiseWindowBrightness:
          screenColor != ChallengeScreenColor.neutral || colorIllumination,
      lowLightIllumination: lowLightIllumination,
      showPhotosensitivityWarning:
          _stage == SecureLivenessStage.colorBaseline ||
          _stage == SecureLivenessStage.colorChallenge,
      colorDiagnostic: _colorDiagnostic,
      headTurnDiagnostic: _headTurnDiagnostic,
    );
  }
}

class _ColorRegionAssessment {
  const _ColorRegionAssessment({
    required this.targetDelta,
    required this.dominanceMargin,
    required this.responseScore,
  });

  final double targetDelta;
  final double dominanceMargin;
  final double responseScore;
}

class _ColorFrameAssessment {
  const _ColorFrameAssessment({
    required this.coherentRegions,
    required this.responseScore,
    required this.requiredRegionTargetDelta,
    required this.requiredRegionDominanceMargin,
  });

  final int coherentRegions;
  final double responseScore;
  final double? requiredRegionTargetDelta;
  final double? requiredRegionDominanceMargin;

  bool get matches =>
      coherentRegions >= SecureLivenessRules.colorRequiredCoherentRegions;
}
