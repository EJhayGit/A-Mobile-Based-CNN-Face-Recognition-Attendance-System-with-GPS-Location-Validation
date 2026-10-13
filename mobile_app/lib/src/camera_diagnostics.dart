import 'package:flutter/foundation.dart';

enum CameraProcessingStage {
  idle,
  cameraInitialization,
  imageStreamControl,
  frameConversion,
  yunetInference,
  qualityEvaluation,
  mediaPipeInitialization,
  mediaPipeInference,
  livenessEvaluation,
  brightnessControl,
  alignment,
  embeddingInference,
  enrollmentStorage,
  attendanceEvaluation,
}

enum CameraScanFailureKind {
  streamInterrupted,
  frameConversion,
  detectorRuntime,
  qualityProcessing,
  mediaPipeInitialization,
  mediaPipeInference,
  livenessProcessing,
  brightnessControl,
  automaticCapture,
  embeddingInference,
  controllerUnavailable,
  unknown,
}

class CameraPipelineException implements Exception {
  CameraPipelineException({
    required this.stage,
    required Object cause,
    required this.causeStackTrace,
  }) : causeType = cause.runtimeType.toString(),
       causeMessage = cause.toString();

  final CameraProcessingStage stage;
  final String causeType;
  final String causeMessage;
  final StackTrace causeStackTrace;

  @override
  String toString() => '$causeType: $causeMessage';
}

class CameraScanFailure {
  const CameraScanFailure({
    required this.kind,
    required this.userMessage,
    required this.exceptionType,
    required this.sanitizedMessage,
    required this.sanitizedStackTrace,
    required this.stage,
  });

  final CameraScanFailureKind kind;
  final String userMessage;
  final String exceptionType;
  final String sanitizedMessage;
  final String sanitizedStackTrace;
  final CameraProcessingStage stage;

  static CameraScanFailure classify(
    Object error,
    StackTrace stackTrace, {
    required CameraProcessingStage activeStage,
  }) {
    final pipelineError = error is CameraPipelineException ? error : null;
    final stage = pipelineError?.stage ?? activeStage;
    final exceptionType =
        pipelineError?.causeType ?? error.runtimeType.toString();
    final message = pipelineError?.causeMessage ?? error.toString();
    final actualStack = pipelineError?.causeStackTrace ?? stackTrace;
    final kind = switch (stage) {
      CameraProcessingStage.cameraInitialization =>
        CameraScanFailureKind.controllerUnavailable,
      CameraProcessingStage.imageStreamControl =>
        CameraScanFailureKind.streamInterrupted,
      CameraProcessingStage.frameConversion =>
        CameraScanFailureKind.frameConversion,
      CameraProcessingStage.yunetInference =>
        CameraScanFailureKind.detectorRuntime,
      CameraProcessingStage.qualityEvaluation =>
        CameraScanFailureKind.qualityProcessing,
      CameraProcessingStage.mediaPipeInitialization =>
        CameraScanFailureKind.mediaPipeInitialization,
      CameraProcessingStage.mediaPipeInference =>
        CameraScanFailureKind.mediaPipeInference,
      CameraProcessingStage.livenessEvaluation =>
        CameraScanFailureKind.livenessProcessing,
      CameraProcessingStage.brightnessControl =>
        CameraScanFailureKind.brightnessControl,
      CameraProcessingStage.alignment => CameraScanFailureKind.automaticCapture,
      CameraProcessingStage.embeddingInference =>
        CameraScanFailureKind.embeddingInference,
      CameraProcessingStage.enrollmentStorage =>
        CameraScanFailureKind.automaticCapture,
      CameraProcessingStage.attendanceEvaluation =>
        CameraScanFailureKind.unknown,
      CameraProcessingStage.idle => CameraScanFailureKind.unknown,
    };
    final userMessage = switch (kind) {
      CameraScanFailureKind.streamInterrupted => 'Camera stream interrupted',
      CameraScanFailureKind.frameConversion => 'Frame conversion failed',
      CameraScanFailureKind.detectorRuntime => 'Face detector failed',
      CameraScanFailureKind.qualityProcessing =>
        'Capture quality measurement failed',
      CameraScanFailureKind.mediaPipeInitialization =>
        'Detailed liveness could not start',
      CameraScanFailureKind.mediaPipeInference =>
        'Detailed liveness processing failed',
      CameraScanFailureKind.livenessProcessing => 'Liveness processing failed',
      CameraScanFailureKind.brightnessControl =>
        'Screen illumination could not be restored safely',
      CameraScanFailureKind.automaticCapture => 'Automatic capture failed',
      CameraScanFailureKind.embeddingInference => 'Embedding inference failed',
      CameraScanFailureKind.controllerUnavailable =>
        'Camera controller unavailable',
      CameraScanFailureKind.unknown => 'Unknown scan error',
    };
    return CameraScanFailure(
      kind: kind,
      userMessage: userMessage,
      exceptionType: _sanitize(exceptionType, maximumLength: 160),
      sanitizedMessage: _sanitize(message, maximumLength: 500),
      sanitizedStackTrace: _sanitize(
        actualStack.toString(),
        maximumLength: 4000,
      ),
      stage: stage,
    );
  }
}

class CameraScanDebugRecord {
  const CameraScanDebugRecord({
    required this.failure,
    required this.flowStateBeforeFailure,
    required this.mostRecentSuccessfulTransition,
    required this.imageStreamingActive,
    required this.stillCaptureRequested,
    required this.yunetInferenceActive,
    required this.embeddingInferenceActive,
    required this.livenessEvaluationActive,
    required this.controllerInitialized,
    required this.widgetMounted,
    required this.processingLockActive,
    required this.rawWidth,
    required this.rawHeight,
    required this.uprightWidth,
    required this.uprightHeight,
    required this.imageFormat,
    required this.elapsedMilliseconds,
  });

  final CameraScanFailure failure;
  final String flowStateBeforeFailure;
  final String mostRecentSuccessfulTransition;
  final bool imageStreamingActive;
  final bool stillCaptureRequested;
  final bool yunetInferenceActive;
  final bool embeddingInferenceActive;
  final bool livenessEvaluationActive;
  final bool controllerInitialized;
  final bool widgetMounted;
  final bool processingLockActive;
  final int rawWidth;
  final int rawHeight;
  final int? uprightWidth;
  final int? uprightHeight;
  final String imageFormat;
  final int elapsedMilliseconds;

  String toSanitizedText() => [
    'failure=${failure.kind.name}',
    'exception=${failure.exceptionType}',
    'message=${failure.sanitizedMessage}',
    'operation=${failure.stage.name}',
    'flow_before=$flowStateBeforeFailure',
    'last_transition=$mostRecentSuccessfulTransition',
    'streaming=$imageStreamingActive',
    'still_capture=$stillCaptureRequested',
    'yunet_active=$yunetInferenceActive',
    'embedding_active=$embeddingInferenceActive',
    'liveness_active=$livenessEvaluationActive',
    'controller_initialized=$controllerInitialized',
    'mounted=$widgetMounted',
    'processing_lock=$processingLockActive',
    'raw=${rawWidth}x$rawHeight',
    'upright=${uprightWidth ?? 'unknown'}x${uprightHeight ?? 'unknown'}',
    'format=$imageFormat',
    'elapsed_ms=$elapsedMilliseconds',
    'stack=${failure.sanitizedStackTrace}',
  ].join('\n');

  void debugLog() {
    if (kDebugMode) debugPrint(toSanitizedText());
  }
}

String _sanitize(String input, {required int maximumLength}) {
  var value = input
      .replaceAll(
        RegExp(r'file:\/\/\/[A-Za-z]:\/[^\s\)]+', caseSensitive: false),
        '[private-path]',
      )
      .replaceAll(RegExp(r'[A-Za-z]:\\[^\r\n\s\)]+'), '[private-path]')
      .replaceAll(RegExp(r'\/(?:Users|home)\/[^\r\n\s\)]+'), '[private-path]');
  if (value.length > maximumLength) {
    value = '${value.substring(0, maximumLength)}…';
  }
  return value;
}
