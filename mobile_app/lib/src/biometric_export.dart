import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'biometric_testing.dart';

abstract interface class BiometricDataShare {
  Future<void> share(Iterable<BiometricTrialRecord> records);
  Future<void> clearExports();
}

class AndroidBiometricDataShare implements BiometricDataShare {
  const AndroidBiometricDataShare({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('thesis.biometric_testing/share');

  final MethodChannel _channel;

  Future<Directory> _exportDirectory() async => Directory(
    '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}biometric_exports',
  );

  @override
  Future<void> share(Iterable<BiometricTrialRecord> records) async {
    final directory = await _exportDirectory();
    await directory.create(recursive: true);
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    final file = File(
      '${directory.path}${Platform.pathSeparator}agila-biometric-tests-$stamp.csv',
    );
    await file.writeAsString(biometricRecordsToCsv(records), flush: true);
    await _channel.invokeMethod<void>('shareCsv', {'path': file.path});
  }

  @override
  Future<void> clearExports() async {
    final directory = await _exportDirectory();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
