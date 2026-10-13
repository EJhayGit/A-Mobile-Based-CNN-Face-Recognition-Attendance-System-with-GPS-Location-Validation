import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'biometric_testing.dart';
import 'camera_diagnostics.dart';
import 'camera_flow.dart';
import 'camera_geometry.dart';
import 'capture_quality.dart';
import 'domain.dart';
import 'face_pipeline.dart';
import 'liveness_runtime.dart';
import 'location.dart';
import 'queue.dart';
import 'secure_liveness_flow.dart';
import 'storage.dart';

class CameraScanResult {
  const CameraScanResult({
    required this.success,
    required this.message,
    this.biometricTrial,
  });

  final bool success;
  final String message;
  final BiometricTrialRecord? biometricTrial;
}

class CameraScanScreen extends StatefulWidget {
  const CameraScanScreen({
    super.key,
    required this.purpose,
    required this.pipeline,
    required this.storage,
    required this.queue,
    required this.location,
    required this.driverId,
    this.assignmentId,
    this.routeStopId,
    this.enrollmentTemplate,
    this.authorizedSite,
    this.debugMode = false,
    this.biometricTrialSetup,
  });

  final ScanPurpose purpose;
  final FacePipeline pipeline;
  final SecureAttendanceStorage storage;
  final AttendanceQueue queue;
  final DeviceLocationService location;
  final String driverId;
  final String? assignmentId;
  final String? routeStopId;
  final List<double>? enrollmentTemplate;
  final AuthorizedSite? authorizedSite;
  final bool debugMode;
  final BiometricTrialSetup? biometricTrialSetup;

  @override
  State<CameraScanScreen> createState() => _CameraScanScreenState();
}

class _CameraScanScreenState extends State<CameraScanScreen>
    with WidgetsBindingObserver {
  late final SecureLivenessController _flow = SecureLivenessController(
    purpose: widget.purpose,
  );
  final _processingGate = FrameProcessingGate();
  final _qualityAnalyzer = CaptureQualityAnalyzer();
  final _livenessRuntime = LivenessRuntime();
  final _brightnessRuntime = WindowBrightnessRuntime();
  final _enrollmentEmbeddings = <List<double>>[];
  final _attendanceVerification = AttendanceFaceVerification();
  final _sessionElapsed = Stopwatch();

  CameraController? _camera;
  CameraOrientation? _orientation;
  CameraDiagnosticSnapshot? _diagnostic;
  CaptureQuality? _quality;
  MediaPipeObservation? _mediaPipe;
  HeadTurnDiagnostic? _headTurnDiagnostic;
  String _status = 'Initializing';
  double _progress = 0;
  bool _initializing = true;
  bool _stopping = false;
  bool _brightnessRaised = false;
  bool _lowLightIllumination = false;
  ScreenIllumination _screenIllumination = ScreenIllumination.neutral;
  int _lastEnrollmentResetToken = 0;
  int _lastLivenessTimestamp = -1;
  CameraScanResult? _result;
  CameraProcessingStage _activeOperation = CameraProcessingStage.idle;
  String _flowStateBeforeFailure = SecureLivenessStage.quality.name;
  String _lastSuccessfulTransition = 'session_start -> quality';
  CameraScanDebugRecord? _lastError;
  BiometricTrialCollector? _biometricTrialCollector;

  @override
  void initState() {
    super.initState();
    final template = widget.enrollmentTemplate;
    if (widget.biometricTrialSetup != null &&
        (!kDebugMode || !widget.debugMode)) {
      throw StateError(
        'Biometric Testing Mode requires a debug build and Debug Mode.',
      );
    }
    if (widget.purpose == ScanPurpose.attendance && template != null) {
      _attendanceVerification.begin(
        driverId: widget.driverId,
        enrollmentTemplate: template,
      );
      _resetBiometricTrialCollector(template);
    }
    WidgetsBinding.instance.addObserver(this);
    _sessionElapsed.start();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      await _ensureMaximumBrightness();
      _activeOperation = CameraProcessingStage.cameraInitialization;
      await widget.pipeline.initialize();
      _activeOperation = CameraProcessingStage.mediaPipeInitialization;
      await _livenessRuntime.startSession(_flow.sessionId);
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No Android camera is available.');
      final selected = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final orientation = CameraOrientation.resolve(
        camera: selected,
        deviceOrientation: DeviceOrientation.portraitUp,
      );
      final controller = CameraController(
        selected,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _orientation = orientation;
        _initializing = false;
        _status = cameraGuidanceFor(
          debugMode: widget.debugMode,
          stage: SecureLivenessStage.quality,
          detailedGuidance: 'Position your face',
          purpose: widget.purpose,
        );
      });
      _activeOperation = CameraProcessingStage.imageStreamControl;
      await controller.startImageStream(_onCameraFrame);
      _activeOperation = CameraProcessingStage.idle;
      _lastSuccessfulTransition = 'camera_initialized -> streaming';
    } catch (error, stackTrace) {
      _recordFailure(error, stackTrace);
    }
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    final startedAt = DateTime.now();
    if (_result != null) return;
    await _processingGate.runIfAcquired(startedAt, () async {
      try {
        final orientation = _orientation;
        if (orientation == null) {
          throw StateError('Camera orientation is unavailable.');
        }
        void reportOperation(CameraProcessingStage stage) {
          _activeOperation = stage;
          _flowStateBeforeFailure = _flow.stage.name;
        }

        final ownedFrame = widget.pipeline.copyCameraFrame(
          frame: image,
          orientation: orientation,
          onStageChanged: reportOperation,
        );
        SecureLivenessUpdate? flowUpdate;
        final frameResult = await widget.pipeline.analyzeOwnedCameraFrame(
          frame: ownedFrame,
          orientation: orientation,
          diagnosticsEnabled: widget.debugMode,
          onStageChanged: reportOperation,
          requestEmbedding: (observation) async {
            CaptureQuality? quality;
            MediaPipeObservation? mediaPipe;
            if (observation.hasProductionFace) {
              reportOperation(CameraProcessingStage.qualityEvaluation);
              quality = _qualityAnalyzer.analyze(
                ownedFrame.upright,
                observation,
              );
              reportOperation(CameraProcessingStage.mediaPipeInference);
              final timestamp = math.max(
                _sessionElapsed.elapsedMilliseconds,
                _lastLivenessTimestamp + 1,
              );
              _lastLivenessTimestamp = timestamp;
              mediaPipe = await _livenessRuntime.analyzeFrame(
                sessionId: _flow.sessionId,
                timestampMs: timestamp,
                frame: ownedFrame,
              );
            }
            reportOperation(CameraProcessingStage.livenessEvaluation);
            final before = _flow.stage;
            _flowStateBeforeFailure = before.name;
            final update = _flow.process(
              SecureLivenessEvidence(
                yunet: observation,
                quality: quality,
                mediaPipe: mediaPipe,
                now: startedAt,
              ),
            );
            if (_flow.enrollmentResetToken != _lastEnrollmentResetToken) {
              _enrollmentEmbeddings.clear();
              _attendanceVerification.resetAttempt();
              _biometricTrialCollector?.resetSamples();
              _lastEnrollmentResetToken = _flow.enrollmentResetToken;
            }
            _recordTransition(before, _flow.stage);
            if (before == SecureLivenessStage.headTurn &&
                _flow.stage == SecureLivenessStage.headReturn) {
              unawaited(HapticFeedback.mediumImpact());
            }
            flowUpdate = update;
            _quality = quality;
            _mediaPipe = mediaPipe;
            await _applyPresentation(update);
            if (update.captureRequested && mounted) {
              setState(() {
                _status = _visibleGuidance('Capturing sample');
                _progress = 1;
              });
            }
            return update.captureRequested;
          },
        );
        _activeOperation = CameraProcessingStage.idle;
        if (!mounted) return;
        final update = flowUpdate;
        if (update != null && frameResult.embedding == null) {
          setState(() {
            _diagnostic = frameResult.diagnostic;
            _status = _visibleGuidance(update.guidance);
            _progress = update.progress;
          });
          if (_flow.stage == SecureLivenessStage.timedOut) {
            await _finish(
              const CameraScanResult(
                success: false,
                message: 'Liveness challenge timed out',
              ),
            );
          } else if (_flow.stage == SecureLivenessStage.failed) {
            await _finish(
              CameraScanResult(success: false, message: update.guidance),
            );
          }
        }
        final embedding = frameResult.embedding;
        if (embedding != null) {
          setState(() => _diagnostic = frameResult.diagnostic);
          _activeOperation = widget.purpose == ScanPurpose.registration
              ? CameraProcessingStage.enrollmentStorage
              : CameraProcessingStage.attendanceEvaluation;
          _flowStateBeforeFailure = _flow.stage.name;
          await _handleAutomaticEmbedding(embedding);
          _activeOperation = CameraProcessingStage.idle;
        }
      } catch (error, stackTrace) {
        _recordFailure(error, stackTrace, frame: image);
      }
    });
    if (_result != null) await _stopImageStreamSafely();
  }

  Future<void> _handleAutomaticEmbedding(List<double> embedding) async {
    if (widget.purpose == ScanPurpose.registration) {
      _enrollmentEmbeddings.add(embedding);
      final before = _flow.stage;
      _flow.captureCompleted(DateTime.now());
      _recordTransition(before, _flow.stage);
      if (_enrollmentEmbeddings.length < 3) {
        if (mounted) {
          setState(() {
            _status =
                'Enrollment sample ${_enrollmentEmbeddings.length + 1} of 3';
            _progress = _enrollmentEmbeddings.length / 3;
          });
        }
        return;
      }
      final template = enrollmentTemplate(_enrollmentEmbeddings);
      await widget.storage.saveTemplate(widget.driverId, template);
      _flow.setCompletedMessage('Registration complete');
      await _finish(
        const CameraScanResult(success: true, message: 'Registration complete'),
      );
      return;
    }

    final template = widget.enrollmentTemplate;
    if (template == null) {
      await _finish(
        const CameraScanResult(
          success: false,
          message: 'Register a face before submitting attendance.',
        ),
      );
      return;
    }
    final biometricCollector = _biometricTrialCollector;
    if (biometricCollector != null) {
      biometricCollector.addProbe(embedding);
      final before = _flow.stage;
      _flow.captureCompleted(DateTime.now());
      _recordTransition(before, _flow.stage);
      if (!biometricCollector.complete) {
        if (mounted) {
          setState(() {
            _status =
                'Research sample ${biometricCollector.sampleCount + 1} '
                'of ${CameraFlowRules.attendanceVerificationCaptures}';
            _progress =
                biometricCollector.sampleCount /
                CameraFlowRules.attendanceVerificationCaptures;
          });
        }
        return;
      }
      final record = biometricCollector.buildRecord();
      _flow.setCompletedMessage('Biometric test trial recorded');
      await _finish(
        CameraScanResult(
          success: true,
          message: 'Biometric test trial recorded',
          biometricTrial: record,
        ),
      );
      return;
    }
    final comparison = _attendanceVerification.compare(
      driverId: widget.driverId,
      probe: embedding,
    );
    if (comparison.status == AttendanceFaceComparisonStatus.rejected) {
      _flow.captureFailed('Verification failed');
      await _finish(
        const CameraScanResult(
          success: false,
          message: 'Face not recognized. Please try again.',
        ),
      );
      return;
    }
    final before = _flow.stage;
    _flow.captureCompleted(DateTime.now());
    _recordTransition(before, _flow.stage);
    if (comparison.status == AttendanceFaceComparisonStatus.pending) {
      if (mounted) {
        setState(() {
          _status =
              'Verification sample ${_attendanceVerification.comparisonCount + 1} '
              'of ${CameraFlowRules.attendanceVerificationCaptures}';
          _progress =
              _attendanceVerification.comparisonCount /
              CameraFlowRules.attendanceVerificationCaptures;
        });
      }
      return;
    }
    final probe = comparison.aggregatedProbe!;

    final site = widget.authorizedSite;
    if (site == null) {
      _flow.setCompletedMessage('No assigned site');
      await _finish(
        const CameraScanResult(
          success: false,
          message:
              'Connect to the backend and download an assigned site first.',
        ),
      );
      return;
    }

    try {
      if (mounted) setState(() => _status = 'Getting your location');
      final reading = await widget.location.current();
      final decision = evaluateAttendance(
        enrollment: template,
        probe: probe,
        site: site,
        latitude: reading.latitude,
        longitude: reading.longitude,
        accuracyMeters: reading.accuracyMeters,
      );
      if (!decision.accepted) {
        final message = switch (decision.reason) {
          'gps_accuracy_rejected' =>
            'Your location could not be verified. Please enable location services and try again.',
          'outside_authorized_site' =>
            'You are outside the assigned Site Location attendance area.',
          _ => 'Face not recognized. Please try again.',
        };
        _flow.setCompletedMessage(message);
        await _finish(CameraScanResult(success: false, message: message));
        return;
      }
      final queued = await widget.queue.enqueue(
        AttendanceAttempt(
          clientAttemptId: _newAttemptId(),
          driverId: widget.driverId,
          siteId: site.id,
          assignmentId: widget.assignmentId,
          routeStopId: widget.routeStopId,
          capturedAtUtc: DateTime.now().toUtc(),
          latitude: reading.latitude,
          longitude: reading.longitude,
          gpsAccuracyMeters: reading.accuracyMeters,
          distanceMeters: decision.distanceMeters,
          faceScore: decision.faceScore,
        ),
      );
      if (!queued) {
        _flow.setCompletedMessage('Site Assignment already submitted');
        await _finish(
          const CameraScanResult(
            success: false,
            message:
                'Attendance for this Site Assignment is already saved and waiting to sync.',
          ),
        );
        return;
      }
      _flow.setCompletedMessage(
        'Attendance saved offline. It will sync when internet is available.',
      );
      await _finish(
        const CameraScanResult(
          success: true,
          message:
              'Attendance saved offline. It will sync when internet is available.',
        ),
      );
    } catch (_) {
      _flow.setCompletedMessage('Location could not be verified');
      await _finish(
        const CameraScanResult(
          success: false,
          message:
              'Your location could not be verified. Please enable location services and try again.',
        ),
      );
    }
  }

  String _newAttemptId() {
    final random = math.Random.secure();
    final entropy = List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '${DateTime.now().microsecondsSinceEpoch}-$entropy';
  }

  String _visibleGuidance(String detailed) => cameraGuidanceFor(
    debugMode: widget.debugMode,
    stage: _flow.stage,
    detailedGuidance: detailed,
    purpose: widget.purpose,
  );

  Future<void> _applyPresentation(SecureLivenessUpdate update) async {
    await _ensureMaximumBrightness();
    _activeOperation = CameraProcessingStage.livenessEvaluation;
    final headTurnDiagnostic = update.headTurnDiagnostic;
    if (kDebugMode &&
        headTurnDiagnostic != null &&
        (headTurnDiagnostic.turnFrames != _headTurnDiagnostic?.turnFrames ||
            headTurnDiagnostic.returnFrames !=
                _headTurnDiagnostic?.returnFrames)) {
      debugPrint(
        'Head response ${headTurnDiagnostic.direction.name}: '
        'baseline ${headTurnDiagnostic.baselineYaw.toStringAsFixed(1)}, '
        'current ${headTurnDiagnostic.currentYaw.toStringAsFixed(1)}, '
        'delta ${headTurnDiagnostic.yawDelta.toStringAsFixed(1)}, '
        'turn ${headTurnDiagnostic.turnFrames}/'
        '${headTurnDiagnostic.requiredTurnFrames}, return '
        '${headTurnDiagnostic.returnFrames}/'
        '${headTurnDiagnostic.requiredReturnFrames}',
      );
    }
    if (!mounted) return;
    setState(() {
      _screenIllumination = update.screenIllumination;
      _lowLightIllumination = update.lowLightIllumination;
      _headTurnDiagnostic = headTurnDiagnostic;
    });
  }

  Future<void> _ensureMaximumBrightness() async {
    if (_brightnessRaised) return;
    _activeOperation = CameraProcessingStage.brightnessControl;
    await _brightnessRuntime.setForIllumination();
    _brightnessRaised = true;
  }

  Future<void> _releaseLivenessResources() async {
    Object? firstError;
    StackTrace? firstStack;
    try {
      _activeOperation = CameraProcessingStage.brightnessControl;
      await _brightnessRuntime.restore();
      _brightnessRaised = false;
    } catch (error, stackTrace) {
      firstError = error;
      firstStack = stackTrace;
    }
    try {
      _activeOperation = CameraProcessingStage.mediaPipeInitialization;
      await _livenessRuntime.closeSession();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStack ??= stackTrace;
    } finally {
      _activeOperation = CameraProcessingStage.idle;
      void clearPresentation() {
        _screenIllumination = ScreenIllumination.neutral;
        _lowLightIllumination = false;
        _headTurnDiagnostic = null;
      }

      if (mounted) {
        setState(clearPresentation);
      } else {
        clearPresentation();
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  Future<void> _finish(CameraScanResult result) async {
    if (!mounted) return;
    final collector = _biometricTrialCollector;
    if (collector != null && result.biometricTrial == null) {
      result = CameraScanResult(
        success: false,
        message: result.message,
        biometricTrial: collector.buildRecord(failureReason: result.message),
      );
    }
    final visibleResult = !result.success && !widget.debugMode
        ? CameraScanResult(
            success: false,
            message: normalAttendanceMessage(result.message),
          )
        : result;
    setState(() {
      _result = visibleResult;
      _status = visibleResult.message;
      _progress = 1;
    });
    _attendanceVerification.clear();
    await _releaseLivenessResources();
  }

  Future<void> _stopImageStream() async {
    if (_stopping) return;
    final controller = _camera;
    if (controller == null || !controller.value.isStreamingImages) return;
    _stopping = true;
    try {
      await controller.stopImageStream();
    } finally {
      _stopping = false;
    }
  }

  Future<void> _stopImageStreamSafely() async {
    try {
      _activeOperation = CameraProcessingStage.imageStreamControl;
      await _stopImageStream();
      _activeOperation = CameraProcessingStage.idle;
    } catch (error, stackTrace) {
      if (_result == null || _result!.success) {
        _recordFailure(error, stackTrace);
      } else {
        final failure = CameraScanFailure.classify(
          error,
          stackTrace,
          activeStage: CameraProcessingStage.imageStreamControl,
        );
        if (kDebugMode) {
          debugPrint(
            'supplemental_stream_error=${failure.exceptionType}: '
            '${failure.sanitizedMessage}',
          );
        }
      }
    }
  }

  void _recordTransition(
    SecureLivenessStage before,
    SecureLivenessStage after,
  ) {
    if (before != after) {
      _lastSuccessfulTransition = '${before.name} -> ${after.name}';
    }
  }

  void _recordFailure(
    Object error,
    StackTrace stackTrace, {
    CameraImage? frame,
  }) {
    final failure = CameraScanFailure.classify(
      error,
      stackTrace,
      activeStage: _activeOperation,
    );
    final controller = _camera;
    final diagnostic = _diagnostic;
    final stage = failure.stage;
    final record = CameraScanDebugRecord(
      failure: failure,
      flowStateBeforeFailure: _flowStateBeforeFailure,
      mostRecentSuccessfulTransition: _lastSuccessfulTransition,
      imageStreamingActive: controller?.value.isStreamingImages ?? false,
      stillCaptureRequested: false,
      yunetInferenceActive: stage == CameraProcessingStage.yunetInference,
      embeddingInferenceActive:
          stage == CameraProcessingStage.embeddingInference,
      livenessEvaluationActive:
          stage == CameraProcessingStage.livenessEvaluation,
      controllerInitialized: controller?.value.isInitialized ?? false,
      widgetMounted: mounted,
      processingLockActive: _processingGate.locked,
      rawWidth: frame?.width ?? diagnostic?.rawWidth ?? 0,
      rawHeight: frame?.height ?? diagnostic?.rawHeight ?? 0,
      uprightWidth: diagnostic?.uprightWidth,
      uprightHeight: diagnostic?.uprightHeight,
      imageFormat:
          frame?.format.group.name ?? diagnostic?.sourceFormat ?? 'unknown',
      elapsedMilliseconds: _sessionElapsed.elapsedMilliseconds,
    );
    record.debugLog();
    _flow.captureFailed(failure.userMessage);
    unawaited(
      _releaseLivenessResources().catchError((Object _, StackTrace _) {}),
    );
    _activeOperation = CameraProcessingStage.idle;
    _lastError = record;
    if (!mounted) return;
    setState(() {
      _initializing = false;
      _status = widget.debugMode
          ? failure.userMessage
          : normalCameraFailureMessage(failure.kind);
      _result = CameraScanResult(
        success: false,
        message: widget.debugMode
            ? failure.userMessage
            : normalCameraFailureMessage(failure.kind),
        biometricTrial: _biometricTrialCollector?.buildRecord(
          failureReason: failure.kind.name,
        ),
      );
    });
  }

  Future<void> _restart() async {
    await _releaseLivenessResources();
    await _ensureMaximumBrightness();
    _flow.restart();
    _processingGate.reset();
    _qualityAnalyzer.reset();
    _enrollmentEmbeddings.clear();
    final template = widget.enrollmentTemplate;
    if (widget.purpose == ScanPurpose.attendance && template != null) {
      _attendanceVerification.begin(
        driverId: widget.driverId,
        enrollmentTemplate: template,
      );
      _resetBiometricTrialCollector(template);
    } else {
      _attendanceVerification.clear();
      _biometricTrialCollector = null;
    }
    _lastEnrollmentResetToken = _flow.enrollmentResetToken;
    _sessionElapsed
      ..reset()
      ..start();
    _activeOperation = CameraProcessingStage.idle;
    _flowStateBeforeFailure = SecureLivenessStage.quality.name;
    _lastSuccessfulTransition = 'restart -> quality';
    _lastLivenessTimestamp = -1;
    _activeOperation = CameraProcessingStage.mediaPipeInitialization;
    await _livenessRuntime.startSession(_flow.sessionId);
    _activeOperation = CameraProcessingStage.idle;
    setState(() {
      _result = null;
      _lastError = null;
      _diagnostic = null;
      _quality = null;
      _mediaPipe = null;
      _headTurnDiagnostic = null;
      _lowLightIllumination = false;
      _status = cameraGuidanceFor(
        debugMode: widget.debugMode,
        stage: SecureLivenessStage.quality,
        detailedGuidance: 'Position your face',
        purpose: widget.purpose,
      );
      _progress = 0;
    });
    final controller = _camera;
    if (controller != null &&
        controller.value.isInitialized &&
        !controller.value.isStreamingImages) {
      try {
        _activeOperation = CameraProcessingStage.imageStreamControl;
        await controller.startImageStream(_onCameraFrame);
        _activeOperation = CameraProcessingStage.idle;
      } catch (error, stackTrace) {
        _recordFailure(error, stackTrace);
      }
    }
  }

  void _resetBiometricTrialCollector(List<double> template) {
    final setup = widget.biometricTrialSetup;
    _biometricTrialCollector = setup == null
        ? null
        : BiometricTrialCollector(setup: setup, enrollment: template);
  }

  Future<void> _close() async {
    _attendanceVerification.clear();
    await _stopImageStreamSafely();
    await _releaseLivenessResources();
    var result = _result;
    final collector = _biometricTrialCollector;
    if (result == null && collector != null) {
      result = CameraScanResult(
        success: false,
        message: 'Biometric test trial cancelled',
        biometricTrial: collector.buildRecord(failureReason: 'user_cancelled'),
      );
    }
    if (mounted) Navigator.of(context).pop(result);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        _result == null) {
      _flow.restart();
      _attendanceVerification.clear();
      _qualityAnalyzer.reset();
      _processingGate.reset();
      _lastLivenessTimestamp = -1;
      if (mounted) {
        setState(() {
          _screenIllumination = ScreenIllumination.neutral;
          _lowLightIllumination = false;
          _headTurnDiagnostic = null;
          _status = 'Liveness session paused; restart required';
          _result = CameraScanResult(
            success: false,
            message: 'Liveness session paused; restart required',
            biometricTrial: _biometricTrialCollector?.buildRecord(
              failureReason: 'lifecycle_interrupted',
            ),
          );
        });
      }
      unawaited(_stopImageStreamSafely());
      unawaited(
        _releaseLivenessResources().catchError((Object _, StackTrace _) {}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final orientation = _orientation;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (camera != null &&
              camera.value.isInitialized &&
              orientation != null)
            FullScreenCameraPreview(
              controller: camera,
              rotationDegrees: orientation.rotationDegrees,
            )
          else
            const ColoredBox(color: Colors.black),
          _FaceGuideOverlay(
            illuminated: _lowLightIllumination,
            screenIllumination: _screenIllumination,
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton.filledTonal(
                        key: const Key('cancel_scan'),
                        onPressed: _close,
                        icon: const Icon(Icons.close),
                        tooltip: 'Cancel scan',
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.biometricTrialSetup != null
                              ? 'Biometric Test Trial'
                              : widget.purpose == ScanPurpose.registration
                              ? 'Register Face'
                              : 'Submit Attendance',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                    ],
                  ),
                  if (widget.debugMode)
                    _DebugDiagnosticCard(
                      diagnostic: _diagnostic,
                      activeOperation: _activeOperation,
                      flowStage: _flow.stage,
                      lastError: _lastError,
                      quality: _quality,
                      mediaPipe: _mediaPipe,
                      headTurnDiagnostic: _headTurnDiagnostic,
                    ),
                  const Spacer(),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Text(
                        _status,
                        key: const Key('camera_status'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    color: Colors.black.withValues(alpha: 0.72),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinearProgressIndicator(
                            value: _initializing ? null : _progress,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Challenge-response liveness engineering only',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                          if (_result != null) ...[
                            const SizedBox(height: 12),
                            FilledButton(
                              key: const Key('done_scan'),
                              onPressed: _close,
                              child: Text(_result!.success ? 'Done' : 'Close'),
                            ),
                            if (!_result!.success &&
                                widget.biometricTrialSetup == null)
                              TextButton(
                                key: const Key('restart_scan'),
                                onPressed: _restart,
                                child: const Text('Restart'),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionElapsed.stop();
    unawaited(
      _releaseLivenessResources().catchError((Object _, StackTrace _) {}),
    );
    final camera = _camera;
    if (camera != null) unawaited(camera.dispose());
    super.dispose();
  }
}

class FullScreenCameraPreview extends StatelessWidget {
  const FullScreenCameraPreview({
    super.key,
    required this.controller,
    required this.rotationDegrees,
  });

  final CameraController controller;
  final int rotationDegrees;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final previewSize = controller.value.previewSize;
      if (previewSize == null) return const ColoredBox(color: Colors.black);
      final geometry = calculatePreviewCover(
        viewport: Size(constraints.maxWidth, constraints.maxHeight),
        cameraPreviewSize: previewSize,
        rotationDegrees: rotationDegrees,
      );
      return ClipRect(
        child: Center(
          child: SizedBox(
            width: geometry.coverSize.width,
            height: geometry.coverSize.height,
            child: CameraPreview(controller),
          ),
        ),
      );
    },
  );
}

@visibleForTesting
String cameraGuidanceFor({
  required bool debugMode,
  required SecureLivenessStage stage,
  required String detailedGuidance,
  required ScanPurpose purpose,
}) {
  if (debugMode) return detailedGuidance;
  return switch (stage) {
    SecureLivenessStage.quality => normalAttendanceMessage(detailedGuidance),
    SecureLivenessStage.headTurn =>
      detailedGuidance.toLowerCase().contains('right')
          ? 'Turn right'
          : 'Turn left',
    SecureLivenessStage.headReturn => 'Turn back to center',
    SecureLivenessStage.captureStabilizing ||
    SecureLivenessStage.captureCooldown => 'Hold still',
    SecureLivenessStage.processing =>
      purpose == ScanPurpose.attendance
          ? 'Verifying face'
          : 'Saving face setup',
    SecureLivenessStage.completed => detailedGuidance,
    SecureLivenessStage.timedOut =>
      'Face verification timed out. Please try again.',
    SecureLivenessStage.failed => normalAttendanceMessage(detailedGuidance),
  };
}

@visibleForTesting
String normalAttendanceMessage(String detailed) {
  final message = detailed.toLowerCase();
  if (message.contains('multiple face')) {
    return 'Only one person should be visible.';
  }
  if (message.contains('move closer')) return 'Move closer to the camera.';
  if (message.contains('full face inside') || message.contains('too close')) {
    return 'Move slightly farther from the camera.';
  }
  if (message.contains('position your face') || message.contains('no face')) {
    return 'No face detected. Position your face inside the guide.';
  }
  if (message.contains('light') ||
      message.contains('glare') ||
      message.contains('blurry') ||
      message.contains('exposure') ||
      message.contains('quality') ||
      (message.contains('hold') && message.contains('still'))) {
    return 'Your face image is unclear. Move to a brighter area and hold still.';
  }
  if (message.contains('outside the assigned')) return detailed;
  if (message.contains('gps') || message.contains('location')) {
    return 'Your location could not be verified. Please enable location services and try again.';
  }
  if (message.contains('already saved') ||
      message.contains('already submitted')) {
    return 'Attendance for this Site Assignment is already saved and waiting to sync.';
  }
  if (message.contains('saved offline')) return detailed;
  if (message.contains('verification failed') ||
      message.contains('not recognized')) {
    return 'Face not recognized. Please try again.';
  }
  return 'Unable to verify. Please try again.';
}

@visibleForTesting
String normalCameraFailureMessage(CameraScanFailureKind kind) => switch (kind) {
  CameraScanFailureKind.detectorRuntime =>
    'No face detected. Position your face inside the guide.',
  CameraScanFailureKind.qualityProcessing =>
    'Your face image is unclear. Move to a brighter area and hold still.',
  CameraScanFailureKind.controllerUnavailable ||
  CameraScanFailureKind.streamInterrupted =>
    'The camera is unavailable. Close other camera apps and try again.',
  _ => 'Unable to verify. Please try again.',
};

class _FaceGuideOverlay extends StatelessWidget {
  const _FaceGuideOverlay({
    required this.illuminated,
    required this.screenIllumination,
  });

  final bool illuminated;
  final ScreenIllumination screenIllumination;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      key: const Key('face_guide_overlay'),
      painter: _FaceGuidePainter(
        illuminated: illuminated,
        screenIllumination: screenIllumination,
      ),
      child: const SizedBox.expand(key: Key('liveness_screen_illumination')),
    ),
  );
}

@visibleForTesting
Path buildLivenessPerimeterPath(Size size, Rect guide) => Path()
  ..fillType = PathFillType.evenOdd
  ..addRect(Offset.zero & size)
  ..addOval(guide);

const faceGuideOutlineWidth = 4.0;

@visibleForTesting
Color? resolveLivenessPerimeterColor({
  required bool illuminated,
  required ScreenIllumination screenIllumination,
}) {
  if (illuminated) return Colors.white;
  return switch (screenIllumination) {
    ScreenIllumination.neutral || ScreenIllumination.white => Colors.white,
  };
}

class _FaceGuidePainter extends CustomPainter {
  const _FaceGuidePainter({
    required this.illuminated,
    required this.screenIllumination,
  });

  final bool illuminated;
  final ScreenIllumination screenIllumination;

  Rect _guideRect(Size size) {
    final width = size.width * 0.78;
    final height = math.min(width / 0.78, size.height * 0.74);
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: width,
      height: height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final guide = _guideRect(size);
    final perimeterColor = resolveLivenessPerimeterColor(
      illuminated: illuminated,
      screenIllumination: screenIllumination,
    );
    if (perimeterColor != null) {
      final perimeter = buildLivenessPerimeterPath(size, guide);
      canvas.drawPath(perimeter, Paint()..color = perimeterColor);
    }
    canvas.drawOval(
      guide,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = faceGuideOutlineWidth,
    );
  }

  @override
  bool shouldRepaint(covariant _FaceGuidePainter oldDelegate) =>
      oldDelegate.illuminated != illuminated ||
      oldDelegate.screenIllumination != screenIllumination;
}

class _DebugDiagnosticCard extends StatelessWidget {
  const _DebugDiagnosticCard({
    required this.diagnostic,
    required this.activeOperation,
    required this.flowStage,
    required this.lastError,
    required this.quality,
    required this.mediaPipe,
    required this.headTurnDiagnostic,
  });

  final CameraDiagnosticSnapshot? diagnostic;
  final CameraProcessingStage activeOperation;
  final SecureLivenessStage flowStage;
  final CameraScanDebugRecord? lastError;
  final CaptureQuality? quality;
  final MediaPipeObservation? mediaPipe;
  final HeadTurnDiagnostic? headTurnDiagnostic;

  @override
  Widget build(BuildContext context) {
    final snapshot = diagnostic;
    final score = snapshot?.highestDebugConfidence;
    final error = lastError;
    final head = headTurnDiagnostic;
    return Card(
      color: Colors.black.withValues(alpha: 0.65),
      child: ExpansionTile(
        key: const Key('debug_diagnostic_panel'),
        dense: true,
        collapsedIconColor: Colors.white,
        iconColor: Colors.white,
        title: Text(
          'State ${flowStage.name} | ${activeOperation.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        subtitle: Text(
          error == null
              ? 'Last error: none'
              : 'Last error: ${error.failure.kind.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          Text(
            snapshot == null
                ? 'Waiting for the first processed frame.'
                : 'Debug candidates ${snapshot.debugCandidateCount} | '
                      'max ${score == null ? 'none' : score.toStringAsFixed(4)}\n'
                      'raw ${snapshot.rawWidth}x${snapshot.rawHeight} | '
                      'upright ${snapshot.uprightWidth}x${snapshot.uprightHeight} | '
                      'rotation ${snapshot.appliedRotation} deg\n'
                      'preview mirror ${snapshot.previewMirrored} | '
                      'analysis mirror ${snapshot.analysisMirrored}\n'
                      '${snapshot.sourceFormat} -> ${snapshot.channelOrder} | '
                      '${snapshot.rejectionReason}'
                      '${quality == null ? '' : '\nquality ${quality!.state.name} | '
                                'Y ${quality!.meanLuminance.toStringAsFixed(1)} | '
                                'dark ${(quality!.underexposedProportion * 100).toStringAsFixed(1)}% | '
                                'glare ${(quality!.overexposedProportion * 100).toStringAsFixed(1)}% | '
                                'contrast ${quality!.contrast.toStringAsFixed(1)} | '
                                'focus ${quality!.focusVariance.toStringAsFixed(1)}'}'
                      '${mediaPipe == null ? '' : '\nMediaPipe faces ${mediaPipe!.faceCount} | '
                                'landmarks ${mediaPipe!.landmarkCount} | '
                                'yaw ${mediaPipe!.yawDegrees?.toStringAsFixed(1) ?? 'none'} | '
                                '${mediaPipe!.inferenceMs} ms'}'
                      '${head == null ? '' : '\nhead ${head.direction.name} | '
                                'baseline ${head.baselineYaw.toStringAsFixed(1)} | '
                                'current ${head.currentYaw.toStringAsFixed(1)} | '
                                'delta ${head.yawDelta.toStringAsFixed(1)}\n'
                                'turn ${head.turnFrames}/${head.requiredTurnFrames} | '
                                'return ${head.returnFrames}/${head.requiredReturnFrames} | '
                                'target ${head.requiredYawDelta.toStringAsFixed(1)}'}'
                      '${error == null ? '' : '\n${error.failure.exceptionType}: ${error.failure.sanitizedMessage}'}',
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
