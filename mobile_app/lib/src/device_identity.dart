import 'package:flutter/services.dart';

class DeviceIdentity {
  const DeviceIdentity({
    required this.publicKey,
    required this.fingerprint,
    required this.label,
  });

  final String publicKey;
  final String fingerprint;
  final String label;
}

abstract interface class DeviceIdentityProvider {
  Future<DeviceIdentity> getIdentity();
  Future<String> sign(String challenge);
  Future<void> clear();
}

class AndroidDeviceIdentity implements DeviceIdentityProvider {
  const AndroidDeviceIdentity();

  static const _channel = MethodChannel('thesis.device_identity/runtime');

  @override
  Future<DeviceIdentity> getIdentity() async {
    final raw = await _channel.invokeMapMethod<String, String>('getIdentity');
    final publicKey = raw?['publicKey'];
    final fingerprint = raw?['fingerprint'];
    final label = raw?['label'];
    if (publicKey == null || fingerprint == null || label == null) {
      throw const FormatException('Device authorization is unavailable.');
    }
    return DeviceIdentity(
      publicKey: publicKey,
      fingerprint: fingerprint,
      label: label,
    );
  }

  @override
  Future<String> sign(String challenge) async {
    final signature = await _channel.invokeMethod<String>('sign', {
      'challenge': challenge,
    });
    if (signature == null || signature.isEmpty) {
      throw const FormatException('Device authorization is unavailable.');
    }
    return signature;
  }

  @override
  Future<void> clear() => _channel.invokeMethod<void>('clear');
}
