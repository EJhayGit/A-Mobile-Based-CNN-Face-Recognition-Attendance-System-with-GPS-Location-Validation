import 'dart:convert';
import 'dart:math' as math;

import 'domain.dart';

const biometricTestingAppVersion = '1.0.0+1';
const biometricTestingModelVersion = 'merlens-v2-curriculum-fp32-opset18';

enum BiometricLightingCondition { indoorNormal, bright, dim }

extension BiometricLightingConditionLabel on BiometricLightingCondition {
  String get csvValue => switch (this) {
    BiometricLightingCondition.indoorNormal => 'indoor_normal',
    BiometricLightingCondition.bright => 'bright',
    BiometricLightingCondition.dim => 'dim',
  };

  String get displayLabel => switch (this) {
    BiometricLightingCondition.indoorNormal => 'Indoor / Normal',
    BiometricLightingCondition.bright => 'Bright',
    BiometricLightingCondition.dim => 'Dim',
  };
}

String normalizeParticipantPseudonym(String value) {
  final normalized = value.trim().toUpperCase();
  if (!RegExp(r'^[A-Z0-9][A-Z0-9_-]{0,31}$').hasMatch(normalized)) {
    throw const FormatException(
      'Use 1-32 letters, numbers, hyphens, or underscores.',
    );
  }
  return normalized;
}

class BiometricTrialSetup {
  BiometricTrialSetup({
    required String enrolledId,
    required String probeId,
    required this.condition,
    String? deviceLabel,
  }) : enrolledId = normalizeParticipantPseudonym(enrolledId),
       probeId = normalizeParticipantPseudonym(probeId),
       deviceLabel = _normalizeOptionalLabel(deviceLabel);

  final String enrolledId;
  final String probeId;
  final BiometricLightingCondition condition;
  final String? deviceLabel;

  String get groundTruth => enrolledId == probeId ? 'genuine' : 'impostor';
}

String? _normalizeOptionalLabel(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (normalized.length > 64 || normalized.contains(RegExp(r'[\r\n]'))) {
    throw const FormatException('Device label must be 64 characters or less.');
  }
  return normalized;
}

String newBiometricTrialId() {
  final random = math.Random.secure();
  final entropy = List.generate(
    8,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return 'bio-${DateTime.now().microsecondsSinceEpoch}-$entropy';
}

class BiometricTrialRecord {
  const BiometricTrialRecord({
    required this.trialId,
    required this.enrolledId,
    required this.probeId,
    required this.groundTruth,
    required this.condition,
    required this.scores,
    required this.aggregateScore,
    required this.currentThreshold,
    required this.productionAccepted,
    required this.failureReason,
    required this.appVersion,
    required this.modelVersion,
    required this.timestampUtc,
    this.deviceLabel,
  });

  final String trialId;
  final String enrolledId;
  final String probeId;
  final String groundTruth;
  final BiometricLightingCondition condition;
  final List<double> scores;
  final double? aggregateScore;
  final double currentThreshold;
  final bool? productionAccepted;
  final String? failureReason;
  final String appVersion;
  final String modelVersion;
  final DateTime timestampUtc;
  final String? deviceLabel;

  Map<String, Object?> toJson() => {
    'trial_id': trialId,
    'enrolled_id': enrolledId,
    'probe_id': probeId,
    'ground_truth': groundTruth,
    'condition': condition.csvValue,
    'scores': scores,
    'aggregate_score': aggregateScore,
    'current_threshold': currentThreshold,
    'production_accepted': productionAccepted,
    'failure_reason': failureReason,
    'app_version': appVersion,
    'model_version': modelVersion,
    'timestamp_utc': timestampUtc.toUtc().toIso8601String(),
    'device_label': deviceLabel,
  };

  factory BiometricTrialRecord.fromJson(Map<String, dynamic> json) {
    final conditionValue = json['condition'] as String;
    return BiometricTrialRecord(
      trialId: json['trial_id'] as String,
      enrolledId: json['enrolled_id'] as String,
      probeId: json['probe_id'] as String,
      groundTruth: json['ground_truth'] as String,
      condition: BiometricLightingCondition.values.firstWhere(
        (value) => value.csvValue == conditionValue,
      ),
      scores: (json['scores'] as List)
          .cast<num>()
          .map((value) => value.toDouble())
          .toList(growable: false),
      aggregateScore: (json['aggregate_score'] as num?)?.toDouble(),
      currentThreshold: (json['current_threshold'] as num).toDouble(),
      productionAccepted: json['production_accepted'] as bool?,
      failureReason: json['failure_reason'] as String?,
      appVersion: json['app_version'] as String,
      modelVersion: json['model_version'] as String,
      timestampUtc: DateTime.parse(json['timestamp_utc'] as String).toUtc(),
      deviceLabel: json['device_label'] as String?,
    );
  }
}

class BiometricTrialCollector {
  BiometricTrialCollector({
    required this.setup,
    required List<double> enrollment,
    String? trialId,
    DateTime? startedAt,
  }) : _enrollment = normalizeEmbedding(enrollment),
       trialId = trialId ?? newBiometricTrialId(),
       startedAt = (startedAt ?? DateTime.now()).toUtc();

  final BiometricTrialSetup setup;
  final List<double> _enrollment;
  final String trialId;
  final DateTime startedAt;
  final List<List<double>> _probes = [];
  final List<double> _scores = [];

  int get sampleCount => _scores.length;
  bool get complete => sampleCount == attendanceVerificationComparisonCount;
  List<double> get scores => List.unmodifiable(_scores);

  void addProbe(List<double> probe) {
    if (complete) {
      throw StateError('Biometric trial already has three samples.');
    }
    final normalizedProbe = normalizeEmbedding(probe);
    _probes.add(normalizedProbe);
    _scores.add(cosineSimilarity(_enrollment, normalizedProbe));
  }

  void resetSamples() {
    _probes.clear();
    _scores.clear();
  }

  BiometricTrialRecord buildRecord({String? failureReason}) {
    final aggregate = complete
        ? cosineSimilarity(_enrollment, enrollmentTemplate(_probes))
        : null;
    final accepted = aggregate == null
        ? null
        : _scores.every((score) => score >= lockedCosineThreshold) &&
              aggregate >= lockedCosineThreshold;
    return BiometricTrialRecord(
      trialId: trialId,
      enrolledId: setup.enrolledId,
      probeId: setup.probeId,
      groundTruth: setup.groundTruth,
      condition: setup.condition,
      scores: List.unmodifiable(_scores),
      aggregateScore: aggregate,
      currentThreshold: lockedCosineThreshold,
      productionAccepted: accepted,
      failureReason: failureReason,
      appVersion: biometricTestingAppVersion,
      modelVersion: biometricTestingModelVersion,
      timestampUtc: startedAt,
      deviceLabel: setup.deviceLabel,
    );
  }
}

const biometricCsvColumns = [
  'trial_id',
  'enrolled_id',
  'probe_id',
  'ground_truth',
  'condition',
  'score1',
  'score2',
  'score3',
  'aggregate',
  'current_threshold',
  'result',
  'failure_reason',
  'app_version',
  'model_version',
  'timestamp_utc',
  'device_label',
];

String biometricRecordsToCsv(Iterable<BiometricTrialRecord> records) {
  final rows = <List<Object?>>[
    biometricCsvColumns,
    ...records.map(
      (record) => [
        record.trialId,
        record.enrolledId,
        record.probeId,
        record.groundTruth,
        record.condition.csvValue,
        record.scores.elementAtOrNull(0),
        record.scores.elementAtOrNull(1),
        record.scores.elementAtOrNull(2),
        record.aggregateScore,
        record.currentThreshold,
        record.productionAccepted == null
            ? 'excluded'
            : record.productionAccepted!
            ? 'accepted'
            : 'rejected',
        record.failureReason,
        record.appVersion,
        record.modelVersion,
        record.timestampUtc.toUtc().toIso8601String(),
        record.deviceLabel,
      ],
    ),
  ];
  return '${rows.map((row) => row.map(_csvCell).join(',')).join('\r\n')}\r\n';
}

String _csvCell(Object? value) {
  if (value == null) return '';
  var text = value is double ? value.toStringAsPrecision(17) : value.toString();
  if (value is String && RegExp(r'^[=+\-@]').hasMatch(text)) text = "'$text";
  if (text.contains(RegExp('[,"\r\n]'))) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
}

String encodeBiometricRecords(Iterable<BiometricTrialRecord> records) =>
    jsonEncode(records.map((record) => record.toJson()).toList());

List<BiometricTrialRecord> decodeBiometricRecords(String? raw) {
  if (raw == null) return [];
  try {
    return (jsonDecode(raw) as List)
        .cast<Map<String, dynamic>>()
        .map(BiometricTrialRecord.fromJson)
        .toList();
  } on Object {
    return [];
  }
}
