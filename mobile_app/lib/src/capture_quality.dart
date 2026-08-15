import 'dart:math' as math;

import 'camera_flow.dart';
import 'camera_geometry.dart';

enum CaptureQualityState {
  acceptable,
  marginal,
  tooLow,
  glare,
  blurry,
  exposureStabilizing,
}

class CaptureQualityRules {
  const CaptureQualityRules._();

  // Initial engineering constants. They remain subject to the one authorized
  // bona fide-only calibration cycle and may not be tuned on attack attempts.
  static const minimumMeanLuminance = 48.0;
  static const preferredMeanLuminance = 72.0;
  static const maximumMeanLuminance = 220.0;
  static const underexposedPixelLevel = 35.0;
  static const overexposedPixelLevel = 245.0;
  static const maximumUnderexposedProportion = 0.55;
  static const preferredUnderexposedProportion = 0.30;
  static const maximumOverexposedProportion = 0.18;
  static const minimumContrast = 22.0;
  static const minimumFocusVariance = 55.0;
  static const stableBrightnessDelta = 14.0;
  static const requiredStableFrames = 3;
  static const requiredIlluminationImprovement = 8.0;
}

class CaptureQuality {
  const CaptureQuality({
    required this.state,
    required this.meanLuminance,
    required this.underexposedProportion,
    required this.overexposedProportion,
    required this.contrast,
    required this.focusVariance,
    required this.brightnessDelta,
  });

  final CaptureQualityState state;
  final double meanLuminance;
  final double underexposedProportion;
  final double overexposedProportion;
  final double contrast;
  final double focusVariance;
  final double? brightnessDelta;

  bool get acceptable => state == CaptureQualityState.acceptable;
  bool get needsIllumination =>
      state == CaptureQualityState.tooLow ||
      (state == CaptureQualityState.marginal &&
          meanLuminance < CaptureQualityRules.preferredMeanLuminance);

  String get guidance => switch (state) {
    CaptureQualityState.acceptable => 'Lighting is acceptable',
    CaptureQualityState.marginal => 'Move toward better light',
    CaptureQualityState.tooLow => 'Low light: screen illumination starting',
    CaptureQualityState.glare => 'Reduce glare on your face',
    CaptureQualityState.blurry => 'Hold the phone and your face still',
    CaptureQualityState.exposureStabilizing => 'Exposure is stabilizing',
  };
}

class CaptureQualityAnalyzer {
  double? _previousMean;

  void reset() => _previousMean = null;

  CaptureQuality analyze(UprightBgrFrame frame, FaceObservation observation) {
    if (!observation.hasProductionFace ||
        observation.boxX == null ||
        observation.boxY == null ||
        observation.boxWidth == null ||
        observation.boxHeight == null) {
      throw StateError('Capture quality requires one validated YuNet face.');
    }
    final left = (observation.boxX! * frame.width).floor().clamp(
      0,
      frame.width - 1,
    );
    final top = (observation.boxY! * frame.height).floor().clamp(
      0,
      frame.height - 1,
    );
    final right = ((observation.boxX! + observation.boxWidth!) * frame.width)
        .ceil()
        .clamp(left + 1, frame.width);
    final bottom = ((observation.boxY! + observation.boxHeight!) * frame.height)
        .ceil()
        .clamp(top + 1, frame.height);

    var count = 0;
    var sum = 0.0;
    var sumSquares = 0.0;
    var underexposed = 0;
    var overexposed = 0;
    var laplacianCount = 0;
    var laplacianSum = 0.0;
    var laplacianSquares = 0.0;
    const step = 2;
    for (var y = top + step; y < bottom - step; y += step) {
      for (var x = left + step; x < right - step; x += step) {
        final luminance = _luminance(frame, x, y);
        count++;
        sum += luminance;
        sumSquares += luminance * luminance;
        if (luminance <= CaptureQualityRules.underexposedPixelLevel) {
          underexposed++;
        }
        if (luminance >= CaptureQualityRules.overexposedPixelLevel) {
          overexposed++;
        }
        final laplacian =
            _luminance(frame, x - step, y) +
            _luminance(frame, x + step, y) +
            _luminance(frame, x, y - step) +
            _luminance(frame, x, y + step) -
            4 * luminance;
        laplacianCount++;
        laplacianSum += laplacian;
        laplacianSquares += laplacian * laplacian;
      }
    }
    if (count == 0 || laplacianCount == 0) {
      throw StateError(
        'The YuNet face region is too small for quality checks.',
      );
    }
    final mean = sum / count;
    final variance = math.max(0, sumSquares / count - mean * mean);
    final laplacianMean = laplacianSum / laplacianCount;
    final focusVariance = math
        .max(
          0,
          laplacianSquares / laplacianCount - laplacianMean * laplacianMean,
        )
        .toDouble();
    final brightnessDelta = _previousMean == null
        ? null
        : (mean - _previousMean!).abs();
    _previousMean = mean;
    final underProportion = underexposed / count;
    final overProportion = overexposed / count;
    final contrast = math.sqrt(variance);
    final state = _classify(
      mean: mean,
      underexposed: underProportion,
      overexposed: overProportion,
      contrast: contrast,
      focusVariance: focusVariance,
      brightnessDelta: brightnessDelta,
    );
    return CaptureQuality(
      state: state,
      meanLuminance: mean,
      underexposedProportion: underProportion,
      overexposedProportion: overProportion,
      contrast: contrast,
      focusVariance: focusVariance,
      brightnessDelta: brightnessDelta,
    );
  }

  CaptureQualityState _classify({
    required double mean,
    required double underexposed,
    required double overexposed,
    required double contrast,
    required double focusVariance,
    required double? brightnessDelta,
  }) {
    if (mean < CaptureQualityRules.minimumMeanLuminance ||
        underexposed > CaptureQualityRules.maximumUnderexposedProportion) {
      return CaptureQualityState.tooLow;
    }
    if (mean > CaptureQualityRules.maximumMeanLuminance ||
        overexposed > CaptureQualityRules.maximumOverexposedProportion) {
      return CaptureQualityState.glare;
    }
    if (focusVariance < CaptureQualityRules.minimumFocusVariance) {
      return CaptureQualityState.blurry;
    }
    if (brightnessDelta == null ||
        brightnessDelta > CaptureQualityRules.stableBrightnessDelta) {
      return CaptureQualityState.exposureStabilizing;
    }
    if (mean < CaptureQualityRules.preferredMeanLuminance ||
        underexposed > CaptureQualityRules.preferredUnderexposedProportion ||
        contrast < CaptureQualityRules.minimumContrast) {
      return CaptureQualityState.marginal;
    }
    return CaptureQualityState.acceptable;
  }

  double _luminance(UprightBgrFrame frame, int x, int y) {
    final index = (y * frame.width + x) * 3;
    final blue = frame.bytes[index];
    final green = frame.bytes[index + 1];
    final red = frame.bytes[index + 2];
    return 0.114 * blue + 0.587 * green + 0.299 * red;
  }
}
