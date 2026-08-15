import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

class PreviewCoverGeometry {
  const PreviewCoverGeometry({
    required this.sourceSize,
    required this.coverSize,
    required this.cropOffset,
  });

  final Size sourceSize;
  final Size coverSize;
  final Offset cropOffset;
}

PreviewCoverGeometry calculatePreviewCover({
  required Size viewport,
  required Size cameraPreviewSize,
  required int rotationDegrees,
}) {
  if (viewport.width <= 0 ||
      viewport.height <= 0 ||
      cameraPreviewSize.width <= 0 ||
      cameraPreviewSize.height <= 0) {
    throw ArgumentError('Preview and viewport dimensions must be positive.');
  }
  final normalizedRotation = rotationDegrees % 360;
  if (![0, 90, 180, 270].contains(normalizedRotation)) {
    throw ArgumentError('Camera rotation must be a right angle.');
  }
  final swapAxes = normalizedRotation == 90 || normalizedRotation == 270;
  final source = swapAxes
      ? Size(cameraPreviewSize.height, cameraPreviewSize.width)
      : cameraPreviewSize;
  final scale =
      (viewport.width / source.width) > (viewport.height / source.height)
      ? viewport.width / source.width
      : viewport.height / source.height;
  final cover = Size(source.width * scale, source.height * scale);
  return PreviewCoverGeometry(
    sourceSize: source,
    coverSize: cover,
    cropOffset: Offset(
      (cover.width - viewport.width) / 2,
      (cover.height - viewport.height) / 2,
    ),
  );
}

class CameraOrientation {
  const CameraOrientation({
    required this.sensorOrientation,
    required this.rotationDegrees,
    required this.previewMirrored,
    required this.analysisMirrored,
  });

  final int sensorOrientation;
  final int rotationDegrees;
  final bool previewMirrored;
  final bool analysisMirrored;

  factory CameraOrientation.resolve({
    required CameraDescription camera,
    required DeviceOrientation deviceOrientation,
  }) {
    final deviceDegrees = switch (deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    final front = camera.lensDirection == CameraLensDirection.front;
    final rotation = front
        ? (camera.sensorOrientation + deviceDegrees) % 360
        : (camera.sensorOrientation - deviceDegrees + 360) % 360;
    if (![0, 90, 180, 270].contains(rotation)) {
      throw StateError('Unsupported camera sensor orientation.');
    }
    return CameraOrientation(
      sensorOrientation: camera.sensorOrientation,
      rotationDegrees: rotation,
      previewMirrored: front,
      analysisMirrored: false,
    );
  }
}

class UprightBgrFrame {
  const UprightBgrFrame({
    required this.width,
    required this.height,
    required this.bytes,
  });

  final int width;
  final int height;
  final Uint8List bytes;
}

UprightBgrFrame orientBgrFrame({
  required Uint8List source,
  required int width,
  required int height,
  required int rotationDegrees,
}) {
  if (width <= 0 || height <= 0 || source.length != width * height * 3) {
    throw ArgumentError('BGR frame dimensions do not match its byte length.');
  }
  final rotation = rotationDegrees % 360;
  if (![0, 90, 180, 270].contains(rotation)) {
    throw ArgumentError('Frame rotation must be a right angle.');
  }
  final swapsAxes = rotation == 90 || rotation == 270;
  final targetWidth = swapsAxes ? height : width;
  final targetHeight = swapsAxes ? width : height;
  if (rotation == 0) {
    return UprightBgrFrame(
      width: width,
      height: height,
      bytes: Uint8List.fromList(source),
    );
  }
  final target = Uint8List(source.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final (targetX, targetY) = switch (rotation) {
        90 => (height - 1 - y, x),
        180 => (width - 1 - x, height - 1 - y),
        270 => (y, width - 1 - x),
        _ => (x, y),
      };
      final sourceIndex = (y * width + x) * 3;
      final targetIndex = (targetY * targetWidth + targetX) * 3;
      target.setRange(targetIndex, targetIndex + 3, source, sourceIndex);
    }
  }
  return UprightBgrFrame(
    width: targetWidth,
    height: targetHeight,
    bytes: target,
  );
}
