import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'biometric_testing.dart';
import 'domain.dart';

abstract interface class AttendanceStorage {
  Future<List<AttendanceAttempt>> readQueue();
  Future<void> writeQueue(List<AttendanceAttempt> queue);
}

abstract interface class BiometricRecordStore {
  Future<List<BiometricTrialRecord>> readBiometricRecords();
  Future<void> appendBiometricRecord(BiometricTrialRecord record);
  Future<void> clearBiometricRecords();
}

class SecureAttendanceStorage
    implements AttendanceStorage, BiometricRecordStore {
  SecureAttendanceStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  // MerLens V2 embeddings are incompatible with previously enrolled Model V1
  // templates, so the new model receives a fresh secure-storage namespace.
  static const _legacyTemplateKey = 'face_embedding_template_merlens_v2';
  static const _templatesKey = 'face_embedding_templates_by_driver_merlens_v2';
  static const _siteKey = 'authorized_site_v1';
  static const _queueKey = 'attendance_queue_v1';
  static const _endpointKey = 'sync_endpoint_v1';
  static const _accessTokenKey = 'backend_access_token_v1';
  static const _refreshTokenKey = 'backend_refresh_token_v1';
  static const _driverProfileKey = 'driver_profile_v1';
  static const _assignmentKey = 'driver_assignment_v1';
  static const _debugModeKey = 'debug_mode_v1';
  static const _lastSyncedAtKey = 'last_synced_at_v1';
  static const _biometricRecordsKey = 'biometric_test_records_v1';
  static const _pendingFaceApprovalConsumptionKey =
      'pending_face_approval_consumption_driver_v1';
  static const _pendingDeviceEnrollmentCompletionKey =
      'pending_device_enrollment_completion_driver_v1';

  final FlutterSecureStorage _storage;

  Future<void> saveTemplate(String driverId, List<double> template) async {
    final accountId = _validatedDriverId(driverId);
    normalizeEmbedding(template);
    final templates = await _readTemplates();
    templates[accountId] = template;
    await _storage.write(key: _templatesKey, value: jsonEncode(templates));
    await _storage.delete(key: _legacyTemplateKey);
  }

  Future<List<double>?> readTemplate(String driverId) async {
    final accountId = _validatedDriverId(driverId);
    final raw = (await _readTemplates())[accountId];
    if (raw is! List) return null;
    try {
      final template = raw
          .cast<num>()
          .map((value) => value.toDouble())
          .toList();
      normalizeEmbedding(template);
      return template;
    } on Object {
      return null;
    }
  }

  Future<void> deleteTemplate(String driverId) async {
    final accountId = _validatedDriverId(driverId);
    final templates = await _readTemplates();
    if (templates.remove(accountId) != null) {
      await _storage.write(key: _templatesKey, value: jsonEncode(templates));
    }
  }

  String _validatedDriverId(String driverId) {
    final value = driverId.trim();
    if (value.isEmpty) throw ArgumentError.value(driverId, 'driverId');
    return value;
  }

  Future<Map<String, dynamic>> _readTemplates() async {
    final raw = await _storage.read(key: _templatesKey);
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } on Object {
      return {};
    }
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
    required String deviceAuthorizationStatus,
  }) => _storage.write(
    key: _driverProfileKey,
    value: jsonEncode({
      'id': id,
      'employee_id': employeeId,
      'full_name': fullName,
      'device_authorization_status': deviceAuthorizationStatus,
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

  Future<void> savePendingFaceApprovalConsumption(String driverId) =>
      _storage.write(
        key: _pendingFaceApprovalConsumptionKey,
        value: _validatedDriverId(driverId),
      );

  Future<String?> readPendingFaceApprovalConsumption() =>
      _storage.read(key: _pendingFaceApprovalConsumptionKey);

  Future<void> clearPendingFaceApprovalConsumption() =>
      _storage.delete(key: _pendingFaceApprovalConsumptionKey);

  Future<void> savePendingDeviceEnrollmentCompletion(String driverId) =>
      _storage.write(
        key: _pendingDeviceEnrollmentCompletionKey,
        value: _validatedDriverId(driverId),
      );

  Future<String?> readPendingDeviceEnrollmentCompletion() =>
      _storage.read(key: _pendingDeviceEnrollmentCompletionKey);

  Future<void> clearPendingDeviceEnrollmentCompletion() =>
      _storage.delete(key: _pendingDeviceEnrollmentCompletionKey);

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
  Future<List<BiometricTrialRecord>> readBiometricRecords() async =>
      decodeBiometricRecords(await _storage.read(key: _biometricRecordsKey));

  @override
  Future<void> appendBiometricRecord(BiometricTrialRecord record) async {
    final records = await readBiometricRecords();
    records.add(record);
    await _storage.write(
      key: _biometricRecordsKey,
      value: encodeBiometricRecords(records),
    );
  }

  @override
  Future<void> clearBiometricRecords() =>
      _storage.delete(key: _biometricRecordsKey);

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
