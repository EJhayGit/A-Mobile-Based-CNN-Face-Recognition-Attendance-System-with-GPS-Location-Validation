import 'package:flutter/services.dart';

class DestinationMapLauncher {
  const DestinationMapLauncher();

  static const _channel = MethodChannel('thesis.navigation/runtime');

  Future<void> open({
    required double latitude,
    required double longitude,
    required String label,
  }) async {
    await _channel.invokeMethod<void>('openDirections', {
      'latitude': latitude,
      'longitude': longitude,
      'label': label,
    });
  }
}
