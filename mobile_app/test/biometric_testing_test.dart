import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/biometric_export.dart';
import 'package:offline_trucking_attendance/src/biometric_testing.dart';
import 'package:offline_trucking_attendance/src/biometric_testing_screen.dart';
import 'package:offline_trucking_attendance/src/domain.dart';
import 'package:offline_trucking_attendance/src/storage.dart';

List<double> embedding(int index) {
  final values = List<double>.filled(embeddingLength, 0);
  values[index] = 1;
  return values;
}

BiometricTrialRecord completeRecord() => BiometricTrialRecord(
  trialId: 'bio-test-1',
  enrolledId: 'P01',
  probeId: 'P01',
  groundTruth: 'genuine',
  condition: BiometricLightingCondition.indoorNormal,
  scores: const [0.8, 0.7, 0.6],
  aggregateScore: 0.75,
  currentThreshold: lockedCosineThreshold,
  productionAccepted: true,
  failureReason: null,
  appVersion: biometricTestingAppVersion,
  modelVersion: biometricTestingModelVersion,
  timestampUtc: DateTime.utc(2026, 8, 20),
  deviceLabel: 'DEVICE-1',
);

class MemoryBiometricStore implements BiometricRecordStore {
  final records = <BiometricTrialRecord>[];

  @override
  Future<void> appendBiometricRecord(BiometricTrialRecord record) async {
    records.add(record);
  }

  @override
  Future<void> clearBiometricRecords() async => records.clear();

  @override
  Future<List<BiometricTrialRecord>> readBiometricRecords() async =>
      List.of(records);
}

class MemoryShare implements BiometricDataShare {
  List<BiometricTrialRecord>? shared;
  bool cleared = false;

  @override
  Future<void> clearExports() async => cleared = true;

  @override
  Future<void> share(Iterable<BiometricTrialRecord> records) async {
    shared = List.of(records);
  }
}

void main() {
  test('pseudonymous IDs determine genuine and impostor ground truth', () {
    expect(
      BiometricTrialSetup(
        enrolledId: ' p01 ',
        probeId: 'P01',
        condition: BiometricLightingCondition.indoorNormal,
      ).groundTruth,
      'genuine',
    );
    expect(
      BiometricTrialSetup(
        enrolledId: 'P01',
        probeId: 'P02',
        condition: BiometricLightingCondition.dim,
      ).groundTruth,
      'impostor',
    );
  });

  test('research collector records all three scores and aggregate', () {
    final collector = BiometricTrialCollector(
      setup: BiometricTrialSetup(
        enrolledId: 'P01',
        probeId: 'P01',
        condition: BiometricLightingCondition.bright,
      ),
      enrollment: embedding(0),
      trialId: 'bio-fixed',
      startedAt: DateTime.utc(2026, 8, 20),
    );
    collector.addProbe(embedding(0));
    collector.addProbe(embedding(0));
    collector.addProbe(embedding(0));

    final record = collector.buildRecord();
    expect(record.scores, [1, 1, 1]);
    expect(record.aggregateScore, 1);
    expect(record.productionAccepted, isTrue);
    expect(record.currentThreshold, 0.35);
  });

  test('incomplete research trials retain scores and exclusion reason', () {
    final collector = BiometricTrialCollector(
      setup: BiometricTrialSetup(
        enrolledId: 'P01',
        probeId: 'P02',
        condition: BiometricLightingCondition.dim,
      ),
      enrollment: embedding(0),
      trialId: 'bio-incomplete',
    )..addProbe(embedding(1));

    final record = collector.buildRecord(failureReason: 'user_cancelled');
    expect(record.scores, [0]);
    expect(record.aggregateScore, isNull);
    expect(record.productionAccepted, isNull);
    expect(record.failureReason, 'user_cancelled');
  });

  test('research result requires every sample and aggregate to pass', () {
    final collector = BiometricTrialCollector(
      setup: BiometricTrialSetup(
        enrolledId: 'P01',
        probeId: 'P02',
        condition: BiometricLightingCondition.indoorNormal,
      ),
      enrollment: embedding(0),
    );
    collector.addProbe(embedding(0));
    collector.addProbe(embedding(1));
    collector.addProbe(embedding(0));

    final record = collector.buildRecord();
    expect(record.aggregateScore, greaterThan(lockedCosineThreshold));
    expect(record.productionAccepted, isFalse);
  });

  test('CSV contains only de-identified metadata and numerical results', () {
    final record = completeRecord();
    final csv = biometricRecordsToCsv([record]);
    final exportedHeader = csv.split('\r\n').first.split(',');

    expect(exportedHeader, biometricCsvColumns);
    expect(csv, contains('0.80000000000000004'));
    expect(
      biometricRecordsToCsv([
        BiometricTrialRecord(
          trialId: record.trialId,
          enrolledId: record.enrolledId,
          probeId: record.probeId,
          groundTruth: record.groundTruth,
          condition: record.condition,
          scores: const [-0.1, 0.2, 0.3],
          aggregateScore: 0.1,
          currentThreshold: record.currentThreshold,
          productionAccepted: false,
          failureReason: null,
          appVersion: record.appVersion,
          modelVersion: record.modelVersion,
          timestampUtc: record.timestampUtc,
        ),
      ]),
      contains('-0.10000000000000001'),
    );
    for (final prohibited in [
      'embedding',
      'image',
      'latitude',
      'longitude',
      'driver_id',
      'attendance',
      'jwt',
      'email',
    ]) {
      expect(exportedHeader, isNot(contains(prohibited)));
      expect(record.toJson().keys, isNot(contains(prohibited)));
    }
  });

  test('research records remain separate from attendance queue', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = SecureAttendanceStorage();

    await storage.appendBiometricRecord(completeRecord());

    expect(await storage.readBiometricRecords(), hasLength(1));
    expect(await storage.readQueue(), isEmpty);
    await storage.clearBiometricRecords();
    expect(await storage.readBiometricRecords(), isEmpty);
  });

  testWidgets('testing screen records, exports, and confirms clearing', (
    tester,
  ) async {
    final store = MemoryBiometricStore();
    final share = MemoryShare();
    await tester.pumpWidget(
      MaterialApp(
        home: BiometricTestingScreen(
          store: store,
          dataShare: share,
          onRunTrial: (_) async => completeRecord(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('biometric_enrolled_id')),
      'P01',
    );
    await tester.enterText(find.byKey(const Key('biometric_probe_id')), 'P01');
    await tester.tap(find.byKey(const Key('run_biometric_trial')));
    await tester.pumpAndSettle();
    expect(store.records, hasLength(1));

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export_biometric_data')));
    await tester.pumpAndSettle();
    expect(share.shared, hasLength(1));

    await tester.tap(find.byKey(const Key('clear_biometric_data')));
    await tester.pumpAndSettle();
    expect(find.text('Clear biometric test data?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm_clear_biometric_data')));
    await tester.pumpAndSettle();
    expect(store.records, isEmpty);
    expect(share.cleared, isTrue);
  });
}
