import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/device_identity.dart';
import 'package:offline_trucking_attendance/src/queue.dart';

class FakeDeviceIdentity implements DeviceIdentityProvider {
  final signedChallenges = <String>[];

  @override
  Future<DeviceIdentity> getIdentity() async => const DeviceIdentity(
    publicKey: 'public-key',
    fingerprint: 'fingerprint',
    label: 'Test Android phone',
  );

  @override
  Future<String> sign(String challenge) async {
    signedChallenges.add(challenge);
    return 'signature-for-$challenge';
  }

  @override
  Future<void> clear() async {}
}

void main() {
  test(
    'driver client follows activation, profile, refresh, and logout contracts',
    () async {
      final requests = <Map<String, Object?>>[];
      final deviceIdentity = FakeDeviceIdentity();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final raw = await utf8.decoder.bind(request).join();
        requests.add({
          'path': request.uri.path,
          'authorization': request.headers.value(
            HttpHeaders.authorizationHeader,
          ),
          'body': raw.isEmpty ? null : jsonDecode(raw),
        });
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/api/driver/auth/device-challenge') {
          final purpose =
              (requests.last['body'] as Map<String, dynamic>)['purpose'];
          request.response.write(
            jsonEncode({'challenge': 'challenge-$purpose'}),
          );
        } else if (request.uri.path == '/api/driver/me') {
          request.response.write(
            jsonEncode({
              'driver': {
                'id': 'driver-id',
                'employee_id': 'DRV-001',
                'full_name': 'Demo Driver',
                'device_authorization': {'status': 'ready'},
                'face_reregistration_request': {'status': 'approved'},
                'current_assignment': {
                  'id': 'assignment-id',
                  'status': 'assigned',
                  'route_name': 'North AM-01',
                  'scheduled_at': '2026-08-11T09:00:00+08:00',
                  'completed_stop_count': 1,
                  'total_stop_count': 2,
                  'current_stop_id': 'stop-2',
                  'location': {
                    'id': 'site-2',
                    'name': 'South Distribution Hub',
                    'address': 'Makati City',
                    'latitude': 14.5,
                    'longitude': 121.0,
                    'radius_meters': 100,
                  },
                  'stops': [
                    {
                      'id': 'stop-1',
                      'order': 1,
                      'state': 'completed',
                      'completed_at': '2026-08-11T09:30:00+08:00',
                      'location': {
                        'id': 'site-1',
                        'name': 'North Distribution Hub',
                        'address': 'Quezon City',
                        'latitude': 14.6,
                        'longitude': 121.1,
                        'radius_meters': 150,
                      },
                    },
                    {
                      'id': 'stop-2',
                      'order': 2,
                      'state': 'current',
                      'completed_at': null,
                      'location': {
                        'id': 'site-2',
                        'name': 'South Distribution Hub',
                        'address': 'Makati City',
                        'latitude': 14.5,
                        'longitude': 121.0,
                        'radius_meters': 100,
                      },
                    },
                  ],
                },
              },
            }),
          );
        } else if (request.uri.path ==
            '/api/driver/device-replacement-request') {
          request.response.write(
            jsonEncode({
              'request': {'status': 'pending'},
            }),
          );
        } else if (request.uri.path == '/api/driver/auth/logout' ||
            request.uri.path == '/api/driver/device/enrollment-complete') {
          request.response.write(jsonEncode({'ok': true}));
        } else {
          request.response.write(
            jsonEncode({
              'access_token': 'access-token',
              'refresh_token': 'refresh-token',
              'driver': {
                'id': 'driver-id',
                'employee_id': 'DRV-001',
                'full_name': 'Demo Driver',
              },
            }),
          );
        }
        await request.response.close();
      });

      final client = DriverBackendClient(
        Uri.parse('http://${server.address.host}:${server.port}'),
        deviceIdentity: deviceIdentity,
      );
      final activated = await client.activate(
        'DRV-001',
        'ABC123',
        'long-password',
      );
      expect(activated.driver.fullName, 'Demo Driver');
      final profile = await client.profile(activated.tokens.accessToken);
      expect(profile.assignedSite?.id, 'site-2');
      expect(profile.assignment?.locationName, 'South Distribution Hub');
      expect(profile.assignment?.routeName, 'North AM-01');
      expect(profile.assignment?.completedStopCount, 1);
      expect(profile.assignment?.totalStopCount, 2);
      expect(profile.faceReregistrationStatus, 'approved');
      expect(profile.assignment?.routeStops.map((stop) => stop.state), [
        'completed',
        'current',
      ]);
      final restored = DriverAssignment.fromJson(profile.assignment!.toJson());
      expect(restored.site.radiusMeters, 100);
      expect(restored.routeStops.map((stop) => stop.state), [
        'completed',
        'current',
      ]);
      await client.completeDeviceEnrollment(activated.tokens.accessToken);
      expect(
        await client.requestDeviceReplacement('DRV-001', 'long-password'),
        'pending',
      );
      expect(profile.deviceAuthorizationStatus, 'ready');
      final refreshed = await client.refresh(
        activated.tokens.refreshToken,
        'DRV-001',
      );
      await client.logout(refreshed.tokens.accessToken);

      expect(requests.map((item) => item['path']), [
        '/api/driver/auth/device-challenge',
        '/api/driver/activate',
        '/api/driver/me',
        '/api/driver/device/enrollment-complete',
        '/api/driver/auth/device-challenge',
        '/api/driver/device-replacement-request',
        '/api/driver/auth/device-challenge',
        '/api/driver/auth/refresh',
        '/api/driver/auth/logout',
      ]);
      expect(
        (requests[1]['body'] as Map<String, dynamic>)['activation_code'],
        'ABC123',
      );
      expect(
        (requests[1]['body'] as Map<String, dynamic>)['device_public_key'],
        'public-key',
      );
      expect(requests[2]['authorization'], 'Bearer access-token');
      expect(requests[3]['authorization'], 'Bearer access-token');
      expect(requests.last['authorization'], 'Bearer access-token');
      expect(deviceIdentity.signedChallenges, [
        'challenge-activate',
        'challenge-replace',
        'challenge-refresh',
      ]);
    },
  );

  test('driver client retains safe backend error detail', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'detail': 'Invalid login credentials'}),
      );
      await request.response.close();
    });
    final client = DriverBackendClient(
      Uri.parse('http://${server.address.host}:${server.port}'),
      deviceIdentity: FakeDeviceIdentity(),
    );

    await expectLater(
      client.login('DRV-001', 'wrong-password'),
      throwsA(
        isA<BackendRequestException>()
            .having((error) => error.statusCode, 'status', 401)
            .having(
              (error) => error.message,
              'message',
              'Invalid login credentials',
            ),
      ),
    );
  });
}
