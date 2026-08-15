import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  testWidgets('sign-in view exposes activation without developer diagnostics', (
    tester,
  ) async {
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
        ),
      ),
    );

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.byKey(const Key('sign_in')), findsOneWidget);
    expect(find.textContaining('YuNet'), findsNothing);
    expect(find.textContaining('threshold'), findsNothing);
    expect(find.textContaining('Supabase'), findsNothing);

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

    expect(find.text('CHECK IN'), findsOneWidget);
    expect(find.text('North Distribution Hub'), findsOneWidget);
    expect(find.text('Assigned'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('2 check-ins waiting to sync'), findsOneWidget);
    expect(find.textContaining('confidence'), findsNothing);
    expect(find.textContaining('Detector'), findsNothing);
    expect(find.textContaining('queue ID'), findsNothing);
  });

  testWidgets(
    'driver shell provides focused home, activity, and profile navigation',
    (tester) async {
      var selectedIndex = 0;
      bool? debugModeChanged;
      await tester.pumpWidget(
        MaterialApp(
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
              onOpenDirections: () {},
              onLogout: () {},
            ),
          ),
        ),
      );

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('Profile'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav_profile')));
      await tester.pumpAndSettle();
      expect(find.text('Account and device readiness'), findsOneWidget);
      await tester.drag(
        find.byType(CustomScrollView).last,
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('logout')), findsOneWidget);
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
    expect(find.text('Pending'), findsOneWidget);
    expect(find.textContaining('private-'), findsNothing);
    expect(find.textContaining('0.9'), findsNothing);
    expect(find.textContaining('14.5'), findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(refreshCount, 1);
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

    expect(find.text('Delivered'), findsOneWidget);
    expect(find.text('Latest delivery'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('check_in'))).onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('open_directions')));
    expect(opened, isTrue);
  });
}
