import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/domain.dart';

List<double> embedding(int index) {
  final values = List<double>.filled(embeddingLength, 0);
  values[index] = 1;
  return values;
}

void main() {
  test('successful attempt A cannot make attempt B begin verified', () {
    final verification = AttendanceFaceVerification()
      ..begin(driverId: 'driver-a', enrollmentTemplate: embedding(0));

    expect(verification.verified, isFalse);
    expect(verification.latestScore, isNull);
    verification.compare(driverId: 'driver-a', probe: embedding(0));
    verification.compare(driverId: 'driver-a', probe: embedding(0));
    verification.compare(driverId: 'driver-a', probe: embedding(0));
    expect(verification.verified, isTrue);
    verification.begin(driverId: 'driver-a', enrollmentTemplate: embedding(0));

    expect(verification.verified, isFalse);
    expect(verification.comparisonCount, 0);
    expect(verification.latestScore, isNull);
  });

  test('three deterministic valid comparisons are required', () {
    final verification = AttendanceFaceVerification()
      ..begin(driverId: 'driver-a', enrollmentTemplate: embedding(0));

    expect(
      verification.compare(driverId: 'driver-a', probe: embedding(0)).status,
      AttendanceFaceComparisonStatus.pending,
    );
    expect(
      verification.compare(driverId: 'driver-a', probe: embedding(0)).status,
      AttendanceFaceComparisonStatus.pending,
    );
    final accepted = verification.compare(
      driverId: 'driver-a',
      probe: embedding(0),
    );

    expect(accepted.status, AttendanceFaceComparisonStatus.accepted);
    expect(accepted.score, 1);
    expect(accepted.aggregatedProbe, embedding(0));
    expect(verification.verified, isTrue);
  });

  test('failed comparison cannot reuse earlier successful samples', () {
    final verification = AttendanceFaceVerification()
      ..begin(driverId: 'driver-a', enrollmentTemplate: embedding(0));
    verification.compare(driverId: 'driver-a', probe: embedding(0));
    verification.compare(driverId: 'driver-a', probe: embedding(0));

    final rejected = verification.compare(
      driverId: 'driver-a',
      probe: embedding(1),
    );

    expect(rejected.status, AttendanceFaceComparisonStatus.rejected);
    expect(verification.verified, isFalse);
    expect(verification.comparisonCount, 0);
    expect(verification.latestScore, isNull);
  });

  test('Driver A verification state cannot survive into Driver B', () {
    final verification = AttendanceFaceVerification()
      ..begin(driverId: 'driver-a', enrollmentTemplate: embedding(0));
    verification.compare(driverId: 'driver-a', probe: embedding(0));
    verification.compare(driverId: 'driver-a', probe: embedding(0));
    verification.compare(driverId: 'driver-a', probe: embedding(0));
    expect(verification.verified, isTrue);
    verification.begin(driverId: 'driver-b', enrollmentTemplate: embedding(1));

    expect(verification.verified, isFalse);
    expect(verification.comparisonCount, 0);
    expect(
      () => verification.compare(driverId: 'driver-a', probe: embedding(0)),
      throwsStateError,
    );
    expect(verification.comparisonCount, 0);
  });
}
