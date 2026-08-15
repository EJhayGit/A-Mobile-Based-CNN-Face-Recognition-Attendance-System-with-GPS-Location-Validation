import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/domain.dart';
import 'package:offline_trucking_attendance/src/queue.dart';
import 'package:offline_trucking_attendance/src/storage.dart';

class MemoryStorage implements AttendanceStorage {
  List<AttendanceAttempt> queue = [];

  @override
  Future<List<AttendanceAttempt>> readQueue() async => [...queue];

  @override
  Future<void> writeQueue(List<AttendanceAttempt> queue) async {
    this.queue = [...queue];
  }
}

class RecordingGateway implements AttendanceGateway {
  final uploaded = <String>[];

  @override
  Future<void> upload(AttendanceAttempt attempt) async {
    uploaded.add(attempt.clientAttemptId);
  }
}

class DelayedGateway implements AttendanceGateway {
  final uploaded = <String>[];
  final release = Completer<void>();

  @override
  Future<void> upload(AttendanceAttempt attempt) async {
    uploaded.add(attempt.clientAttemptId);
    await release.future;
  }
}

class FailingGateway implements AttendanceGateway {
  @override
  Future<void> upload(AttendanceAttempt attempt) async {
    throw const BackendRequestException(503, 'Offline');
  }
}

AttendanceAttempt attempt(String id) => AttendanceAttempt(
  clientAttemptId: id,
  driverId: 'driver',
  siteId: 'site',
  capturedAtUtc: DateTime.utc(2026, 7, 30),
  latitude: 0,
  longitude: 0,
  gpsAccuracyMeters: 5,
  distanceMeters: 0,
  faceScore: 1,
);

void main() {
  test(
    'queue is idempotent and removes successfully synchronized records',
    () async {
      final storage = MemoryStorage();
      final queue = AttendanceQueue(storage);
      await queue.enqueue(attempt('same-id'));
      await queue.enqueue(attempt('same-id'));
      expect(storage.queue, hasLength(1));

      final gateway = RecordingGateway();
      expect(await queue.synchronize(gateway), 1);
      expect(gateway.uploaded, ['same-id']);
      expect(storage.queue, isEmpty);
    },
  );

  test('overlapping automatic sync triggers share one upload pass', () async {
    final storage = MemoryStorage()..queue = [attempt('queued-id')];
    final queue = AttendanceQueue(storage);
    final gateway = DelayedGateway();

    final first = queue.synchronize(gateway);
    final second = queue.synchronize(gateway);
    await Future<void>.delayed(Duration.zero);
    expect(gateway.uploaded, ['queued-id']);
    gateway.release.complete();

    expect(await first, 1);
    expect(await second, 1);
    expect(storage.queue, isEmpty);
  });

  test('offline synchronization leaves the attendance safely queued', () async {
    final storage = MemoryStorage()..queue = [attempt('offline-id')];
    final queue = AttendanceQueue(storage);

    expect(await queue.synchronize(FailingGateway()), 0);
    expect(storage.queue.map((item) => item.clientAttemptId), ['offline-id']);

    final online = RecordingGateway();
    expect(await queue.synchronize(online), 1);
    expect(online.uploaded, ['offline-id']);
    expect(storage.queue, isEmpty);
  });
}
