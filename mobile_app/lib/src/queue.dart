import 'dart:convert';
import 'dart:io';

import 'domain.dart';
import 'storage.dart';

abstract interface class AttendanceGateway {
  Future<void> upload(AttendanceAttempt attempt);
}

class BackendTokens {
  const BackendTokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

class DriverIdentity {
  const DriverIdentity({
    required this.id,
    required this.employeeId,
    required this.fullName,
  });

  final String id;
  final String employeeId;
  final String fullName;

  factory DriverIdentity.fromJson(Map<String, dynamic> json) => DriverIdentity(
    id: json['id'] as String,
    employeeId: json['employee_id'] as String,
    fullName: json['full_name'] as String,
  );
}

class DriverSession {
  const DriverSession({required this.tokens, required this.driver});

  final BackendTokens tokens;
  final DriverIdentity driver;
}

class DriverProfile {
  const DriverProfile({required this.driver, required this.assignment});

  final DriverIdentity driver;
  final DriverAssignment? assignment;

  AuthorizedSite? get assignedSite =>
      assignment?.isActive == true ? assignment!.site : null;
}

class DriverAssignment {
  const DriverAssignment({
    required this.id,
    required this.status,
    required this.locationName,
    required this.address,
    required this.scheduledAt,
    required this.site,
  });

  final String id;
  final String status;
  final String locationName;
  final String? address;
  final DateTime? scheduledAt;
  final AuthorizedSite site;

  bool get isActive => status == 'assigned' || status == 'in_progress';

  factory DriverAssignment.fromJson(Map<String, dynamic> json) {
    final location = json['location'];
    if (location is! Map<String, dynamic>) {
      throw const FormatException('Assigned location is invalid.');
    }
    final scheduledAt = json['scheduled_at'];
    return DriverAssignment(
      id: json['id'] as String,
      status: json['status'] as String,
      locationName: location['name'] as String,
      address: location['address'] as String?,
      scheduledAt: scheduledAt is String
          ? DateTime.parse(scheduledAt).toLocal()
          : null,
      site: AuthorizedSite.fromJson(location),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'status': status,
    'scheduled_at': scheduledAt?.toUtc().toIso8601String(),
    'location': {...site.toJson(), 'name': locationName, 'address': address},
  };
}

class BackendRequestException implements Exception {
  const BackendRequestException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

class DriverBackendClient {
  DriverBackendClient(this.endpoint, {HttpClient? client})
    : _client = client ?? HttpClient();

  final Uri endpoint;
  final HttpClient _client;

  Future<Map<String, dynamic>> _readJson(HttpClientResponse response) async {
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'The server could not complete the request.';
      try {
        final payload = jsonDecode(body);
        if (payload is Map<String, dynamic> && payload['detail'] is String) {
          message = payload['detail'] as String;
        }
      } catch (_) {
        // Keep the safe generic message for non-JSON server responses.
      }
      throw BackendRequestException(response.statusCode, message);
    }
    if (body.isEmpty) return const {};
    return jsonDecode(body) as Map<String, dynamic>;
  }

  DriverSession _sessionFromPayload(Map<String, dynamic> payload) {
    final driver = payload['driver'];
    if (driver is! Map<String, dynamic>) {
      throw const FormatException('Driver response is missing.');
    }
    return DriverSession(
      tokens: BackendTokens(
        accessToken: payload['access_token'] as String,
        refreshToken: payload['refresh_token'] as String,
      ),
      driver: DriverIdentity.fromJson(driver),
    );
  }

  Future<DriverSession> activate(
    String employeeId,
    String activationCode,
    String password,
  ) async {
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/activate'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'employee_id': employeeId,
        'activation_code': activationCode,
        'password': password,
        'device_label': 'offline-attendance-android',
      }),
    );
    return _sessionFromPayload(await _readJson(await request.close()));
  }

  Future<DriverSession> login(String loginId, String password) async {
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/auth/login'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'login_id': loginId,
        'password': password,
        'device_label': 'offline-attendance-android',
      }),
    );
    return _sessionFromPayload(await _readJson(await request.close()));
  }

  Future<DriverSession> refresh(String refreshToken) async {
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/auth/refresh'),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'refresh_token': refreshToken}));
    return _sessionFromPayload(await _readJson(await request.close()));
  }

  Future<DriverProfile> profile(String accessToken) async {
    final request = await _client.getUrl(endpoint.resolve('/api/driver/me'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    final payload = await _readJson(await request.close());
    final driver = payload['driver'];
    if (driver is! Map<String, dynamic>) {
      throw const FormatException('Driver response is missing.');
    }
    final rawAssignment =
        driver['current_assignment'] ?? driver['recent_delivery'];
    final assignment = rawAssignment == null
        ? null
        : DriverAssignment.fromJson(rawAssignment as Map<String, dynamic>);
    if (assignment != null &&
        (assignment.site.radiusMeters < 10 ||
            assignment.site.radiusMeters > 5000)) {
      throw const FormatException('Assigned radius is invalid.');
    }
    return DriverProfile(
      driver: DriverIdentity.fromJson(driver),
      assignment: assignment,
    );
  }

  Future<void> logout(String accessToken) async {
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/auth/logout'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    await _readJson(await request.close());
  }

  Future<AuthorizedSite?> assignedSite(String accessToken) async {
    return (await profile(accessToken)).assignedSite;
  }
}

class HttpAttendanceGateway implements AttendanceGateway {
  HttpAttendanceGateway(this.endpoint, this.accessToken, {HttpClient? client})
    : _client = client ?? HttpClient();

  final Uri endpoint;
  final String accessToken;
  final HttpClient _client;

  @override
  Future<void> upload(AttendanceAttempt attempt) async {
    final request = await _client.postUrl(endpoint.resolve('/attendance/sync'));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    request.headers.set('Idempotency-Key', attempt.clientAttemptId);
    request.write(jsonEncode(attempt.toJson()));
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Attendance sync returned HTTP ${response.statusCode}.',
      );
    }
  }
}

class AttendanceQueue {
  AttendanceQueue(this.storage);

  final AttendanceStorage storage;
  Future<int>? _activeSynchronization;

  Future<void> enqueue(AttendanceAttempt attempt) async {
    final queue = await storage.readQueue();
    if (queue.any((item) => item.clientAttemptId == attempt.clientAttemptId)) {
      return;
    }
    await storage.writeQueue([...queue, attempt]);
  }

  Future<int> synchronize(AttendanceGateway gateway) {
    final active = _activeSynchronization;
    if (active != null) return active;
    final synchronization = _synchronize(gateway);
    _activeSynchronization = synchronization;
    return synchronization.whenComplete(() {
      if (identical(_activeSynchronization, synchronization)) {
        _activeSynchronization = null;
      }
    });
  }

  Future<int> _synchronize(AttendanceGateway gateway) async {
    final queue = await storage.readQueue();
    final remaining = <AttendanceAttempt>[];
    var uploaded = 0;
    for (final attempt in queue) {
      try {
        await gateway.upload(attempt);
        uploaded++;
      } catch (_) {
        remaining.add(attempt);
      }
    }
    await storage.writeQueue(remaining);
    return uploaded;
  }
}
