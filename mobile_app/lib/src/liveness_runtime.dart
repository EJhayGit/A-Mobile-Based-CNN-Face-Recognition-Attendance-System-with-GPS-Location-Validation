import 'package:flutter/services.dart';

import 'camera_frame.dart';

class SkinRegionColor {
  const SkinRegionColor({
    required this.red,
    required this.green,
    required this.blue,
  });

  final double red;
  final double green;
  final double blue;

  static SkinRegionColor? fromObject(Object? value) {
    if (value is! Map) return null;
    final red = value['red'];
    final green = value['green'];
    final blue = value['blue'];
    if (red is! num || green is! num || blue is! num) return null;
    final redValue = red.toDouble();
    final greenValue = green.toDouble();
    final blueValue = blue.toDouble();
    if (!redValue.isFinite ||
        !greenValue.isFinite ||
        !blueValue.isFinite ||
        redValue < 0 ||
        redValue > 255 ||
        greenValue < 0 ||
        greenValue > 255 ||
        blueValue < 0 ||
        blueValue > 255) {
      return null;
    }
    return SkinRegionColor(red: redValue, green: greenValue, blue: blueValue);
  }
}

class MediaPipeObservation {
  const MediaPipeObservation({
    required this.sessionId,
    required this.timestampMs,
    required this.resultTimestampMs,
    required this.inferenceMs,
    required this.faceCount,
    required this.landmarkCount,
    required this.transformationAvailable,
    required this.yawDegrees,
    required this.centerX,
    required this.centerY,
    required this.faceWidth,
    required this.skinRegions,
  });

  final String sessionId;
  final int timestampMs;
  final int resultTimestampMs;
  final int inferenceMs;
  final int faceCount;
  final int landmarkCount;
  final bool transformationAvailable;
  final double? yawDegrees;
  final double? centerX;
  final double? centerY;
  final double? faceWidth;
  final Map<String, SkinRegionColor> skinRegions;

  bool get hasCompleteLivenessSignals {
    bool inRange(double? value, double minimum, double maximum) =>
        value != null && value.isFinite && value >= minimum && value <= maximum;

    return faceCount == 1 &&
        landmarkCount >= 478 &&
        transformationAvailable &&
        inRange(yawDegrees, -180, 180) &&
        inRange(centerX, 0, 1) &&
        inRange(centerY, 0, 1) &&
        inRange(faceWidth, double.minPositive, 1.5);
  }

  factory MediaPipeObservation.fromMap(Map<Object?, Object?> map) {
    T requireValue<T>(String key) {
      final value = map[key];
      if (value is! T) throw StateError('Missing MediaPipe result field: $key');
      return value;
    }

    double? optionalDouble(String key) => switch (map[key]) {
      final num value when value.toDouble().isFinite => value.toDouble(),
      _ => null,
    };

    final rawRegions = map['skinRegions'];
    final regions = <String, SkinRegionColor>{};
    if (rawRegions is Map) {
      for (final entry in rawRegions.entries) {
        final color = SkinRegionColor.fromObject(entry.value);
        if (entry.key is String && color != null) {
          regions[entry.key! as String] = color;
        }
      }
    }
    return MediaPipeObservation(
      sessionId: requireValue<String>('sessionId'),
      timestampMs: requireValue<num>('timestampMs').toInt(),
      resultTimestampMs: requireValue<num>('resultTimestampMs').toInt(),
      inferenceMs: requireValue<num>('inferenceMs').toInt(),
      faceCount: requireValue<num>('faceCount').toInt(),
      landmarkCount: requireValue<num>('landmarkCount').toInt(),
      transformationAvailable: requireValue<bool>('transformationAvailable'),
      yawDegrees: optionalDouble('yawDegrees'),
      centerX: optionalDouble('centerX'),
      centerY: optionalDouble('centerY'),
      faceWidth: optionalDouble('faceWidth'),
      skinRegions: Map.unmodifiable(regions),
    );
  }
}

class LivenessRuntime {
  LivenessRuntime({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('thesis.liveness/runtime');

  final MethodChannel _channel;
  int _lastTimestampMs = -1;

  Future<void> startSession(String sessionId) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'startSession',
      {'sessionId': sessionId},
    );
    if (result == null || result['sessionId'] != sessionId) {
      throw StateError('The native liveness session did not initialize.');
    }
    _lastTimestampMs = -1;
  }

  Future<MediaPipeObservation> analyzeFrame({
    required String sessionId,
    required int timestampMs,
    required ConvertedCameraFrame frame,
  }) async {
    if (timestampMs <= _lastTimestampMs) {
      throw StateError('Liveness timestamps must increase monotonically.');
    }
    _lastTimestampMs = timestampMs;
    final upright = frame.upright;
    final result = await _channel
        .invokeMapMethod<Object?, Object?>('analyzeFrame', {
          'sessionId': sessionId,
          'timestampMs': timestampMs,
          'width': upright.width,
          'height': upright.height,
          'bgrBytes': Uint8List.fromList(upright.bytes),
        });
    if (result == null) {
      throw StateError('The native liveness runtime returned no result.');
    }
    final observation = MediaPipeObservation.fromMap(result);
    if (observation.sessionId != sessionId ||
        observation.timestampMs != timestampMs ||
        observation.resultTimestampMs != timestampMs) {
      throw StateError('The native liveness runtime returned a stale result.');
    }
    return observation;
  }

  Future<void> closeSession() async {
    _lastTimestampMs = -1;
    await _channel.invokeMethod<void>('closeSession');
  }
}

class WindowBrightnessRuntime {
  WindowBrightnessRuntime({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('thesis.liveness/brightness');

  final MethodChannel _channel;

  Future<void> setForIllumination({double level = 1}) => _channel
      .invokeMethod<void>('setBrightness', {'level': level.clamp(0.0, 1.0)});

  Future<void> restore() => _channel.invokeMethod<void>('restoreBrightness');
}
