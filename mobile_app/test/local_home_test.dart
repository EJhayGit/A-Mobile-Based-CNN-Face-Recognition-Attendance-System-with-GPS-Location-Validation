import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/main.dart' show AttendanceApp;
import 'package:offline_trucking_attendance/src/domain.dart';
import 'package:offline_trucking_attendance/src/driver_app_views.dart';
import 'package:offline_trucking_attendance/src/queue.dart';

const driver = DriverIdentity(
  id: 'driver-id',
  employeeId: 'DRV-001',
  fullName: 'Demo Driver',
);

final assignment = DriverAssignment(
  id: 'assignment-id',
  status: 'assigned',
  locationName: 'North Distribution Hub',
  address: 'Quezon City',
  scheduledAt: DateTime(2026, 8, 11, 9),
  site: const AuthorizedSite(
    id: 'site-id',
    latitude: 14.5,
    longitude: 121,
    radiusMeters: 100,
  ),
);

final multiStopAssignment = DriverAssignment(
  id: 'multi-assignment-id',
  status: 'in_progress',
  routeName: 'North AM-01',
  locationName: 'Second Stop',
  address: 'Makati City',
  scheduledAt: DateTime(2026, 8, 11, 9),
  site: const AuthorizedSite(
    id: 'site-2',
    latitude: 14.5,
    longitude: 121,
    radiusMeters: 100,
  ),
  completedStopCount: 1,
  totalStopCount: 3,
  currentStopId: 'stop-2',
  stops: const [
    DriverRouteStop(
      id: 'stop-1',
      order: 1,
      state: 'completed',
      locationName: 'First Stop',
      address: 'Quezon City',
      site: AuthorizedSite(
        id: 'site-1',
        latitude: 14.6,
        longitude: 121.1,
        radiusMeters: 100,
      ),
    ),
    DriverRouteStop(
      id: 'stop-2',
      order: 2,
      state: 'current',
      locationName: 'Second Stop',
      address: 'Makati City',
      site: AuthorizedSite(
        id: 'site-2',
        latitude: 14.5,
        longitude: 121,
        radiusMeters: 100,
      ),
    ),
    DriverRouteStop(
      id: 'stop-3',
      order: 3,
      state: 'upcoming',
      locationName: 'Final Stop',
      address: 'Pasay City',
      site: AuthorizedSite(
        id: 'site-3',
        latitude: 14.4,
        longitude: 120.9,
        radiusMeters: 100,
      ),
    ),
  ],
);

void main() {
  testWidgets('application typography uses bundled Montserrat', (tester) async {
    late MaterialApp app;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          app = const AttendanceApp().build(context) as MaterialApp;
          return const SizedBox.shrink();
        },
      ),
    );

    expect(app.theme?.textTheme.bodyMedium?.fontFamily, 'Montserrat');
    expect(app.darkTheme?.textTheme.bodyMedium?.fontFamily, 'Montserrat');
  });

  testWidgets('sign-in view exposes activation without developer diagnostics', (
    tester,
  ) async {
    var replacementRequested = false;
    final controllers = List.generate(5, (_) => TextEditingController());
    addTearDown(() {
      for (final controller in controllers) {
        controller.dispose();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AuthView(
          busy: false,
          message: '',
          endpointController: controllers[0],
          employeeIdController: controllers[1],
          passwordController: controllers[2],
          activationCodeController: controllers[3],
          confirmationController: controllers[4],
          onLogin: () {},
          onActivate: () {},
          onRequestDeviceReplacement: () => replacementRequested = true,
        ),
      ),
    );

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.byKey(const Key('sign_in')), findsOneWidget);
    expect(find.textContaining('YuNet'), findsNothing);
    expect(find.textContaining('threshold'), findsNothing);
    expect(find.textContaining('Supabase'), findsNothing);
    expect(find.byKey(const Key('request_device_replacement')), findsOneWidget);
    tester
        .widget<OutlinedButton>(
          find.byKey(const Key('request_device_replacement')),
        )
        .onPressed!();
    expect(replacementRequested, isTrue);

    await tester.tap(find.byKey(const Key('toggle_activation')));
    await tester.pumpAndSettle();
    expect(find.text('Join your fleet'), findsOneWidget);
    expect(find.byKey(const Key('activation_code')), findsOneWidget);
    expect(find.byKey(const Key('confirm_password')), findsOneWidget);
    expect(find.byKey(const Key('activate_account')), findsOneWidget);
  });

  testWidgets('driver home prioritizes check-in and safe offline status', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DriverHomeView(
          driver: driver,
          assignment: assignment,
          registered: true,
          queueCount: 2,
          busy: false,
          cameraReady: true,
          message: 'Ready for check-in.',
          onCheckIn: () {},
          onRegister: () {},
          onSynchronize: () {},
          onRefresh: () async {},
          offline: false,
          lastSyncedAt: null,
          onOpenDirections: () {},
        ),
      ),
    );

    expect(find.text('FIELD PERSONNEL WORKSPACE'), findsOneWidget);
    expect(
      find.text(
        'Keep your attendance, site activity, and offline records in one place.',
      ),
      findsOneWidget,
    );
    expect(find.text('Field Personnel ID: DRV-001'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Latest Site Assignment'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Latest Site Assignment'), findsOneWidget);
    expect(find.text('North Distribution Hub'), findsNWidgets(2));
    expect(find.text('Assigned'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('CHECK IN'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('CHECK IN'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Site Location'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.scrollUntilVisible(
      find.text('2 check-ins waiting to sync'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('2 check-ins waiting to sync'), findsOneWidget);
    expect(find.textContaining('confidence'), findsNothing);
    expect(find.textContaining('Detector'), findsNothing);
    expect(find.textContaining('queue ID'), findsNothing);
  });

  testWidgets('driver home makes current stop and route progress obvious', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DriverHomeView(
          driver: driver,
          assignment: multiStopAssignment,
          registered: true,
          queueCount: 0,
          busy: false,
          cameraReady: true,
          message: '',
          onCheckIn: () {},
          onRegister: () {},
          onSynchronize: () {},
          onRefresh: () async {},
          offline: false,
          lastSyncedAt: null,
          onOpenDirections: () {},
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Latest Site Assignment'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Latest Site Assignment'), findsOneWidget);
    expect(find.text('North AM-01'), findsOneWidget);
    expect(find.text('Site 2 of 3 • Current'), findsOneWidget);
    expect(find.text('1 of 3 sites completed'), findsOneWidget);
    expect(find.text('First Stop'), findsOneWidget);
    expect(find.text('Second Stop'), findsNWidgets(2));
    expect(find.text('Final Stop'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Upcoming'), findsOneWidget);
  });

  testWidgets(
    'driver shell provides focused home, activity, and profile navigation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var selectedIndex = 0;
      bool? debugModeChanged;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Montserrat'),
          home: StatefulBuilder(
            builder: (context, setState) => DriverShellView(
              driver: driver,
              assignment: assignment,
              registered: true,
              pendingAttempts: const [],
              busy: false,
              cameraReady: true,
              message: '',
              selectedIndex: selectedIndex,
              onDestinationSelected: (index) =>
                  setState(() => selectedIndex = index),
              onCheckIn: () {},
              onRegister: () {},
              onSynchronize: () {},
              onRefresh: () async {},
              offline: false,
              lastSyncedAt: null,
              debugMode: false,
              onDebugModeChanged: (value) => debugModeChanged = value,
              onOpenBiometricTesting: () {},
              onOpenDirections: () {},
              onLogout: () {},
            ),
          ),
        ),
      );

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('Profile'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('nav_profile')));
      await tester.pumpAndSettle();
      expect(find.text('Account and device readiness'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('logout')),
        240,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.byKey(const Key('logout')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('debug_mode')));
      await tester.pump();
      expect(debugModeChanged, isTrue);
    },
  );

  testWidgets('activity shows only privacy-safe pending attendance details', (
    tester,
  ) async {
    var refreshCount = 0;
    final pending = AttendanceAttempt(
      clientAttemptId: 'private-attempt-id',
      driverId: 'private-driver-id',
      siteId: 'private-site-id',
      capturedAtUtc: DateTime.utc(2026, 8, 11, 1),
      latitude: 14.5,
      longitude: 121,
      gpsAccuracyMeters: 5,
      distanceMeters: 2,
      faceScore: .9,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DriverActivityView(
          attempts: [pending],
          busy: false,
          onSynchronize: () {},
          onRefresh: () async => refreshCount++,
        ),
      ),
    );

    expect(find.text('Check-in saved'), findsOneWidget);
    expect(find.text('Submitted'), findsOneWidget);
    expect(find.textContaining('private-'), findsNothing);
    expect(find.textContaining('0.9'), findsNothing);
    expect(find.textContaining('14.5'), findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(refreshCount, 1);
  });

  testWidgets('biometric testing entry is gated by Debug Mode', (tester) async {
    Future<void> pumpProfile(bool debugMode) => tester.pumpWidget(
      MaterialApp(
        home: DriverProfileView(
          driver: driver,
          registered: true,
          assignmentReady: true,
          queueCount: 0,
          busy: false,
          cameraReady: true,
          onRegister: () {},
          onSynchronize: () {},
          onRefresh: () async {},
          offline: false,
          lastSyncedAt: null,
          debugMode: debugMode,
          onDebugModeChanged: (_) {},
          onOpenBiometricTesting: () {},
          onLogout: () {},
        ),
      ),
    );

    await pumpProfile(false);
    expect(find.byKey(const Key('open_biometric_testing')), findsNothing);
    await pumpProfile(true);
    expect(find.byKey(const Key('open_biometric_testing')), findsOneWidget);
  });

  testWidgets('face re-registration requires confirmation', (tester) async {
    var registrationCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DriverProfileView(
          driver: driver,
          registered: true,
          faceReregistrationStatus: 'approved',
          assignmentReady: true,
          queueCount: 0,
          busy: false,
          cameraReady: true,
          onRegister: () {},
          onReregister: () => registrationCount++,
          onSynchronize: () {},
          onRefresh: () async {},
          offline: false,
          lastSyncedAt: null,
          debugMode: false,
          onDebugModeChanged: (_) {},
          onOpenBiometricTesting: () {},
          onLogout: () {},
        ),
      ),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile_reregister_face')));
    await tester.pumpAndSettle();
    expect(find.text('Re-register face?'), findsOneWidget);
    expect(registrationCount, 0);

    await tester.tap(find.byKey(const Key('cancel_face_reregistration')));
    await tester.pumpAndSettle();
    expect(registrationCount, 0);

    await tester.tap(find.byKey(const Key('profile_reregister_face')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_face_reregistration')));
    await tester.pumpAndSettle();
    expect(registrationCount, 1);
  });

  testWidgets('face re-registration cannot start before approval', (
    tester,
  ) async {
    var requestCount = 0;
    var registrationCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DriverProfileView(
          driver: driver,
          registered: true,
          assignmentReady: true,
          queueCount: 0,
          busy: false,
          cameraReady: true,
          onRegister: () {},
          onRequestFaceReregistration: () => requestCount++,
          onReregister: () => registrationCount++,
          onSynchronize: () {},
          onRefresh: () async {},
          offline: false,
          lastSyncedAt: null,
          debugMode: false,
          onDebugModeChanged: (_) {},
          onOpenBiometricTesting: () {},
          onLogout: () {},
        ),
      ),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('Request re-registration'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile_reregister_face')));
    await tester.pumpAndSettle();
    expect(requestCount, 1);
    expect(registrationCount, 0);
    expect(find.text('Re-register face?'), findsNothing);
  });

  testWidgets('destination directions and delivered status are clear', (
    tester,
  ) async {
    var opened = false;
    final delivered = DriverAssignment(
      id: assignment.id,
      status: 'completed',
      locationName: assignment.locationName,
      address: assignment.address,
      scheduledAt: assignment.scheduledAt,
      site: assignment.site,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DriverHomeView(
          driver: driver,
          assignment: delivered,
          registered: true,
          queueCount: 0,
          busy: false,
          cameraReady: true,
          message: '',
          onCheckIn: () {},
          onRegister: () {},
          onSynchronize: () {},
          onRefresh: () async {},
          offline: false,
          lastSyncedAt: null,
          onOpenDirections: () => opened = true,
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Latest Site Assignment'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Completed'), findsNWidgets(2));
    expect(find.text('Latest Site Assignment'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open_directions')));
    expect(opened, isTrue);
    await tester.scrollUntilVisible(
      find.byKey(const Key('check_in')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('check_in'))).onPressed,
      isNull,
    );
  });

  testWidgets('latest assignment remains within a narrow phone viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Montserrat'),
        home: DriverHomeView(
          driver: driver,
          assignment: multiStopAssignment,
          registered: true,
          queueCount: 2,
          busy: false,
          cameraReady: true,
          message: 'Ready for check-in.',
          onCheckIn: () {},
          onRegister: () {},
          onSynchronize: () {},
          onRefresh: () async {},
          offline: false,
          lastSyncedAt: null,
          onOpenDirections: () {},
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Latest Site Assignment'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final titleRect = tester.getRect(find.text('Latest Site Assignment'));
    final badgeRect = tester.getRect(find.text('In progress'));
    expect(titleRect.left, greaterThanOrEqualTo(0));
    expect(titleRect.right, lessThanOrEqualTo(320));
    expect(badgeRect.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.byKey(const Key('synchronize')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
