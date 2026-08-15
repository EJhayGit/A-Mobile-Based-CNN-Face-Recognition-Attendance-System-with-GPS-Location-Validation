import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/queue.dart';

void main() {
  test(
    'driver client follows activation, profile, refresh, and logout contracts',
    () async {
      final requests = <Map<String, Object?>>[];
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
        if (request.uri.path == '/api/driver/me') {
          request.response.write(
            jsonEncode({
              'driver': {
                'id': 'driver-id',
                'employee_id': 'DRV-001',
                'full_name': 'Demo Driver',
                'current_assignment': {
                  'id': 'assignment-id',
                  'status': 'assigned',
                  'scheduled_at': '2026-08-11T09:00:00+08:00',
                  'location': {
                    'id': 'site-id',
                    'name': 'North Distribution Hub',
                    'address': 'Quezon City',
                    'latitude': 14.5,
                    'longitude': 121.0,
                    'radius_meters': 100,
                  },
                },
              },
            }),
          );
        } else if (request.uri.path == '/api/driver/auth/logout') {
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
      );
      final activated = await client.activate(
        'DRV-001',
        'ABC123',
        'long-password',
      );
      expect(activated.driver.fullName, 'Demo Driver');
      final profile = await client.profile(activated.tokens.accessToken);
      expect(profile.assignedSite?.id, 'site-id');
      expect(profile.assignment?.locationName, 'North Distribution Hub');
      expect(
        DriverAssignment.fromJson(
          profile.assignment!.toJson(),
        ).site.radiusMeters,
        100,
      );
      final refreshed = await client.refresh(activated.tokens.refreshToken);
      await client.logout(refreshed.tokens.accessToken);

      expect(requests.map((item) => item['path']), [
        '/api/driver/activate',
        '/api/driver/me',
        '/api/driver/auth/refresh',
        '/api/driver/auth/logout',
      ]);
      expect(
        (requests.first['body'] as Map<String, dynamic>)['activation_code'],
        'ABC123',
      );
      expect(requests[1]['authorization'], 'Bearer access-token');
      expect(requests.last['authorization'], 'Bearer access-token');
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
