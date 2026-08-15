import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'domain.dart';

class EmbeddingRuntime {
  EmbeddingRuntime({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('thesis.embedding/runtime');

  final MethodChannel _channel;

  Future<String> load() async {
    final provider = await _channel.invokeMethod<String>('loadModel');
    if (provider == null || provider.isEmpty) {
      throw StateError(
        'The Android runtime did not report an execution provider.',
      );
    }
    return provider;
  }

  Future<List<double>> inferAlignedImage(String path) async {
    final values = await _channel.invokeListMethod<double>(
      'inferAlignedImage',
      {'path': path},
    );
    if (values == null) {
      throw StateError('The Android runtime did not return an embedding.');
    }
    final normalized = normalizeEmbedding(values);
    final norm = math.sqrt(
      normalized.fold<double>(0, (sum, value) => sum + value * value),
    );
    if ((norm - 1).abs() > 1e-3) {
      throw StateError('The embedding is not L2 normalized.');
    }
    return normalized;
  }
}
