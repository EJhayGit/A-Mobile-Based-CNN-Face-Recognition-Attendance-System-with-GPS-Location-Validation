import 'package:flutter/services.dart';

class NetworkStatusRuntime {
  NetworkStatusRuntime({EventChannel? channel})
    : _channel = channel ?? const EventChannel('thesis.connectivity/events');

  final EventChannel _channel;

  Stream<bool> get changes => _channel
      .receiveBroadcastStream()
      .map((value) => value == true)
      .distinct();
}
