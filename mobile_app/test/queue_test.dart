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

AttendanceAttempt attempt(
  String id, {
  String driverId = 'driver',
  String assignmentId = 'assignment',
  String routeStopId = 'stop-1',
  String siteId = 'site-1',
}) => AttendanceAttempt(
  clientAttemptId: id,
  driverId: driverId,
  siteId: siteId,
  assignmentId: assignmentId,
  routeStopId: routeStopId,
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
      expect(await queue.enqueue(attempt('same-id')), isTrue);
      expect(await queue.enqueue(attempt('same-id')), isFalse);
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

  test(
    'duplicate offline submission is blocked by assignment and stop',
    () async {
      final storage = MemoryStorage();
      final queue = AttendanceQueue(storage);

      expect(await queue.enqueue(attempt('first-id')), isTrue);
      expect(await queue.enqueue(attempt('different-id')), isFalse);
      expect(storage.queue, hasLength(1));
      expect(
        await queue.hasPendingSubmission(
          driverId: 'driver',
          assignmentId: 'assignment',
          routeStopId: 'stop-1',
          siteId: 'site-1',
        ),
        isTrue,
      );
    },
  );

  test('concurrent duplicate submissions are serialized', () async {
    final storage = MemoryStorage();
    final queue = AttendanceQueue(storage);

    final results = await Future.wait([
      queue.enqueue(attempt('concurrent-a')),
      queue.enqueue(attempt('concurrent-b')),
    ]);
    expect(results.where((saved) => saved), hasLength(1));
    expect(storage.queue, hasLength(1));
  });

  test('restart preserves the submission lock and exact identities', () async {
    final storage = MemoryStorage();
    await AttendanceQueue(storage).enqueue(attempt('persisted-id'));

    final restarted = AttendanceQueue(storage);
    expect(await restarted.enqueue(attempt('new-id')), isFalse);
    final persisted = storage.queue.single;
    expect(persisted.driverId, 'driver');
    expect(persisted.assignmentId, 'assignment');
    expect(persisted.routeStopId, 'stop-1');
    expect(persisted.siteId, 'site-1');
  });

  test(
    'different Field Personnel and ordered stops remain independent',
    () async {
      final storage = MemoryStorage();
      final queue = AttendanceQueue(storage);

      expect(await queue.enqueue(attempt('first')), isTrue);
      expect(
        await queue.enqueue(
          attempt('second', routeStopId: 'stop-2', siteId: 'site-2'),
        ),
        isTrue,
      );
      expect(
        await queue.enqueue(attempt('third', driverId: 'driver-2')),
        isTrue,
      );
      expect(storage.queue, hasLength(3));
    },
  );

  test('pending attendance advances cached multi-site assignment', () {
    const assignment = DriverAssignment(
      id: 'assignment',
      status: 'assigned',
      locationName: 'Site 1',
      address: null,
      scheduledAt: null,
      site: AuthorizedSite(
        id: 'site-1',
        latitude: 1,
        longitude: 1,
        radiusMeters: 100,
      ),
      currentStopId: 'stop-1',
      totalStopCount: 2,
      stops: [
        DriverRouteStop(
          id: 'stop-1',
          order: 1,
          state: 'current',
          locationName: 'Site 1',
          address: null,
          site: AuthorizedSite(
            id: 'site-1',
            latitude: 1,
            longitude: 1,
            radiusMeters: 100,
          ),
        ),
        DriverRouteStop(
          id: 'stop-2',
          order: 2,
          state: 'upcoming',
          locationName: 'Site 2',
          address: null,
          site: AuthorizedSite(
            id: 'site-2',
            latitude: 2,
            longitude: 2,
            radiusMeters: 100,
          ),
        ),
      ],
    );

    final updated = assignment.applyPendingAttendance([
      attempt('queued'),
    ], driverId: 'driver');
    expect(updated.routeStops.map((stop) => stop.state), [
      'pending_sync',
      'current',
    ]);
    expect(updated.currentStopId, 'stop-2');
    expect(updated.site.id, 'site-2');
    expect(updated.locationName, 'Site 2');
  });
}
