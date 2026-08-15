import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/domain.dart';

List<double> axisEmbedding(int index, {double sign = 1}) {
  final values = List<double>.filled(embeddingLength, 0);
  values[index] = sign;
  return values;
}

void main() {
  const site = AuthorizedSite(
    id: 'depot',
    latitude: 14.5995,
    longitude: 120.9842,
    radiusMeters: 100,
  );

  test('enrollment mean is L2 normalized', () {
    final template = enrollmentTemplate([axisEmbedding(0), axisEmbedding(0)]);
    expect(template.length, embeddingLength);
    expect(template[0], closeTo(1, 1e-12));
  });

  test('locked threshold accepts a matching face inside GPS boundary', () {
    final decision = evaluateAttendance(
      enrollment: axisEmbedding(0),
      probe: axisEmbedding(0),
      site: site,
      latitude: site.latitude,
      longitude: site.longitude,
      accuracyMeters: 5,
    );
    expect(decision.accepted, isTrue);
    expect(decision.reason, 'accepted');
  });

  test('locked threshold rejects non-match', () {
    final decision = evaluateAttendance(
      enrollment: axisEmbedding(0),
      probe: axisEmbedding(1),
      site: site,
      latitude: site.latitude,
      longitude: site.longitude,
      accuracyMeters: 5,
    );
    expect(decision.accepted, isFalse);
    expect(decision.reason, 'face_non_match');
  });

  test('GPS boundary rejects otherwise matching face', () {
    final decision = evaluateAttendance(
      enrollment: axisEmbedding(0),
      probe: axisEmbedding(0),
      site: site,
      latitude: site.latitude + 0.01,
      longitude: site.longitude,
      accuracyMeters: 5,
    );
    expect(decision.accepted, isFalse);
    expect(decision.reason, 'outside_authorized_site');
  });

  test('manager radius accepts in-boundary reading with accuracy over 50m', () {
    const managerSite = AuthorizedSite(
      id: 'wide-test-site',
      latitude: 14.5995,
      longitude: 120.9842,
      radiusMeters: 250,
    );
    final decision = evaluateAttendance(
      enrollment: axisEmbedding(0),
      probe: axisEmbedding(0),
      site: managerSite,
      latitude: managerSite.latitude + 0.001,
      longitude: managerSite.longitude,
      accuracyMeters: 120,
    );

    expect(decision.distanceMeters, lessThan(managerSite.radiusMeters));
    expect(decision.accepted, isTrue);
    expect(decision.reason, 'accepted');
  });

  test('invalid GPS readings remain rejected', () {
    for (final accuracy in [double.nan, double.infinity, -1.0]) {
      final decision = evaluateAttendance(
        enrollment: axisEmbedding(0),
        probe: axisEmbedding(0),
        site: site,
        latitude: site.latitude,
        longitude: site.longitude,
        accuracyMeters: accuracy,
      );
      expect(decision.accepted, isFalse);
      expect(decision.reason, 'gps_accuracy_rejected');
    }

    final invalidCoordinates = evaluateAttendance(
      enrollment: axisEmbedding(0),
      probe: axisEmbedding(0),
      site: site,
      latitude: double.nan,
      longitude: site.longitude,
      accuracyMeters: 5,
    );
    expect(invalidCoordinates.accepted, isFalse);
    expect(invalidCoordinates.reason, 'gps_accuracy_rejected');
  });

  test('assigned site parses the manager-controlled radius', () {
    final assigned = assignedSiteFromDriverResponse({
      'driver': {
        'current_assignment': {
          'location': {
            'id': 'location-1',
            'latitude': 14.5995,
            'longitude': 120.9842,
            'radius_meters': 375,
          },
        },
      },
    });
    expect(assigned?.id, 'location-1');
    expect(assigned?.radiusMeters, 375);
  });

  test('missing assignment produces no authorized site', () {
    expect(
      assignedSiteFromDriverResponse({
        'driver': {'current_assignment': null},
      }),
      isNull,
    );
  });
}
