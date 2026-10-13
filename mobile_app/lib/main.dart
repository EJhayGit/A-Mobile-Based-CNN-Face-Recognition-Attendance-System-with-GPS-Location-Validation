import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/biometric_testing.dart';
import 'src/biometric_testing_screen.dart';
import 'src/camera_flow.dart';
import 'src/camera_scan_screen.dart';
import 'src/app_config.dart';
import 'src/domain.dart';
import 'src/driver_app_views.dart';
import 'src/face_pipeline.dart';
import 'src/location.dart';
import 'src/map_launcher.dart';
import 'src/network_status.dart';
import 'src/queue.dart';
import 'src/storage.dart';

const fleetNavy = Color(0xff202637);
const fleetNavyDeep = Color(0xff151b29);
const fleetBlue = Color(0xff2878f0);
const fleetBackground = Color(0xffeef2f7);
const fleetDarkBackground = Color(0xff0f1420);
const fleetSuccess = Color(0xff20a66a);
const fleetWarning = Color(0xffe8a91f);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const AttendanceApp());
}

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AGILA',
    debugShowCheckedModeBanner: false,
    theme: _fleetTheme(Brightness.light),
    darkTheme: _fleetTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: const AttendanceScreen(),
  );
}

ThemeData _fleetTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: fleetBlue,
    brightness: brightness,
    surface: dark ? const Color(0xff171e2d) : Colors.white,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: dark ? fleetDarkBackground : fleetBackground,
    fontFamily: 'Montserrat',
    appBarTheme: const AppBarTheme(
      backgroundColor: fleetNavy,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .75)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xff1d2637) : const Color(0xfff6f8fb),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: fleetBlue,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: dark ? const Color(0xff171e2d) : Colors.white,
      indicatorColor: fleetBlue.withValues(alpha: .14),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected)
              ? fleetBlue
              : scheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w800
              : FontWeight.w600,
        ),
      ),
    ),
  );
}

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen>
    with WidgetsBindingObserver {
  final _storage = SecureAttendanceStorage();
  final _pipeline = FacePipeline();
  final _location = DeviceLocationService();
  final _mapLauncher = const DestinationMapLauncher();
  final _networkStatus = NetworkStatusRuntime();
  final _endpoint = TextEditingController();
  final _employeeId = TextEditingController();
  final _password = TextEditingController();
  final _activationCode = TextEditingController();
  final _confirmation = TextEditingController();
  late final AttendanceQueue _queue = AttendanceQueue(_storage);

  DriverIdentity? _driver;
  AuthorizedSite? _site;
  DriverAssignment? _assignment;
  List<AttendanceAttempt> _pendingAttempts = const [];
  String _message = '';
  bool _registered = false;
  bool _pipelineReady = false;
  bool _loading = true;
  bool _busy = false;
  bool _syncing = false;
  bool _offline = false;
  bool _debugMode = false;
  String _faceReregistrationStatus = 'none';
  String _deviceAuthorizationStatus = 'unbound';
  bool? _networkAvailable;
  DateTime? _lastSyncedAt;
  StreamSubscription<bool>? _networkSubscription;
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _networkSubscription = _networkStatus.changes.listen(
      _handleNetworkStatus,
      onError: (_) {},
    );
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _pipeline.initialize();
      _pipelineReady = true;
    } catch (_) {
      _message = 'Camera check-in is temporarily unavailable.';
    }
    final endpoint = await _storage.readEndpoint();
    final cachedDriver = await _storage.readDriverProfile();
    final cachedAssignment = await _storage.readDriverAssignment();
    final refreshToken = await _storage.readRefreshToken();
    _debugMode = AppConfig.debugModeEnabled(await _storage.readDebugMode());
    _lastSyncedAt = await _storage.readLastSyncedAt();
    _pendingAttempts = await _storage.readQueue();
    if (cachedAssignment != null) {
      _assignment = DriverAssignment.fromJson(cachedAssignment);
      final cachedIdentity = cachedDriver == null
          ? null
          : DriverIdentity.fromJson(cachedDriver);
      if (cachedIdentity != null) {
        _assignment = _assignment!.applyPendingAttendance(
          _pendingAttempts,
          driverId: cachedIdentity.id,
        );
        await _storage.saveDriverAssignment(_assignment!.toJson());
      }
    }
    _site = _assignment?.isActive == true
        ? _assignment!.site
        : await _storage.readSite();
    final configuredEndpoint = endpoint ?? AppConfig.apiBaseUrl.trim();
    if (configuredEndpoint.isNotEmpty) _endpoint.text = configuredEndpoint;

    if (endpoint != null && cachedDriver != null && refreshToken != null) {
      _driver = DriverIdentity.fromJson(cachedDriver);
      _deviceAuthorizationStatus =
          cachedDriver['device_authorization_status'] as String? ?? 'unbound';
      _registered = await _storage.readTemplate(_driver!.id) != null;
    }
    if (endpoint != null && refreshToken != null && _driver != null) {
      try {
        final client = DriverBackendClient(AppConfig.backendUri(endpoint));
        final session = await client.refresh(refreshToken, _driver!.employeeId);
        await _saveSession(client, session);
      } on SocketException {
        _offline = true;
        _message = _site == null
            ? 'Offline. Connect to refresh your Site Assignment.'
            : 'Offline mode. Your saved Site Assignment remains available.';
      } on BackendRequestException catch (error) {
        if (error.statusCode != 401) {
          _message = 'Could not refresh the account. Please try again.';
        } else {
          await _storage.clearBackendSession();
          _driver = null;
          _registered = false;
          _deviceAuthorizationStatus = 'unbound';
          _site = null;
          _assignment = null;
          _message = 'Your session expired. Please sign in again.';
        }
      } catch (_) {
        await _storage.clearBackendSession();
        _driver = null;
        _registered = false;
        _deviceAuthorizationStatus = 'unbound';
        _site = null;
        _assignment = null;
        _message = 'Your session expired. Please sign in again.';
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
    if (_driver != null) unawaited(_synchronizeInBackground());
  }

  void _handleNetworkStatus(bool available) {
    final previous = _networkAvailable;
    _networkAvailable = available;
    if (!available) {
      if (mounted) setState(() => _offline = true);
      return;
    }
    if (previous == false && !_loading && _driver != null) {
      unawaited(_synchronizeInBackground());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading && _driver != null) {
      unawaited(_synchronizeInBackground());
    }
  }

  Uri _backendUri() {
    return AppConfig.backendUri(_endpoint.text);
  }

  Future<void> _saveSession(
    DriverBackendClient client,
    DriverSession session,
  ) async {
    await _storage.saveEndpoint(client.endpoint.toString());
    await _storage.saveBackendTokens(
      session.tokens.accessToken,
      session.tokens.refreshToken,
    );
    final profile = await client.profile(session.tokens.accessToken);
    _pendingAttempts = await _storage.readQueue();
    final assignment = profile.assignment?.applyPendingAttendance(
      _pendingAttempts,
      driverId: profile.driver.id,
    );
    final assignedSite = assignment?.isActive == true ? assignment!.site : null;
    if (assignedSite == null) {
      await _storage.clearSite();
    } else {
      await _storage.saveSite(assignedSite);
    }
    if (assignment == null) {
      await _storage.clearDriverAssignment();
    } else {
      await _storage.saveDriverAssignment(assignment.toJson());
    }
    _driver = profile.driver;
    _site = assignedSite;
    _assignment = assignment;
    _faceReregistrationStatus = profile.faceReregistrationStatus;
    _deviceAuthorizationStatus = profile.deviceAuthorizationStatus;
    final pendingConsumption = await _storage
        .readPendingFaceApprovalConsumption();
    if (pendingConsumption == profile.driver.id) {
      if (_faceReregistrationStatus == 'approved') {
        _faceReregistrationStatus = await client
            .consumeFaceReregistrationApproval(session.tokens.accessToken);
      }
      if (_faceReregistrationStatus == 'consumed') {
        await _storage.clearPendingFaceApprovalConsumption();
      }
    }
    _registered = await _storage.readTemplate(profile.driver.id) != null;
    if (_registered && _deviceAuthorizationStatus == 'enrollment_required') {
      final pendingDeviceEnrollment = await _storage
          .readPendingDeviceEnrollmentCompletion();
      if (pendingDeviceEnrollment == profile.driver.id) {
        try {
          await client.completeDeviceEnrollment(session.tokens.accessToken);
          await _storage.clearPendingDeviceEnrollmentCompletion();
          _deviceAuthorizationStatus = 'ready';
        } on Object {
          // Keep the local completion marker and retry after connectivity returns.
        }
      } else {
        await _storage.deleteTemplate(profile.driver.id);
        _registered = false;
      }
    } else if (_deviceAuthorizationStatus == 'ready') {
      await _storage.clearPendingDeviceEnrollmentCompletion();
    }
    await _storage.saveDriverProfile(
      id: profile.driver.id,
      employeeId: profile.driver.employeeId,
      fullName: profile.driver.fullName,
      deviceAuthorizationStatus: _deviceAuthorizationStatus,
    );
  }

  Future<void> _authenticate({required bool activation}) async {
    await _run(() async {
      final employeeId = _employeeId.text.trim();
      final password = _password.text;
      if (employeeId.isEmpty || password.isEmpty) {
        throw const FormatException('Enter your employee ID and password.');
      }
      if (activation && password != _confirmation.text) {
        throw const FormatException('Passwords do not match.');
      }
      final client = DriverBackendClient(_backendUri());
      final session = activation
          ? await client.activate(
              employeeId,
              _activationCode.text.trim(),
              password,
            )
          : await client.login(employeeId, password);
      await _saveSession(client, session);
      _password.clear();
      _activationCode.clear();
      _confirmation.clear();
      _message = _deviceAuthorizationStatus != 'ready'
          ? 'Signed in. Complete supervised face setup on this authorized device.'
          : _site == null
          ? 'Signed in. Ask your manager to assign a Site Assignment before check-in.'
          : 'Ready for check-in.';
    });
  }

  Future<void> _logout() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final endpoint = await _storage.readEndpoint();
      final accessToken = await _storage.readAccessToken();
      if (endpoint != null && accessToken != null) {
        try {
          await DriverBackendClient(
            AppConfig.backendUri(endpoint),
          ).logout(accessToken);
        } catch (_) {
          // Local sign-out must still succeed when the server is unreachable.
        }
      }
      await _storage.clearBackendSession();
      _driver = null;
      _registered = false;
      _deviceAuthorizationStatus = 'unbound';
      _site = null;
      _assignment = null;
      _selectedTab = 0;
      _message = 'Signed out securely.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openRegistration({bool reRegistration = false}) async {
    if (!_pipelineReady || _busy) return;
    final driver = _driver;
    if (driver == null) return;
    if (reRegistration && _faceReregistrationStatus != 'approved') {
      setState(
        () => _message =
            'Fleet Manager approval is required before re-registration.',
      );
      return;
    }
    if (!reRegistration &&
        _deviceAuthorizationStatus != 'enrollment_required') {
      setState(
        () => _message =
            'Face setup on this device requires Fleet Manager authorization.',
      );
      return;
    }
    final result = await Navigator.of(context).push<CameraScanResult>(
      MaterialPageRoute(
        builder: (_) => CameraScanScreen(
          purpose: ScanPurpose.registration,
          pipeline: _pipeline,
          storage: _storage,
          queue: _queue,
          location: _location,
          driverId: driver.id,
          debugMode: _debugMode,
        ),
      ),
    );
    if (reRegistration && result?.success == true) {
      final endpoint = await _storage.readEndpoint();
      final accessToken = await _storage.readAccessToken();
      if (endpoint != null && accessToken != null) {
        try {
          _faceReregistrationStatus = await DriverBackendClient(
            AppConfig.backendUri(endpoint),
          ).consumeFaceReregistrationApproval(accessToken);
          await _storage.clearPendingFaceApprovalConsumption();
        } on Object {
          _faceReregistrationStatus = 'consumed';
          await _storage.savePendingFaceApprovalConsumption(driver.id);
          if (mounted) {
            setState(
              () => _message =
                  'Face re-registration completed. Approval cleanup will retry when connected.',
            );
          }
          return;
        }
      }
    }
    if (!reRegistration && result?.success == true) {
      final endpoint = await _storage.readEndpoint();
      final accessToken = await _storage.readAccessToken();
      if (endpoint != null && accessToken != null) {
        await _storage.savePendingDeviceEnrollmentCompletion(driver.id);
        try {
          await DriverBackendClient(
            AppConfig.backendUri(endpoint),
          ).completeDeviceEnrollment(accessToken);
          await _storage.clearPendingDeviceEnrollmentCompletion();
          _deviceAuthorizationStatus = 'ready';
        } on Object {
          _deviceAuthorizationStatus = 'enrollment_required';
          if (mounted) {
            setState(
              () => _message =
                  'Face saved. Connect to confirm this device before attendance.',
            );
          }
          return;
        }
      }
    }
    await _refreshLocalState(result?.message);
  }

  Future<void> _requestDeviceReplacement() async {
    await _run(() async {
      final employeeId = _employeeId.text.trim();
      final password = _password.text;
      if (employeeId.isEmpty || password.isEmpty) {
        throw const FormatException(
          'Enter your employee ID and password before requesting a new device.',
        );
      }
      final status = await DriverBackendClient(
        _backendUri(),
      ).requestDeviceReplacement(employeeId, password);
      _message = status == 'pending'
          ? 'Device request sent. Ask your Fleet Manager to verify and approve this phone.'
          : 'Device request status: $status.';
    });
  }

  Future<void> _requestFaceReregistration() async {
    await _run(() async {
      final endpoint = await _storage.readEndpoint();
      final accessToken = await _storage.readAccessToken();
      if (endpoint == null || accessToken == null) {
        throw const FormatException('Connect and sign in to request approval.');
      }
      _faceReregistrationStatus = await DriverBackendClient(
        AppConfig.backendUri(endpoint),
      ).requestFaceReregistration(accessToken);
      _message = 'Waiting for Fleet Manager approval.';
    });
  }

  Future<void> _openAttendance() async {
    if (!_pipelineReady || _busy) return;
    final driver = _driver;
    if (driver == null) return;
    if (_deviceAuthorizationStatus != 'ready') {
      setState(
        () => _message =
            'Complete the authorized face setup on this device before attendance.',
      );
      return;
    }
    final template = await _storage.readTemplate(driver.id);
    if (template == null) {
      setState(
        () => _message = 'Complete face setup before your first check-in.',
      );
      return;
    }
    final assignment = _assignment;
    final site = assignment?.isActive == true ? assignment!.site : null;
    if (assignment == null || site == null) {
      setState(
        () => _message = assignment?.isPendingSynchronization == true
            ? 'This Site Assignment is submitted and waiting to sync.'
            : 'No active Site Assignment is assigned yet.',
      );
      return;
    }
    final currentStop = assignment.currentStop;
    if (await _queue.hasPendingSubmission(
      driverId: driver.id,
      assignmentId: assignment.id,
      routeStopId: currentStop?.id,
      siteId: site.id,
    )) {
      setState(
        () => _message =
            'Attendance for this Site Assignment is already saved and waiting to sync.',
      );
      return;
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<CameraScanResult>(
      MaterialPageRoute(
        builder: (_) => CameraScanScreen(
          purpose: ScanPurpose.attendance,
          pipeline: _pipeline,
          storage: _storage,
          queue: _queue,
          location: _location,
          driverId: driver.id,
          assignmentId: assignment.id,
          routeStopId: currentStop?.id,
          enrollmentTemplate: template,
          authorizedSite: site,
          debugMode: _debugMode,
        ),
      ),
    );
    await _refreshLocalState(result?.message);
    if (result?.success == true) {
      final synchronized = await _synchronizeCore(announce: false);
      if (mounted) {
        setState(() {
          _message = synchronized && _pendingAttempts.isEmpty
              ? 'Attendance recorded.'
              : 'Attendance saved offline. It will sync when internet is available.';
        });
      }
    }
  }

  Future<void> _synchronize() async {
    await _run(() async {
      await _synchronizeCore(announce: true);
    });
  }

  Future<void> _synchronizeInBackground() async {
    await _synchronizeCore(announce: false);
  }

  Future<bool> _synchronizeCore({required bool announce}) async {
    if (_syncing || _driver == null) return false;
    _syncing = true;
    if (mounted) setState(() {});
    try {
      final endpoint = await _storage.readEndpoint();
      final refreshToken = await _storage.readRefreshToken();
      if (endpoint == null || refreshToken == null) {
        if (announce) throw const FormatException('Please sign in again.');
        return false;
      }
      final client = DriverBackendClient(AppConfig.backendUri(endpoint));
      final session = await client.refresh(refreshToken, _driver!.employeeId);
      await _saveSession(client, session);
      final uploaded = await _queue.synchronize(
        HttpAttendanceGateway(client.endpoint, session.tokens.accessToken),
      );
      await _saveSession(client, session);
      _pendingAttempts = await _storage.readQueue();
      _offline = false;
      _lastSyncedAt = DateTime.now();
      await _storage.saveLastSyncedAt(_lastSyncedAt!);
      if (announce) {
        _message = uploaded > 0
            ? '$uploaded check-in record${uploaded == 1 ? '' : 's'} synchronized.'
            : _pendingAttempts.isEmpty
            ? 'Everything is up to date.'
            : '${_pendingAttempts.length} pending — will retry automatically.';
      }
      return true;
    } on SocketException {
      _offline = true;
      _pendingAttempts = await _storage.readQueue();
      if (announce) {
        _message = 'Offline. Saved check-ins will sync automatically.';
      }
      return false;
    } on HttpException {
      _offline = true;
      _pendingAttempts = await _storage.readQueue();
      if (announce) {
        _message = 'Offline. Saved check-ins will sync automatically.';
      }
      return false;
    } on BackendRequestException {
      if (announce) rethrow;
      return false;
    } catch (_) {
      if (announce) rethrow;
      return false;
    } finally {
      _syncing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _setDebugMode(bool enabled) async {
    if (!kDebugMode) return;
    setState(() => _debugMode = enabled);
    await _storage.saveDebugMode(enabled);
  }

  Future<void> _openBiometricTesting() async {
    if (!kDebugMode || !_debugMode || !_registered || _busy) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BiometricTestingScreen(
          store: _storage,
          onRunTrial: _runBiometricTrial,
        ),
      ),
    );
  }

  Future<BiometricTrialRecord?> _runBiometricTrial(
    BiometricTrialSetup setup,
  ) async {
    final driver = _driver;
    if (driver == null) return null;
    final template = await _storage.readTemplate(driver.id);
    if (template == null || !mounted) return null;
    final result = await Navigator.of(context).push<CameraScanResult>(
      MaterialPageRoute(
        builder: (_) => CameraScanScreen(
          purpose: ScanPurpose.attendance,
          pipeline: _pipeline,
          storage: _storage,
          queue: _queue,
          location: _location,
          driverId: driver.id,
          enrollmentTemplate: template,
          debugMode: true,
          biometricTrialSetup: setup,
        ),
      ),
    );
    return result?.biometricTrial;
  }

  Future<void> _openDirections() async {
    final assignment = _assignment;
    if (assignment == null) return;
    try {
      await _mapLauncher.open(
        latitude: assignment.site.latitude,
        longitude: assignment.site.longitude,
        label: assignment.locationName,
      );
    } on PlatformException {
      if (mounted) {
        setState(() => _message = 'Could not open directions on this device.');
      }
    }
  }

  Future<void> _refreshLocalState(String? message) async {
    final driver = _driver;
    _registered =
        driver != null && await _storage.readTemplate(driver.id) != null;
    _pendingAttempts = await _storage.readQueue();
    final assignment = _assignment;
    if (driver != null && assignment != null) {
      _assignment = assignment.applyPendingAttendance(
        _pendingAttempts,
        driverId: driver.id,
      );
      await _storage.saveDriverAssignment(_assignment!.toJson());
      if (_assignment!.isActive) {
        _site = _assignment!.site;
        await _storage.saveSite(_site!);
      } else {
        _site = null;
        await _storage.clearSite();
      }
    }
    if (message != null) _message = message;
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await action();
    } on BackendRequestException catch (error) {
      _message = error.statusCode == 401
          ? 'Those sign-in details were not accepted.'
          : error.message;
    } on SocketException {
      _message =
          'Cannot reach the server. Check your connection and try again.';
    } on FormatException catch (error) {
      _message = error.message;
    } catch (_) {
      _message = 'Something went wrong. Please try again.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const FleetLoadingView();
    }
    if (_driver == null) {
      return AuthView(
        busy: _busy,
        message: _message,
        endpointController: _endpoint,
        employeeIdController: _employeeId,
        passwordController: _password,
        activationCodeController: _activationCode,
        confirmationController: _confirmation,
        onLogin: () => _authenticate(activation: false),
        onActivate: () => _authenticate(activation: true),
        onRequestDeviceReplacement: _requestDeviceReplacement,
      );
    }
    return DriverShellView(
      driver: _driver!,
      assignment: _assignment,
      registered: _registered,
      faceReregistrationStatus: _faceReregistrationStatus,
      pendingAttempts: _pendingAttempts,
      busy: _busy || _syncing,
      cameraReady: _pipelineReady,
      offline: _offline,
      lastSyncedAt: _lastSyncedAt,
      debugMode: _debugMode,
      message: _message,
      selectedIndex: _selectedTab,
      onDestinationSelected: (index) => setState(() => _selectedTab = index),
      onCheckIn: _openAttendance,
      onRegister: () => _openRegistration(),
      onRequestFaceReregistration: _requestFaceReregistration,
      onReregister: () => _openRegistration(reRegistration: true),
      onSynchronize: _synchronize,
      onRefresh: _synchronize,
      onDebugModeChanged: _setDebugMode,
      onOpenBiometricTesting: _openBiometricTesting,
      onOpenDirections: _openDirections,
      onLogout: _logout,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_networkSubscription?.cancel());
    _pipeline.dispose();
    _endpoint.dispose();
    _employeeId.dispose();
    _password.dispose();
    _activationCode.dispose();
    _confirmation.dispose();
    super.dispose();
  }
}
