import 'dart:math' as math;

const lockedCosineThreshold = 0.2071264386177063;
const embeddingLength = 128;

List<double> normalizeEmbedding(List<double> input) {
  if (input.length != embeddingLength ||
      input.any((value) => !value.isFinite)) {
    throw ArgumentError('Embedding must contain 128 finite values.');
  }
  final norm = math.sqrt(
    input.fold<double>(0, (sum, value) => sum + value * value),
  );
  if (!norm.isFinite || norm == 0) {
    throw ArgumentError('Embedding norm must be finite and non-zero.');
  }
  return input.map((value) => value / norm).toList(growable: false);
}

List<double> enrollmentTemplate(List<List<double>> captures) {
  if (captures.isEmpty) {
    throw ArgumentError('At least one enrollment capture is required.');
  }
  final normalized = captures.map(normalizeEmbedding).toList(growable: false);
  final mean = List<double>.filled(embeddingLength, 0);
  for (final embedding in normalized) {
    for (var index = 0; index < embeddingLength; index++) {
      mean[index] += embedding[index] / normalized.length;
    }
  }
  return normalizeEmbedding(mean);
}

double cosineSimilarity(List<double> first, List<double> second) {
  final a = normalizeEmbedding(first);
  final b = normalizeEmbedding(second);
  var score = 0.0;
  for (var index = 0; index < embeddingLength; index++) {
    score += a[index] * b[index];
  }
  return score;
}

double haversineMeters(
  double latitudeA,
  double longitudeA,
  double latitudeB,
  double longitudeB,
) {
  const earthRadiusMeters = 6371008.8;
  double radians(double degrees) => degrees * math.pi / 180;
  final latitudeDelta = radians(latitudeB - latitudeA);
  final longitudeDelta = radians(longitudeB - longitudeA);
  final value =
      math.sin(latitudeDelta / 2) * math.sin(latitudeDelta / 2) +
      math.cos(radians(latitudeA)) *
          math.cos(radians(latitudeB)) *
          math.sin(longitudeDelta / 2) *
          math.sin(longitudeDelta / 2);
  return earthRadiusMeters *
      2 *
      math.atan2(math.sqrt(value), math.sqrt(1 - value));
}

class AuthorizedSite {
  const AuthorizedSite({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
  });

  final String id;
  final double latitude;
  final double longitude;
  final double radiusMeters;

  Map<String, Object> toJson() => {
    'id': id,
    'latitude': latitude,
    'longitude': longitude,
    'radius_meters': radiusMeters,
  };

  factory AuthorizedSite.fromJson(Map<String, dynamic> json) => AuthorizedSite(
    id: json['id'] as String,
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    radiusMeters: (json['radius_meters'] as num).toDouble(),
  );
}

AuthorizedSite? assignedSiteFromDriverResponse(Map<String, dynamic> payload) {
  final driver = payload['driver'];
  if (driver is! Map<String, dynamic>) {
    throw const FormatException('Driver response is missing.');
  }
  final assignment = driver['current_assignment'];
  if (assignment == null) return null;
  if (assignment is! Map<String, dynamic>) {
    throw const FormatException('Assigned delivery is invalid.');
  }
  final location = assignment['location'];
  if (location is! Map<String, dynamic>) {
    throw const FormatException('Assigned location is invalid.');
  }
  final site = AuthorizedSite.fromJson({
    'id': location['id'],
    'latitude': location['latitude'],
    'longitude': location['longitude'],
    'radius_meters': location['radius_meters'],
  });
  if (site.radiusMeters < 10 || site.radiusMeters > 5000) {
    throw const FormatException('Assigned radius is invalid.');
  }
  return site;
}

class AttendanceDecision {
  const AttendanceDecision({
    required this.accepted,
    required this.faceScore,
    required this.distanceMeters,
    required this.reason,
  });

  final bool accepted;
  final double faceScore;
  final double distanceMeters;
  final String reason;
}

AttendanceDecision evaluateAttendance({
  required List<double> enrollment,
  required List<double> probe,
  required AuthorizedSite site,
  required double latitude,
  required double longitude,
  required double accuracyMeters,
}) {
  final score = cosineSimilarity(enrollment, probe);
  final validCoordinates =
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;
  final distance = validCoordinates
      ? haversineMeters(latitude, longitude, site.latitude, site.longitude)
      : double.infinity;
  if (score < lockedCosineThreshold) {
    return AttendanceDecision(
      accepted: false,
      faceScore: score,
      distanceMeters: distance,
      reason: 'face_non_match',
    );
  }
  if (!validCoordinates || !accuracyMeters.isFinite || accuracyMeters < 0) {
    return AttendanceDecision(
      accepted: false,
      faceScore: score,
      distanceMeters: distance,
      reason: 'gps_accuracy_rejected',
    );
  }
  if (distance > site.radiusMeters) {
    return AttendanceDecision(
      accepted: false,
      faceScore: score,
      distanceMeters: distance,
      reason: 'outside_authorized_site',
    );
  }
  return AttendanceDecision(
    accepted: true,
    faceScore: score,
    distanceMeters: distance,
    reason: 'accepted',
  );
}

class AttendanceAttempt {
  const AttendanceAttempt({
    required this.clientAttemptId,
    required this.driverId,
    required this.siteId,
    required this.capturedAtUtc,
    required this.latitude,
    required this.longitude,
    required this.gpsAccuracyMeters,
    required this.distanceMeters,
    required this.faceScore,
  });

  final String clientAttemptId;
  final String driverId;
  final String siteId;
  final DateTime capturedAtUtc;
  final double latitude;
  final double longitude;
  final double gpsAccuracyMeters;
  final double distanceMeters;
  final double faceScore;

  Map<String, Object> toJson() => {
    'client_attempt_id': clientAttemptId,
    'driver_id': driverId,
    'site_id': siteId,
    'captured_at_utc': capturedAtUtc.toUtc().toIso8601String(),
    'latitude': latitude,
    'longitude': longitude,
    'gps_accuracy_meters': gpsAccuracyMeters,
    'distance_meters': distanceMeters,
    'face_score': faceScore,
    'face_verified': true,
    'gps_verified': true,
  };

  factory AttendanceAttempt.fromJson(Map<String, dynamic> json) =>
      AttendanceAttempt(
        clientAttemptId: json['client_attempt_id'] as String,
        driverId: json['driver_id'] as String,
        siteId: json['site_id'] as String,
        capturedAtUtc: DateTime.parse(
          json['captured_at_utc'] as String,
        ).toUtc(),
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        gpsAccuracyMeters: (json['gps_accuracy_meters'] as num).toDouble(),
        distanceMeters: (json['distance_meters'] as num).toDouble(),
        faceScore: (json['face_score'] as num).toDouble(),
      );
}
