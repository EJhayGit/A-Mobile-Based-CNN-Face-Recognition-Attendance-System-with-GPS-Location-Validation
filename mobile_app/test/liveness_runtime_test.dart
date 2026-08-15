import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/camera_frame.dart';
import 'package:offline_trucking_attendance/src/camera_geometry.dart';
import 'package:offline_trucking_attendance/src/liveness_runtime.dart';

final frame = ConvertedCameraFrame(
  rawWidth: 2,
  rawHeight: 1,
  upright: UprightBgrFrame(
    width: 2,
    height: 1,
    bytes: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
  ),
  sourceFormat: 'yuv420',
  channelOrder: 'BGR',
);

Map<String, Object?> nativeObservation(String sessionId, int timestamp) => {
  'sessionId': sessionId,
  'timestampMs': timestamp,
  'resultTimestampMs': timestamp,
  'inferenceMs': 12,
  'faceCount': 1,
  'landmarkCount': 478,
  'transformationAvailable': true,
  'yawDegrees': 2.0,
  'centerX': 0.5,
  'centerY': 0.5,
  'faceWidth': 0.4,
  'skinRegions': {
    'forehead': {'red': 100.0, 'green': 101.0, 'blue': 102.0},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'runtime sends owned BGR bytes and rejects non-increasing timestamps',
    () async {
      const channel = MethodChannel('test.liveness/runtime');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'startSession') {
              return {'sessionId': 'session-1'};
            }
            if (call.method == 'analyzeFrame') {
              final arguments = call.arguments! as Map<Object?, Object?>;
              expect(arguments['width'], 2);
              expect(arguments['height'], 1);
              expect(arguments['bgrBytes'], isA<Uint8List>());
              expect(arguments['bgrBytes'], orderedEquals([1, 2, 3, 4, 5, 6]));
              return nativeObservation(
                arguments['sessionId']! as String,
                arguments['timestampMs']! as int,
              );
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final runtime = LivenessRuntime(channel: channel);
      await runtime.startSession('session-1');
      final result = await runtime.analyzeFrame(
        sessionId: 'session-1',
        timestampMs: 10,
        frame: frame,
      );
      expect(result.hasCompleteLivenessSignals, isTrue);
      expect(result.skinRegions['forehead']!.green, 101);
      await expectLater(
        runtime.analyzeFrame(
          sessionId: 'session-1',
          timestampMs: 10,
          frame: frame,
        ),
        throwsStateError,
      );
      expect(
        calls.where((call) => call.method == 'analyzeFrame'),
        hasLength(1),
      );
    },
  );

  test('runtime rejects stale native session and result timestamp', () async {
    const channel = MethodChannel('test.liveness/stale');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'startSession') return {'sessionId': 'current'};
          if (call.method == 'analyzeFrame') {
            return nativeObservation('stale', 8);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final runtime = LivenessRuntime(channel: channel);
    await runtime.startSession('current');
    await expectLater(
      runtime.analyzeFrame(sessionId: 'current', timestampMs: 8, frame: frame),
      throwsStateError,
    );
  });

  test('non-finite native liveness values fail closed', () {
    final observation = nativeObservation('session', 1)
      ..['yawDegrees'] = double.nan;
    final parsed = MediaPipeObservation.fromMap(observation);
    expect(parsed.hasCompleteLivenessSignals, isFalse);

    expect(
      SkinRegionColor.fromObject({
        'red': double.infinity,
        'green': 100.0,
        'blue': 100.0,
      }),
      isNull,
    );
  });

  test(
    'window brightness bridge exposes explicit set and restore calls',
    () async {
      const channel = MethodChannel('test.liveness/brightness');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final runtime = WindowBrightnessRuntime(channel: channel);
      await runtime.setForIllumination();
      await runtime.restore();
      expect(calls.map((call) => call.method), [
        'setBrightness',
        'restoreBrightness',
      ]);
      expect((calls.first.arguments as Map<Object?, Object?>)['level'], 1.0);
    },
  );
}
