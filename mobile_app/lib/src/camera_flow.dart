enum ScanPurpose { registration, attendance }

class CameraFlowRules {
  const CameraFlowRules._();

  static const productionThreshold = 0.9;
  static const debugReportingThreshold = 0.3;
  static const minimumFrameInterval = Duration(milliseconds: 200);
  static const requiredConsecutiveFrames = 3;
  static const enrollmentCaptureSeparation = Duration(milliseconds: 900);
  static const minimumFaceWidthRatio = 0.34;
  static const maximumFaceWidthRatio = 0.82;
  static const minimumCenterX = 0.20;
  static const maximumCenterX = 0.80;
  static const minimumCenterY = 0.16;
  static const maximumCenterY = 0.84;
  static const minimumActiveFaceWidthRatio = 0.20;
  static const maximumActiveFaceWidthRatio = 0.92;
  static const minimumActiveCenterX = 0.05;
  static const maximumActiveCenterX = 0.95;
  static const minimumActiveCenterY = 0.08;
  static const maximumActiveCenterY = 0.92;
}

class FaceObservation {
  const FaceObservation({
    required this.productionFaceCount,
    required this.productionConfidence,
    required this.debugCandidateCount,
    required this.highestDebugConfidence,
    required this.geometryValid,
    required this.centerX,
    required this.centerY,
    required this.faceWidthRatio,
    required this.noseOffsetEyeDistances,
    required this.rejectionReason,
    this.boxX,
    this.boxY,
    this.boxWidth,
    this.boxHeight,
  });

  const FaceObservation.none({
    this.debugCandidateCount = 0,
    this.highestDebugConfidence,
    this.rejectionReason = 'no_face',
  }) : productionFaceCount = 0,
       productionConfidence = null,
       geometryValid = false,
       centerX = null,
       centerY = null,
       faceWidthRatio = null,
       noseOffsetEyeDistances = null,
       boxX = null,
       boxY = null,
       boxWidth = null,
       boxHeight = null;

  final int productionFaceCount;
  final double? productionConfidence;
  final int debugCandidateCount;
  final double? highestDebugConfidence;
  final bool geometryValid;
  final double? centerX;
  final double? centerY;
  final double? faceWidthRatio;

  // Report-only legacy geometry. It may support positioning diagnostics but is
  // never consumed by the security-authorizing liveness controller.
  final double? noseOffsetEyeDistances;
  final String rejectionReason;
  final double? boxX;
  final double? boxY;
  final double? boxWidth;
  final double? boxHeight;

  bool get hasProductionFace =>
      productionFaceCount == 1 &&
      (productionConfidence ?? -1) >= CameraFlowRules.productionThreshold &&
      geometryValid;

  bool get inTargetRegion =>
      hasProductionFace &&
      faceWidthRatio! >= CameraFlowRules.minimumFaceWidthRatio &&
      faceWidthRatio! <= CameraFlowRules.maximumFaceWidthRatio &&
      centerX! >= CameraFlowRules.minimumCenterX &&
      centerX! <= CameraFlowRules.maximumCenterX &&
      centerY! >= CameraFlowRules.minimumCenterY &&
      centerY! <= CameraFlowRules.maximumCenterY;

  // A completed fresh challenge still requires strict positioning before
  // capture. This wider range only prevents ordinary head-turn displacement
  // from restarting an already active liveness stage.
  bool get inActiveLivenessRegion =>
      hasProductionFace &&
      faceWidthRatio! >= CameraFlowRules.minimumActiveFaceWidthRatio &&
      faceWidthRatio! <= CameraFlowRules.maximumActiveFaceWidthRatio &&
      centerX! >= CameraFlowRules.minimumActiveCenterX &&
      centerX! <= CameraFlowRules.maximumActiveCenterX &&
      centerY! >= CameraFlowRules.minimumActiveCenterY &&
      centerY! <= CameraFlowRules.maximumActiveCenterY;
}

class FrameProcessingGate {
  FrameProcessingGate({
    this.minimumInterval = CameraFlowRules.minimumFrameInterval,
  });

  final Duration minimumInterval;
  bool _locked = false;
  DateTime? _lastStart;

  bool get locked => _locked;

  bool tryAcquire(DateTime now) {
    if (_locked) return false;
    final lastStart = _lastStart;
    if (lastStart != null && now.difference(lastStart) < minimumInterval) {
      return false;
    }
    _locked = true;
    _lastStart = now;
    return true;
  }

  Future<bool> runIfAcquired(
    DateTime now,
    Future<void> Function() operation,
  ) async {
    if (!tryAcquire(now)) return false;
    try {
      await operation();
      return true;
    } finally {
      if (_locked) release();
    }
  }

  void release() {
    if (!_locked) throw StateError('Frame-processing gate is not locked.');
    _locked = false;
  }

  void reset() {
    _locked = false;
    _lastStart = null;
  }
}
