import 'dart:typed_data';

import 'package:camera/camera.dart';

import 'camera_geometry.dart';

class CameraFrameConversionException implements Exception {
  const CameraFrameConversionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ConvertedCameraFrame {
  const ConvertedCameraFrame({
    required this.rawWidth,
    required this.rawHeight,
    required this.upright,
    required this.sourceFormat,
    required this.channelOrder,
  });

  final int rawWidth;
  final int rawHeight;
  final UprightBgrFrame upright;
  final String sourceFormat;
  final String channelOrder;
}

class CameraFrameConverter {
  const CameraFrameConverter();

  ConvertedCameraFrame convert(
    CameraImage image, {
    required int rotationDegrees,
  }) {
    if (image.format.group != ImageFormatGroup.yuv420 ||
        image.planes.length != 3) {
      throw CameraFrameConversionException(
        'Expected a three-plane YUV420 Android camera frame.',
      );
    }
    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0) {
      throw const CameraFrameConversionException(
        'Camera frame dimensions are invalid.',
      );
    }
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;
    if (uvPixelStride <= 0 || (vPlane.bytesPerPixel ?? 1) != uvPixelStride) {
      throw const CameraFrameConversionException(
        'Camera chroma-plane pixel strides are unsupported.',
      );
    }
    final bgr = Uint8List(width * height * 3);
    for (var y = 0; y < height; y++) {
      final yRow = y * yPlane.bytesPerRow;
      final uvRow = (y >> 1) * uPlane.bytesPerRow;
      final vRow = (y >> 1) * vPlane.bytesPerRow;
      for (var x = 0; x < width; x++) {
        final yIndex = yRow + x;
        final uvOffset = (x >> 1) * uvPixelStride;
        final uIndex = uvRow + uvOffset;
        final vIndex = vRow + uvOffset;
        if (yIndex >= yPlane.bytes.length ||
            uIndex >= uPlane.bytes.length ||
            vIndex >= vPlane.bytes.length) {
          throw const CameraFrameConversionException(
            'Camera plane metadata exceeds the supplied buffers.',
          );
        }
        final yValue = yPlane.bytes[yIndex];
        final uValue = uPlane.bytes[uIndex];
        final vValue = vPlane.bytes[vIndex];
        final c = yValue - 16;
        final d = uValue - 128;
        final e = vValue - 128;
        final red = _clip((298 * c + 409 * e + 128) >> 8);
        final green = _clip((298 * c - 100 * d - 208 * e + 128) >> 8);
        final blue = _clip((298 * c + 516 * d + 128) >> 8);
        final index = (y * width + x) * 3;
        bgr[index] = blue;
        bgr[index + 1] = green;
        bgr[index + 2] = red;
      }
    }
    return ConvertedCameraFrame(
      rawWidth: width,
      rawHeight: height,
      upright: orientBgrFrame(
        source: bgr,
        width: width,
        height: height,
        rotationDegrees: rotationDegrees,
      ),
      sourceFormat: image.format.group.name,
      channelOrder: 'BGR',
    );
  }

  static int _clip(int value) {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return value;
  }
}
