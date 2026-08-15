import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  const CameraScanResult({required this.success, required this.message});

  final bool success;
  final String message;
}

class CameraScanScreen extends StatefulWidget {
  const CameraScanScreen({
    super.key,
    required this.purpose,
    required this.pipeline,
    required this.storage,
    required this.queue,
    required this.location,
    this.enrollmentTemplate,
    this.authorizedSite,
    this.debugMode = false,
  });

  final ScanPurpose purpose;
  final FacePipeline pipeline;
  final SecureAttendanceStorage storage;
  final AttendanceQueue queue;
  final DeviceLocationService location;
  final List<double>? enrollmentTemplate;
  final AuthorizedSite? authorizedSite;
  final bool debugMode;

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
  final _sessionElapsed = Stopwatch();

  CameraController? _camera;
  CameraOrientation? _orientation;
  CameraDiagnosticSnapshot? _diagnostic;
  CaptureQuality? _quality;
  MediaPipeObservation? _mediaPipe;
  ColorResponseDiagnostic? _colorDiagnostic;
  HeadTurnDiagnostic? _headTurnDiagnostic;
  String _status = 'Initializing';
  double _progress = 0;
  bool _initializing = true;
  bool _stopping = false;
  bool _brightnessRaised = false;
  bool _lowLightIllumination = false;
  bool _showPhotosensitivityWarning = false;
  ChallengeScreenColor _screenColor = ChallengeScreenColor.neutral;
  int _lastEnrollmentResetToken = 0;
  int _lastLivenessTimestamp = -1;
  CameraScanResult? _result;
  CameraProcessingStage _activeOperation = CameraProcessingStage.idle;
  String _flowStateBeforeFailure = SecureLivenessStage.quality.name;
  String _lastSuccessfulTransition = 'session_start -> quality';
  CameraScanDebugRecord? _lastError;

  @override
  void initState() {
    super.initState();
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
      await widget.storage.saveTemplate(template);
      _flow.setCompletedMessage('Registration complete');
      await _finish(
        const CameraScanResult(success: true, message: 'Registration complete'),
      );
      return;
    }

    final before = _flow.stage;
    _flow.captureCompleted(DateTime.now());
    _recordTransition(before, _flow.stage);
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
    final score = cosineSimilarity(template, embedding);
    if (score < lockedCosineThreshold) {
      _flow.setCompletedMessage('Verification failed');
      await _finish(
        const CameraScanResult(success: false, message: 'Verification failed'),
      );
      return;
    }

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
        probe: embedding,
        site: site,
        latitude: reading.latitude,
        longitude: reading.longitude,
        accuracyMeters: reading.accuracyMeters,
      );
      if (!decision.accepted) {
        final message = switch (decision.reason) {
          'gps_accuracy_rejected' => 'GPS validation failed',
          'outside_authorized_site' => 'GPS validation failed',
          _ => 'Verification failed',
        };
        _flow.setCompletedMessage(message);
        await _finish(CameraScanResult(success: false, message: message));
        return;
      }
      await widget.queue.enqueue(
        AttendanceAttempt(
          clientAttemptId: _newAttemptId(),
          driverId: 'local-development-driver',
          siteId: site.id,
          capturedAtUtc: DateTime.now().toUtc(),
          latitude: reading.latitude,
          longitude: reading.longitude,
          gpsAccuracyMeters: reading.accuracyMeters,
          distanceMeters: decision.distanceMeters,
          faceScore: decision.faceScore,
        ),
      );
      _flow.setCompletedMessage('Saved offline — will sync automatically');
      await _finish(
        const CameraScanResult(
          success: true,
          message: 'Saved offline — will sync automatically.',
        ),
      );
    } catch (_) {
      _flow.setCompletedMessage('GPS validation failed');
      await _finish(
        const CameraScanResult(
          success: false,
          message: 'GPS validation failed',
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
    _activeOperation = update.showPhotosensitivityWarning
        ? CameraProcessingStage.colorResponse
        : CameraProcessingStage.livenessEvaluation;
    final colorDiagnostic = update.colorDiagnostic;
    final headTurnDiagnostic = update.headTurnDiagnostic;
    if (kDebugMode &&
        colorDiagnostic != null &&
        colorDiagnostic.sampledFrames != _colorDiagnostic?.sampledFrames) {
      debugPrint(
        'Color response ${colorDiagnostic.color.name}: '
        'samples ${colorDiagnostic.sampledFrames}/'
        '${colorDiagnostic.sampleWindowFrames}, matches '
        '${colorDiagnostic.matchingFrames}/'
        '${colorDiagnostic.requiredMatchingFrames}, best regions '
        '${colorDiagnostic.bestCoherentRegions}/'
        '${colorDiagnostic.requiredCoherentRegions}, target delta '
        '${colorDiagnostic.bestTargetDelta?.toStringAsFixed(2) ?? 'none'}, '
        'dominance ${colorDiagnostic.bestDominanceMargin?.toStringAsFixed(2) ?? 'none'}',
      );
    }
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
      _screenColor = update.screenColor;
      _lowLightIllumination = update.lowLightIllumination;
      _showPhotosensitivityWarning = update.showPhotosensitivityWarning;
      _colorDiagnostic = colorDiagnostic;
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
        _screenColor = ChallengeScreenColor.neutral;
        _lowLightIllumination = false;
        _showPhotosensitivityWarning = false;
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
    final visibleResult = !result.success && !widget.debugMode
        ? const CameraScanResult(
            success: false,
            message: 'Unable to verify. Please try again.',
          )
        : result;
    setState(() {
      _result = visibleResult;
      _status = visibleResult.message;
      _progress = 1;
    });
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
          : 'Unable to verify. Please try again.';
      _result = CameraScanResult(
        success: false,
        message: widget.debugMode
            ? failure.userMessage
            : 'Unable to verify. Please try again.',
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
      _colorDiagnostic = null;
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

  Future<void> _close() async {
    await _stopImageStreamSafely();
    await _releaseLivenessResources();
    if (mounted) Navigator.of(context).pop(_result);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        _result == null) {
      _flow.restart();
      _qualityAnalyzer.reset();
      _processingGate.reset();
      _lastLivenessTimestamp = -1;
      if (mounted) {
        setState(() {
          _screenColor = ChallengeScreenColor.neutral;
          _lowLightIllumination = false;
          _showPhotosensitivityWarning = false;
          _headTurnDiagnostic = null;
          _status = 'Liveness session paused; restart required';
          _result = const CameraScanResult(
            success: false,
            message: 'Liveness session paused; restart required',
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
    final colorIlluminationActive =
        _flow.stage == SecureLivenessStage.colorBaseline ||
        _flow.stage == SecureLivenessStage.colorChallenge;
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
            screenColor: _screenColor,
            colorBaselineActive:
                _flow.stage == SecureLivenessStage.colorBaseline,
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
                          widget.purpose == ScanPurpose.registration
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
                  if (widget.debugMode && !colorIlluminationActive)
                    _DebugDiagnosticCard(
                      diagnostic: _diagnostic,
                      activeOperation: _activeOperation,
                      flowStage: _flow.stage,
                      lastError: _lastError,
                      quality: _quality,
                      mediaPipe: _mediaPipe,
                      colorDiagnostic: _colorDiagnostic,
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
                          if (!colorIlluminationActive)
                            const Text(
                              'Challenge-response liveness engineering only',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white70),
                            ),
                          if (_showPhotosensitivityWarning) ...[
                            const SizedBox(height: 8),
                            const Text(
                              'Photosensitivity notice: the screen will change '
                              'colors slowly without flashing.',
                              key: Key('photosensitivity_warning'),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.amberAccent),
                            ),
                          ],
                          if (_result != null) ...[
                            const SizedBox(height: 12),
                            FilledButton(
                              key: const Key('done_scan'),
                              onPressed: _close,
                              child: Text(_result!.success ? 'Done' : 'Close'),
                            ),
                            if (!_result!.success)
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
    SecureLivenessStage.quality =>
      detailedGuidance.contains('Position') ||
              detailedGuidance.contains('face') ||
              detailedGuidance.contains('closer') ||
              detailedGuidance.contains('oval')
          ? 'Position your face inside the circle'
          : 'Hold still',
    SecureLivenessStage.headTurn =>
      detailedGuidance.toLowerCase().contains('right')
          ? 'Turn right'
          : 'Turn left',
    SecureLivenessStage.headReturn => 'Turn back to center',
    SecureLivenessStage.colorBaseline ||
    SecureLivenessStage.colorChallenge => 'Checking liveness',
    SecureLivenessStage.captureStabilizing ||
    SecureLivenessStage.captureCooldown => 'Hold still',
    SecureLivenessStage.processing =>
      purpose == ScanPurpose.attendance
          ? 'Verifying face'
          : 'Saving face setup',
    SecureLivenessStage.completed => detailedGuidance,
    SecureLivenessStage.timedOut ||
    SecureLivenessStage.failed => 'Unable to verify. Please try again.',
  };
}

class _FaceGuideOverlay extends StatelessWidget {
  const _FaceGuideOverlay({
    required this.illuminated,
    required this.screenColor,
    required this.colorBaselineActive,
  });

  final bool illuminated;
  final ChallengeScreenColor screenColor;
  final bool colorBaselineActive;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      key: const Key('face_guide_overlay'),
      painter: _FaceGuidePainter(
        illuminated: illuminated,
        screenColor: screenColor,
        colorBaselineActive: colorBaselineActive,
      ),
      child: const SizedBox.expand(key: Key('liveness_screen_color')),
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
  required ChallengeScreenColor screenColor,
  required bool colorBaselineActive,
}) {
  if (illuminated) return Colors.white;
  if (colorBaselineActive) return const Color(0xFF202020);
  return switch (screenColor) {
    ChallengeScreenColor.red => const Color(0xFFFF0000),
    ChallengeScreenColor.green => const Color(0xFF00FF00),
    ChallengeScreenColor.blue => const Color(0xFF0000FF),
    ChallengeScreenColor.neutral || ChallengeScreenColor.white => Colors.white,
  };
}

class _FaceGuidePainter extends CustomPainter {
  const _FaceGuidePainter({
    required this.illuminated,
    required this.screenColor,
    required this.colorBaselineActive,
  });

  final bool illuminated;
  final ChallengeScreenColor screenColor;
  final bool colorBaselineActive;

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
      screenColor: screenColor,
      colorBaselineActive: colorBaselineActive,
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
      oldDelegate.screenColor != screenColor ||
      oldDelegate.colorBaselineActive != colorBaselineActive;
}

class _DebugDiagnosticCard extends StatelessWidget {
  const _DebugDiagnosticCard({
    required this.diagnostic,
    required this.activeOperation,
    required this.flowStage,
    required this.lastError,
    required this.quality,
    required this.mediaPipe,
    required this.colorDiagnostic,
    required this.headTurnDiagnostic,
  });

  final CameraDiagnosticSnapshot? diagnostic;
  final CameraProcessingStage activeOperation;
  final SecureLivenessStage flowStage;
  final CameraScanDebugRecord? lastError;
  final CaptureQuality? quality;
  final MediaPipeObservation? mediaPipe;
  final ColorResponseDiagnostic? colorDiagnostic;
  final HeadTurnDiagnostic? headTurnDiagnostic;

  @override
  Widget build(BuildContext context) {
    final snapshot = diagnostic;
    final score = snapshot?.highestDebugConfidence;
    final error = lastError;
    final color = colorDiagnostic;
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
              ? color == null
                    ? 'Last error: none'
                    : 'Color ${color.color.name}: '
                          '${color.sampledFrames}/${color.sampleWindowFrames} samples, '
                          '${color.matchingFrames}/${color.requiredMatchingFrames} matches'
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
                      '${color == null ? '' : '\ncolor ${color.color.name} | '
                                'samples ${color.sampledFrames}/${color.sampleWindowFrames} | '
                                'matches ${color.matchingFrames}/${color.requiredMatchingFrames}\n'
                                'best regions ${color.bestCoherentRegions}/${color.requiredCoherentRegions} | '
                                'target delta ${color.bestTargetDelta?.toStringAsFixed(2) ?? 'none'} | '
                                'dominance ${color.bestDominanceMargin?.toStringAsFixed(2) ?? 'none'}'}'
                      '${error == null ? '' : '\n${error.failure.exceptionType}: ${error.failure.sanitizedMessage}'}',
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
