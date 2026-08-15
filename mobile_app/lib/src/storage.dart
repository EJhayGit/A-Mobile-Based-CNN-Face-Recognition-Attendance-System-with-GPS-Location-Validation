import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'domain.dart';

abstract interface class AttendanceStorage {
  Future<List<AttendanceAttempt>> readQueue();
  Future<void> writeQueue(List<AttendanceAttempt> queue);
}

class SecureAttendanceStorage implements AttendanceStorage {
  SecureAttendanceStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  // MerLens V2 embeddings are incompatible with previously enrolled Model V1
  // templates, so the new model receives a fresh secure-storage namespace.
  static const _templateKey = 'face_embedding_template_merlens_v2';
  static const _siteKey = 'authorized_site_v1';
  static const _queueKey = 'attendance_queue_v1';
  static const _endpointKey = 'sync_endpoint_v1';
  static const _accessTokenKey = 'backend_access_token_v1';
  static const _refreshTokenKey = 'backend_refresh_token_v1';
  static const _driverProfileKey = 'driver_profile_v1';
  static const _assignmentKey = 'driver_assignment_v1';
  static const _debugModeKey = 'debug_mode_v1';
  static const _lastSyncedAtKey = 'last_synced_at_v1';

  final FlutterSecureStorage _storage;

  Future<void> saveTemplate(List<double> template) =>
      _storage.write(key: _templateKey, value: jsonEncode(template));

  Future<List<double>?> readTemplate() async {
    final raw = await _storage.read(key: _templateKey);
    if (raw == null) return null;
    return (jsonDecode(raw) as List)
        .cast<num>()
        .map((value) => value.toDouble())
        .toList();
  }

  Future<void> saveSite(AuthorizedSite site) =>
      _storage.write(key: _siteKey, value: jsonEncode(site.toJson()));

  Future<AuthorizedSite?> readSite() async {
    final raw = await _storage.read(key: _siteKey);
    if (raw == null) return null;
    return AuthorizedSite.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> clearSite() => _storage.delete(key: _siteKey);

  Future<void> saveEndpoint(String endpoint) =>
      _storage.write(key: _endpointKey, value: endpoint);

  Future<String?> readEndpoint() => _storage.read(key: _endpointKey);

  Future<void> saveBackendTokens(
    String accessToken,
    String refreshToken,
  ) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  Future<String?> readAccessToken() => _storage.read(key: _accessTokenKey);

  Future<String?> readRefreshToken() => _storage.read(key: _refreshTokenKey);

  Future<void> saveDriverProfile({
    required String id,
    required String employeeId,
    required String fullName,
  }) => _storage.write(
    key: _driverProfileKey,
    value: jsonEncode({
      'id': id,
      'employee_id': employeeId,
      'full_name': fullName,
    }),
  );

  Future<Map<String, dynamic>?> readDriverProfile() async {
    final raw = await _storage.read(key: _driverProfileKey);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> saveDriverAssignment(Map<String, Object?> assignment) =>
      _storage.write(key: _assignmentKey, value: jsonEncode(assignment));

  Future<Map<String, dynamic>?> readDriverAssignment() async {
    final raw = await _storage.read(key: _assignmentKey);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> clearDriverAssignment() => _storage.delete(key: _assignmentKey);

  Future<void> clearBackendSession() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _siteKey);
    await _storage.delete(key: _driverProfileKey);
    await _storage.delete(key: _assignmentKey);
  }

  Future<void> saveDebugMode(bool enabled) =>
      _storage.write(key: _debugModeKey, value: enabled ? 'true' : 'false');

  Future<bool> readDebugMode() async =>
      await _storage.read(key: _debugModeKey) == 'true';

  Future<void> saveLastSyncedAt(DateTime value) => _storage.write(
    key: _lastSyncedAtKey,
    value: value.toUtc().toIso8601String(),
  );

  Future<DateTime?> readLastSyncedAt() async {
    final raw = await _storage.read(key: _lastSyncedAtKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }

  @override
  Future<List<AttendanceAttempt>> readQueue() async {
    final raw = await _storage.read(key: _queueKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .cast<Map<String, dynamic>>()
        .map(AttendanceAttempt.fromJson)
        .toList();
  }

  @override
  Future<void> writeQueue(List<AttendanceAttempt> queue) => _storage.write(
    key: _queueKey,
    value: jsonEncode(queue.map((attempt) => attempt.toJson()).toList()),
  );
}
