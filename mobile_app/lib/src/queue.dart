import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'domain.dart';
import 'device_identity.dart';
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
  const DriverProfile({
    required this.driver,
    required this.assignment,
    required this.faceReregistrationStatus,
    required this.deviceAuthorizationStatus,
  });

  final DriverIdentity driver;
  final DriverAssignment? assignment;
  final String faceReregistrationStatus;
  final String deviceAuthorizationStatus;

  AuthorizedSite? get assignedSite =>
      assignment?.isActive == true ? assignment!.site : null;
}

class DriverRouteStop {
  const DriverRouteStop({
    required this.id,
    required this.order,
    required this.state,
    required this.locationName,
    required this.address,
    required this.site,
    this.completedAt,
  });

  final String? id;
  final int order;
  final String state;
  final String locationName;
  final String? address;
  final AuthorizedSite site;
  final DateTime? completedAt;

  bool get isCompleted => state == 'completed';
  bool get isSubmitted => isCompleted || state == 'pending_sync';
  bool get isCurrent => state == 'current';

  DriverRouteStop copyWith({String? state}) => DriverRouteStop(
    id: id,
    order: order,
    state: state ?? this.state,
    locationName: locationName,
    address: address,
    site: site,
    completedAt: completedAt,
  );

  factory DriverRouteStop.fromJson(Map<String, dynamic> json) {
    final location = json['location'];
    if (location is! Map<String, dynamic>) {
      throw const FormatException('Route stop location is invalid.');
    }
    final completedAt = json['completed_at'];
    return DriverRouteStop(
      id: json['id'] as String?,
      order: (json['order'] as num).toInt(),
      state: json['state'] as String,
      locationName: location['name'] as String,
      address: location['address'] as String?,
      site: AuthorizedSite.fromJson(location),
      completedAt: completedAt is String
          ? DateTime.parse(completedAt).toLocal()
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'order': order,
    'state': state,
    'completed_at': completedAt?.toUtc().toIso8601String(),
    'location': {...site.toJson(), 'name': locationName, 'address': address},
  };
}

class DriverAssignment {
  const DriverAssignment({
    required this.id,
    required this.status,
    required this.locationName,
    required this.address,
    required this.scheduledAt,
    required this.site,
    this.routeName,
    this.stops = const [],
    this.completedStopCount = 0,
    this.totalStopCount = 1,
    this.currentStopId,
  });

  final String id;
  final String status;
  final String locationName;
  final String? address;
  final DateTime? scheduledAt;
  final AuthorizedSite site;
  final String? routeName;
  final List<DriverRouteStop> stops;
  final int completedStopCount;
  final int totalStopCount;
  final String? currentStopId;

  bool get isActive => status == 'assigned' || status == 'in_progress';
  bool get isPendingSynchronization => status == 'pending_sync';
  int get submittedStopCount =>
      routeStops.where((stop) => stop.isSubmitted).length;

  List<DriverRouteStop> get routeStops => stops.isNotEmpty
      ? stops
      : [
          DriverRouteStop(
            id: null,
            order: 1,
            state: status == 'completed' ? 'completed' : 'current',
            locationName: locationName,
            address: address,
            site: site,
          ),
        ];

  DriverRouteStop? get currentStop {
    for (final stop in routeStops) {
      if (stop.isCurrent) return stop;
    }
    return null;
  }

  DriverAssignment applyPendingAttendance(
    Iterable<AttendanceAttempt> attempts, {
    required String driverId,
  }) {
    final relevant = attempts.where(
      (attempt) =>
          attempt.driverId == driverId &&
          (attempt.assignmentId == id ||
              (attempt.assignmentId == null &&
                  routeStops.any((stop) => stop.site.id == attempt.siteId))),
    );
    if (relevant.isEmpty) return this;
    final pendingStopKeys = relevant
        .map((attempt) => attempt.routeStopId ?? attempt.siteId)
        .toSet();
    final updatedStops = routeStops
        .map((stop) {
          if (stop.isCompleted) return stop;
          final stopKey = stop.id ?? stop.site.id;
          return pendingStopKeys.contains(stopKey)
              ? stop.copyWith(state: 'pending_sync')
              : stop;
        })
        .toList(growable: false);
    final nextIndex = updatedStops.indexWhere((stop) => !stop.isSubmitted);
    final normalizedStops = updatedStops.indexed
        .map((entry) {
          final (index, stop) = entry;
          if (stop.isSubmitted) return stop;
          return stop.copyWith(
            state: index == nextIndex ? 'current' : 'upcoming',
          );
        })
        .toList(growable: false);
    final next = nextIndex < 0 ? null : normalizedStops[nextIndex];
    final display = next ?? normalizedStops.last;
    return DriverAssignment(
      id: id,
      status: next == null ? 'pending_sync' : 'in_progress',
      locationName: display.locationName,
      address: display.address,
      scheduledAt: scheduledAt,
      site: display.site,
      routeName: routeName,
      stops: normalizedStops,
      completedStopCount: normalizedStops
          .where((stop) => stop.isCompleted)
          .length,
      totalStopCount: normalizedStops.length,
      currentStopId: next?.id,
    );
  }

  factory DriverAssignment.fromJson(Map<String, dynamic> json) {
    final location = json['location'];
    if (location is! Map<String, dynamic>) {
      throw const FormatException('Assigned location is invalid.');
    }
    final scheduledAt = json['scheduled_at'];
    final rawStops = json['stops'];
    final stops = rawStops is List
        ? rawStops
              .map(
                (stop) => DriverRouteStop.fromJson(
                  Map<String, dynamic>.from(stop as Map),
                ),
              )
              .toList(growable: false)
        : const <DriverRouteStop>[];
    return DriverAssignment(
      id: json['id'] as String,
      status: json['status'] as String,
      locationName: location['name'] as String,
      address: location['address'] as String?,
      scheduledAt: scheduledAt is String
          ? DateTime.parse(scheduledAt).toLocal()
          : null,
      site: AuthorizedSite.fromJson(location),
      routeName: json['route_name'] as String?,
      stops: stops,
      completedStopCount:
          (json['completed_stop_count'] as num?)?.toInt() ??
          stops.where((stop) => stop.isCompleted).length,
      totalStopCount:
          (json['total_stop_count'] as num?)?.toInt() ??
          (stops.isEmpty ? 1 : stops.length),
      currentStopId: json['current_stop_id'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'status': status,
    'scheduled_at': scheduledAt?.toUtc().toIso8601String(),
    'route_name': routeName,
    'location': {...site.toJson(), 'name': locationName, 'address': address},
    'stops': stops.map((stop) => stop.toJson()).toList(growable: false),
    'completed_stop_count': completedStopCount,
    'total_stop_count': totalStopCount,
    'current_stop_id': currentStopId,
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
  DriverBackendClient(
    this.endpoint, {
    HttpClient? client,
    DeviceIdentityProvider? deviceIdentity,
  }) : _client = client ?? HttpClient(),
       _deviceIdentity = deviceIdentity ?? const AndroidDeviceIdentity();

  final Uri endpoint;
  final HttpClient _client;
  final DeviceIdentityProvider _deviceIdentity;

  Future<Map<String, String>> _deviceProof(
    String loginId,
    String purpose,
  ) async {
    final challengeRequest = await _client.postUrl(
      endpoint.resolve('/api/driver/auth/device-challenge'),
    );
    challengeRequest.headers.contentType = ContentType.json;
    challengeRequest.write(
      jsonEncode({'login_id': loginId, 'purpose': purpose}),
    );
    final challengePayload = await _readJson(await challengeRequest.close());
    final challenge = challengePayload['challenge'];
    if (challenge is! String || challenge.isEmpty) {
      throw const FormatException('Device authorization is unavailable.');
    }
    final identity = await _deviceIdentity.getIdentity();
    return {
      'device_public_key': identity.publicKey,
      'device_challenge': challenge,
      'device_signature': await _deviceIdentity.sign(challenge),
      'device_label': identity.label,
    };
  }

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
      throw const FormatException('Field Personnel response is missing.');
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
    final proof = await _deviceProof(employeeId, 'activate');
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/activate'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'employee_id': employeeId,
        'activation_code': activationCode,
        'password': password,
        ...proof,
      }),
    );
    return _sessionFromPayload(await _readJson(await request.close()));
  }

  Future<DriverSession> login(String loginId, String password) async {
    final proof = await _deviceProof(loginId, 'login');
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/auth/login'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({'login_id': loginId, 'password': password, ...proof}),
    );
    return _sessionFromPayload(await _readJson(await request.close()));
  }

  Future<DriverSession> refresh(String refreshToken, String loginId) async {
    final proof = await _deviceProof(loginId, 'refresh');
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/auth/refresh'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'refresh_token': refreshToken,
        'login_id': loginId,
        ...proof,
      }),
    );
    return _sessionFromPayload(await _readJson(await request.close()));
  }

  Future<DriverProfile> profile(String accessToken) async {
    final request = await _client.getUrl(endpoint.resolve('/api/driver/me'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    final payload = await _readJson(await request.close());
    final driver = payload['driver'];
    if (driver is! Map<String, dynamic>) {
      throw const FormatException('Field Personnel response is missing.');
    }
    final rawAssignment =
        driver['current_assignment'] ?? driver['recent_delivery'];
    final assignment = rawAssignment == null
        ? null
        : DriverAssignment.fromJson(rawAssignment as Map<String, dynamic>);
    if (assignment != null &&
        ([
          assignment.site,
          ...assignment.stops.map((stop) => stop.site),
        ].any((site) => site.radiusMeters < 10 || site.radiusMeters > 5000))) {
      throw const FormatException('Assigned radius is invalid.');
    }
    return DriverProfile(
      driver: DriverIdentity.fromJson(driver),
      assignment: assignment,
      faceReregistrationStatus:
          (driver['face_reregistration_request']
                  as Map<String, dynamic>?)?['status']
              as String? ??
          'none',
      deviceAuthorizationStatus:
          (driver['device_authorization'] as Map<String, dynamic>?)?['status']
              as String? ??
          'unbound',
    );
  }

  Future<String> requestDeviceReplacement(
    String loginId,
    String password,
  ) async {
    final proof = await _deviceProof(loginId, 'replace');
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/device-replacement-request'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({'login_id': loginId, 'password': password, ...proof}),
    );
    final payload = await _readJson(await request.close());
    return (payload['request'] as Map<String, dynamic>)['status'] as String;
  }

  Future<void> completeDeviceEnrollment(String accessToken) async {
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/device/enrollment-complete'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    await _readJson(await request.close());
  }

  Future<String> requestFaceReregistration(String accessToken) async {
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/face-reregistration-request'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    final payload = await _readJson(await request.close());
    return (payload['request'] as Map<String, dynamic>)['status'] as String;
  }

  Future<String> consumeFaceReregistrationApproval(String accessToken) async {
    final request = await _client.postUrl(
      endpoint.resolve('/api/driver/face-reregistration-request/consume'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    final payload = await _readJson(await request.close());
    return (payload['request'] as Map<String, dynamic>)['status'] as String;
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
  Future<void> _storageTail = Future<void>.value();

  Future<T> _withStorageLock<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _storageTail = _storageTail.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<bool> enqueue(AttendanceAttempt attempt) => _withStorageLock(() async {
    if (attempt.driverId.trim().isEmpty ||
        attempt.siteId.trim().isEmpty ||
        (attempt.assignmentId?.trim().isEmpty ?? false) ||
        (attempt.routeStopId?.trim().isEmpty ?? false)) {
      throw ArgumentError('Attendance identity fields must not be empty.');
    }
    final queue = await storage.readQueue();
    if (queue.any(
      (item) =>
          item.clientAttemptId == attempt.clientAttemptId ||
          _sameSubmission(item, attempt),
    )) {
      return false;
    }
    await storage.writeQueue([...queue, attempt]);
    return true;
  });

  Future<bool> hasPendingSubmission({
    required String driverId,
    required String assignmentId,
    required String? routeStopId,
    required String siteId,
  }) => _withStorageLock(
    () async => (await storage.readQueue()).any(
      (item) =>
          item.driverId == driverId &&
          ((item.assignmentId == assignmentId &&
                  (item.routeStopId ?? item.siteId) ==
                      (routeStopId ?? siteId)) ||
              (item.assignmentId == null && item.siteId == siteId)),
    ),
  );

  bool _sameSubmission(AttendanceAttempt first, AttendanceAttempt second) {
    if (first.driverId != second.driverId) return false;
    if (first.assignmentId == null || second.assignmentId == null) {
      return first.siteId == second.siteId;
    }
    return first.assignmentId == second.assignmentId &&
        (first.routeStopId ?? first.siteId) ==
            (second.routeStopId ?? second.siteId);
  }

  Future<int> synchronize(AttendanceGateway gateway) {
    final active = _activeSynchronization;
    if (active != null) return active;
    final synchronization = _withStorageLock(() => _synchronize(gateway));
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
