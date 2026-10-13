import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';

import 'camera_diagnostics.dart';
import 'camera_flow.dart';
import 'camera_frame.dart';
import 'camera_geometry.dart';
import 'model_runtime.dart';
import 'similarity_alignment.dart';

class FacePipelineInitialization {
  const FacePipelineInitialization({
    required this.provider,
    required this.detectorReady,
  });

  final String provider;
  final bool detectorReady;
}

class CameraDiagnosticSnapshot {
  const CameraDiagnosticSnapshot({
    required this.rawWidth,
    required this.rawHeight,
    required this.uprightWidth,
    required this.uprightHeight,
    required this.sensorOrientation,
    required this.appliedRotation,
    required this.previewMirrored,
    required this.analysisMirrored,
    required this.sourceFormat,
    required this.channelOrder,
    required this.detectorWidth,
    required this.detectorHeight,
    required this.debugCandidateCount,
    required this.highestDebugConfidence,
    required this.debugBoundingBox,
    required this.debugLandmarks,
    required this.productionAccepted,
    required this.rejectionReason,
  });

  final int rawWidth;
  final int rawHeight;
  final int uprightWidth;
  final int uprightHeight;
  final int sensorOrientation;
  final int appliedRotation;
  final bool previewMirrored;
  final bool analysisMirrored;
  final String sourceFormat;
  final String channelOrder;
  final int detectorWidth;
  final int detectorHeight;
  final int debugCandidateCount;
  final double? highestDebugConfidence;
  final List<double>? debugBoundingBox;
  final List<Point2d>? debugLandmarks;
  final bool productionAccepted;
  final String rejectionReason;
}

class CameraFramePipelineResult {
  const CameraFramePipelineResult({
    required this.observation,
    required this.diagnostic,
    required this.embedding,
  });

  final FaceObservation observation;
  final CameraDiagnosticSnapshot diagnostic;
  final List<double>? embedding;
}

class _DetectionRows {
  const _DetectionRows(this.rows);

  final List<List<double>> rows;

  int get count => rows.length;

  List<double>? get highest {
    if (rows.isEmpty) return null;
    return rows.reduce(
      (first, second) => first[14] >= second[14] ? first : second,
    );
  }
}

class _ValidatedDetection {
  const _ValidatedDetection({
    required this.row,
    required this.boundingBox,
    required this.landmarks,
    required this.confidence,
  });

  final List<double> row;
  final List<double> boundingBox;
  final List<Point2d> landmarks;
  final double confidence;
}

class FacePipeline {
  FacePipeline({EmbeddingRuntime? runtime, CameraFrameConverter? converter})
    : _runtime = runtime ?? EmbeddingRuntime(),
      _converter = converter ?? const CameraFrameConverter();

  static const detectorAsset =
      'assets/models/face_detection_yunet_2023mar.onnx';
  static const detectorThreshold = CameraFlowRules.productionThreshold;
  static const debugDetectorThreshold = CameraFlowRules.debugReportingThreshold;

  final EmbeddingRuntime _runtime;
  final CameraFrameConverter _converter;
  cv.FaceDetectorYN? _productionDetector;
  cv.FaceDetectorYN? _debugDetector;
  FacePipelineInitialization? _initialization;

  Future<FacePipelineInitialization> initialize() async {
    final existing = _initialization;
    if (existing != null) return existing;
    final detectorPath = await _copyAsset(detectorAsset);
    _productionDetector = cv.FaceDetectorYN.fromFile(
      detectorPath,
      '',
      (320, 320),
      scoreThreshold: detectorThreshold,
      nmsThreshold: 0.3,
      topK: 5000,
    );
    _debugDetector = cv.FaceDetectorYN.fromFile(
      detectorPath,
      '',
      (320, 320),
      scoreThreshold: debugDetectorThreshold,
      nmsThreshold: 0.3,
      topK: 5000,
    );
    final provider = await _runtime.load();
    return _initialization = FacePipelineInitialization(
      provider: provider,
      detectorReady: true,
    );
  }

  Future<String> _copyAsset(String assetPath) async {
    final directory = await getApplicationSupportDirectory();
    final modelDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}models',
    );
    await modelDirectory.create(recursive: true);
    final destination = File(
      '${modelDirectory.path}${Platform.pathSeparator}${assetPath.split('/').last}',
    );
    final data = await rootBundle.load(assetPath);
    final expectedLength = data.lengthInBytes;
    if (!await destination.exists() ||
        await destination.length() != expectedLength) {
      await destination.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, expectedLength),
        flush: true,
      );
    }
    return destination.path;
  }

  ConvertedCameraFrame copyCameraFrame({
    required CameraImage frame,
    required CameraOrientation orientation,
    void Function(CameraProcessingStage stage)? onStageChanged,
  }) {
    onStageChanged?.call(CameraProcessingStage.frameConversion);
    try {
      return _converter.convert(
        frame,
        rotationDegrees: orientation.rotationDegrees,
      );
    } catch (error, stackTrace) {
      throw CameraPipelineException(
        stage: CameraProcessingStage.frameConversion,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  Future<CameraFramePipelineResult> analyzeOwnedCameraFrame({
    required ConvertedCameraFrame frame,
    required CameraOrientation orientation,
    required bool diagnosticsEnabled,
    required Future<bool> Function(FaceObservation observation)
    requestEmbedding,
    void Function(CameraProcessingStage stage)? onStageChanged,
  }) async {
    if (_productionDetector == null || _debugDetector == null) {
      throw StateError('The detector is not initialized.');
    }
    var activeStage = CameraProcessingStage.yunetInference;
    void reportStage(CameraProcessingStage stage) {
      activeStage = stage;
      onStageChanged?.call(stage);
    }

    cv.Mat? image;
    cv.Mat? productionFaces;
    cv.Mat? debugFaces;
    try {
      reportStage(CameraProcessingStage.yunetInference);
      image = cv.Mat.fromList(
        frame.upright.height,
        frame.upright.width,
        cv.MatType.CV_8UC3,
        frame.upright.bytes,
      );
      final production = _productionDetector!;
      production.setInputSize((image.cols, image.rows));
      productionFaces = production.detect(image);
      final productionRows = _rows(productionFaces);

      var debugRows = const _DetectionRows([]);
      if (diagnosticsEnabled) {
        final debug = _debugDetector!;
        debug.setInputSize((image.cols, image.rows));
        debugFaces = debug.detect(image);
        debugRows = _rows(debugFaces);
      }
      final evaluation = _observationFromRows(
        productionRows: productionRows,
        debugRows: debugRows,
        width: image.cols,
        height: image.rows,
      );
      reportStage(CameraProcessingStage.livenessEvaluation);
      final shouldInfer = await requestEmbedding(evaluation.observation);
      if (shouldInfer && !evaluation.observation.hasProductionFace) {
        throw StateError('A diagnostic detection cannot authorize capture.');
      }
      final embedding = shouldInfer
          ? await _embeddingForDetection(
              image,
              evaluation.validated!,
              onStageChanged: reportStage,
            )
          : null;
      final highestDebug = debugRows.highest;
      return CameraFramePipelineResult(
        observation: evaluation.observation,
        diagnostic: CameraDiagnosticSnapshot(
          rawWidth: frame.rawWidth,
          rawHeight: frame.rawHeight,
          uprightWidth: frame.upright.width,
          uprightHeight: frame.upright.height,
          sensorOrientation: orientation.sensorOrientation,
          appliedRotation: orientation.rotationDegrees,
          previewMirrored: orientation.previewMirrored,
          analysisMirrored: orientation.analysisMirrored,
          sourceFormat: frame.sourceFormat,
          channelOrder: frame.channelOrder,
          detectorWidth: image.cols,
          detectorHeight: image.rows,
          debugCandidateCount: debugRows.count,
          highestDebugConfidence: highestDebug?[14],
          debugBoundingBox: highestDebug?.sublist(0, 4),
          debugLandmarks: highestDebug == null
              ? null
              : _landmarks(highestDebug),
          productionAccepted: evaluation.observation.hasProductionFace,
          rejectionReason: evaluation.observation.rejectionReason,
        ),
        embedding: embedding,
      );
    } catch (error, stackTrace) {
      if (error is CameraPipelineException) rethrow;
      throw CameraPipelineException(
        stage: activeStage,
        cause: error,
        causeStackTrace: stackTrace,
      );
    } finally {
      debugFaces?.dispose();
      productionFaces?.dispose();
      image?.dispose();
    }
  }

  _ObservationEvaluation _observationFromRows({
    required _DetectionRows productionRows,
    required _DetectionRows debugRows,
    required int width,
    required int height,
  }) {
    final highestDebug = debugRows.highest;
    if (productionRows.count != 1) {
      final reason = productionRows.count > 1
          ? 'multiple_faces'
          : debugRows.count > 0
          ? 'below_production_threshold'
          : 'no_face';
      return _ObservationEvaluation(
        observation: FaceObservation(
          productionFaceCount: productionRows.count,
          productionConfidence: productionRows.highest?[14],
          debugCandidateCount: debugRows.count,
          highestDebugConfidence: highestDebug?[14],
          geometryValid: false,
          centerX: null,
          centerY: null,
          faceWidthRatio: null,
          noseOffsetEyeDistances: null,
          rejectionReason: reason,
        ),
      );
    }
    try {
      final detection = _validateDetection(
        productionRows.rows.single,
        width: width,
        height: height,
      );
      final bbox = detection.boundingBox;
      final landmarks = detection.landmarks;
      final eyeMidX = (landmarks[0].x + landmarks[1].x) / 2;
      final eyeDx = landmarks[1].x - landmarks[0].x;
      final eyeDy = landmarks[1].y - landmarks[0].y;
      final eyeDistance = math.sqrt(eyeDx * eyeDx + eyeDy * eyeDy);
      if (!eyeDistance.isFinite || eyeDistance <= 1e-6) {
        throw const _DetectionValidationError('invalid_eye_geometry');
      }
      final observation = FaceObservation(
        productionFaceCount: 1,
        productionConfidence: detection.confidence,
        debugCandidateCount: debugRows.count,
        highestDebugConfidence: highestDebug?[14],
        geometryValid: true,
        centerX: (bbox[0] + bbox[2] / 2) / width,
        centerY: (bbox[1] + bbox[3] / 2) / height,
        faceWidthRatio: bbox[2] / width,
        noseOffsetEyeDistances: (landmarks[2].x - eyeMidX) / eyeDistance,
        rejectionReason: 'accepted',
        boxX: bbox[0] / width,
        boxY: bbox[1] / height,
        boxWidth: bbox[2] / width,
        boxHeight: bbox[3] / height,
      );
      return _ObservationEvaluation(
        observation: observation,
        validated: detection,
      );
    } on _DetectionValidationError catch (error) {
      return _ObservationEvaluation(
        observation: FaceObservation(
          productionFaceCount: 1,
          productionConfidence: productionRows.rows.single[14],
          debugCandidateCount: debugRows.count,
          highestDebugConfidence: highestDebug?[14],
          geometryValid: false,
          centerX: null,
          centerY: null,
          faceWidthRatio: null,
          noseOffsetEyeDistances: null,
          rejectionReason: error.reason,
        ),
      );
    }
  }

  _ValidatedDetection _validateDetection(
    List<double> row, {
    required int width,
    required int height,
  }) {
    if (row.length != 15 || row.any((value) => !value.isFinite)) {
      throw const _DetectionValidationError('invalid_detection');
    }
    if (row[14] < detectorThreshold) {
      throw const _DetectionValidationError('below_production_threshold');
    }
    final bbox = row.sublist(0, 4);
    if (bbox[2] <= 0 || bbox[3] <= 0) {
      throw const _DetectionValidationError('invalid_bbox');
    }
    final xMargin = width * 0.05;
    final yMargin = height * 0.05;
    if (bbox[0] < -xMargin ||
        bbox[1] < -yMargin ||
        bbox[0] + bbox[2] > width + xMargin ||
        bbox[1] + bbox[3] > height + yMargin) {
      throw const _DetectionValidationError('bbox_out_of_bounds');
    }
    final landmarks = _landmarks(row);
    if (landmarks.any(
      (point) =>
          point.x < 0 || point.x >= width || point.y < 0 || point.y >= height,
    )) {
      throw const _DetectionValidationError('landmarks_out_of_bounds');
    }
    return _ValidatedDetection(
      row: row,
      boundingBox: bbox,
      landmarks: landmarks,
      confidence: row[14],
    );
  }

  Future<List<double>> _embeddingForDetection(
    cv.Mat image,
    _ValidatedDetection detection, {
    required void Function(CameraProcessingStage stage) onStageChanged,
  }) async {
    cv.Mat? transform;
    cv.Mat? aligned;
    File? alignedFile;
    try {
      onStageChanged(CameraProcessingStage.alignment);
      final matrix = solveSimilarityTransform(
        detection.landmarks,
        frozenAlignmentTarget,
      );
      transform = cv.Mat.fromList(2, 3, cv.MatType.CV_64FC1, matrix);
      aligned = cv.warpAffine(
        image,
        transform,
        (224, 224),
        flags: cv.INTER_LINEAR,
        borderMode: cv.BORDER_CONSTANT,
      );
      if (aligned.rows != 224 || aligned.cols != 224) {
        throw StateError('Alignment did not produce a 224x224 image.');
      }
      final temporaryDirectory = await getTemporaryDirectory();
      alignedFile = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}aligned_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      if (!cv.imwrite(alignedFile.path, aligned)) {
        throw StateError('The aligned temporary image could not be encoded.');
      }
      onStageChanged(CameraProcessingStage.embeddingInference);
      return await _runtime.inferAlignedImage(alignedFile.path);
    } finally {
      aligned?.dispose();
      transform?.dispose();
      if (alignedFile != null && await alignedFile.exists()) {
        await alignedFile.delete();
      }
    }
  }

  _DetectionRows _rows(cv.Mat faces) {
    if (faces.isEmpty) return const _DetectionRows([]);
    return _DetectionRows(
      faces
          .toList()
          .map((row) => row.map((value) => value.toDouble()).take(15).toList())
          .where((row) => row.length == 15)
          .toList(growable: false),
    );
  }

  List<Point2d> _landmarks(List<double> row) => List.generate(
    5,
    (index) => Point2d(row[4 + index * 2], row[5 + index * 2]),
    growable: false,
  );

  void dispose() {
    _debugDetector?.dispose();
    _productionDetector?.dispose();
    _debugDetector = null;
    _productionDetector = null;
    _initialization = null;
  }
}

class _ObservationEvaluation {
  const _ObservationEvaluation({required this.observation, this.validated});

  final FaceObservation observation;
  final _ValidatedDetection? validated;
}

class _DetectionValidationError implements Exception {
  const _DetectionValidationError(this.reason);

  final String reason;
}
