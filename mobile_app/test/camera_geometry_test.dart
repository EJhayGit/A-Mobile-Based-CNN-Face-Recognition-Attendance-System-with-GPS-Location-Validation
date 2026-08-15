import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/camera_geometry.dart';

void main() {
  test('portrait cover preserves aspect ratio and crops outer edges', () {
    final geometry = calculatePreviewCover(
      viewport: const Size(1080, 2400),
      cameraPreviewSize: const Size(1280, 720),
      rotationDegrees: 90,
    );
    expect(geometry.sourceSize, const Size(720, 1280));
    expect(
      geometry.coverSize.width / geometry.coverSize.height,
      closeTo(720 / 1280, 1e-12),
    );
    expect(geometry.coverSize.width, 1350);
    expect(geometry.coverSize.height, 2400);
    expect(geometry.cropOffset.dx, 135);
    expect(geometry.cropOffset.dy, 0);
  });

  test('front preview is mirrored while analysis remains unmirrored', () {
    const camera = CameraDescription(
      name: 'front',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 270,
    );
    final orientation = CameraOrientation.resolve(
      camera: camera,
      deviceOrientation: DeviceOrientation.portraitUp,
    );
    expect(orientation.rotationDegrees, 270);
    expect(orientation.previewMirrored, isTrue);
    expect(orientation.analysisMirrored, isFalse);
  });

  test('back camera portrait rotation follows the sensor', () {
    const camera = CameraDescription(
      name: 'back',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    );
    final orientation = CameraOrientation.resolve(
      camera: camera,
      deviceOrientation: DeviceOrientation.portraitUp,
    );
    expect(orientation.rotationDegrees, 90);
    expect(orientation.previewMirrored, isFalse);
    expect(orientation.analysisMirrored, isFalse);
  });

  test('BGR orientation rotates pixels without mirroring', () {
    final source = Uint8List.fromList([
      1,
      0,
      0,
      2,
      0,
      0,
      3,
      0,
      0,
      4,
      0,
      0,
      5,
      0,
      0,
      6,
      0,
      0,
    ]);
    final upright = orientBgrFrame(
      source: source,
      width: 3,
      height: 2,
      rotationDegrees: 90,
    );
    expect(upright.width, 2);
    expect(upright.height, 3);
    expect(
      [
        for (var index = 0; index < upright.bytes.length; index += 3)
          upright.bytes[index],
      ],
      [4, 1, 5, 2, 6, 3],
    );
  });

  test('upright frame owns bytes before asynchronous processing', () {
    final source = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
    final upright = orientBgrFrame(
      source: source,
      width: 2,
      height: 1,
      rotationDegrees: 0,
    );
    source.fillRange(0, source.length, 99);
    expect(upright.bytes, [1, 2, 3, 4, 5, 6]);
  });
}
