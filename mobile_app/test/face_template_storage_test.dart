import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/domain.dart';
import 'package:offline_trucking_attendance/src/storage.dart';

List<double> embedding(int index) {
  final values = List<double>.filled(embeddingLength, 0);
  values[index] = 1;
  return values;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('each authenticated Driver reads only their own template', () async {
    final storage = SecureAttendanceStorage();
    await storage.saveTemplate('driver-a', embedding(0));
    await storage.saveTemplate('driver-b', embedding(1));

    expect(await storage.readTemplate('driver-a'), embedding(0));
    expect(await storage.readTemplate('driver-b'), embedding(1));
    expect(await storage.readTemplate('driver-c'), isNull);
  });

  test('successful re-registration replaces only that Driver template', () async {
    final storage = SecureAttendanceStorage();
    await storage.saveTemplate('driver-a', embedding(0));
    await storage.saveTemplate('driver-b', embedding(1));

    // Until enrollment completes and calls saveTemplate, the old value remains.
    expect(await storage.readTemplate('driver-a'), embedding(0));

    await storage.saveTemplate('driver-a', embedding(2));

    expect(await storage.readTemplate('driver-a'), embedding(2));
    expect(await storage.readTemplate('driver-b'), embedding(1));
  });

  test('logout does not expose the previous Driver template', () async {
    final storage = SecureAttendanceStorage();
    await storage.saveTemplate('driver-a', embedding(0));
    await storage.saveBackendTokens('access', 'refresh');
    await storage.saveDriverProfile(
      id: 'driver-a',
      employeeId: 'A-001',
      fullName: 'Driver A',
      deviceAuthorizationStatus: 'ready',
    );

    await storage.clearBackendSession();

    expect(await storage.readTemplate('driver-b'), isNull);
    expect(await storage.readTemplate('driver-a'), embedding(0));
  });

  test(
    'a stale template can be removed for a newly authorized device',
    () async {
      final storage = SecureAttendanceStorage();
      await storage.saveTemplate('driver-a', embedding(0));
      await storage.saveTemplate('driver-b', embedding(1));

      await storage.deleteTemplate('driver-a');

      expect(await storage.readTemplate('driver-a'), isNull);
      expect(await storage.readTemplate('driver-b'), embedding(1));
    },
  );

  test('legacy device-wide template is never accepted', () async {
    FlutterSecureStorage.setMockInitialValues({
      'face_embedding_template_merlens_v2': '[1, 0, 0]',
    });
    final storage = SecureAttendanceStorage();

    expect(await storage.readTemplate('driver-a'), isNull);
  });

  test(
    'approval consumption retry marker is Driver-bound and clearable',
    () async {
      final storage = SecureAttendanceStorage();
      await storage.savePendingFaceApprovalConsumption('driver-a');

      expect(await storage.readPendingFaceApprovalConsumption(), 'driver-a');

      await storage.clearPendingFaceApprovalConsumption();
      expect(await storage.readPendingFaceApprovalConsumption(), isNull);
    },
  );

  test(
    'device enrollment completion marker is Driver-bound and clearable',
    () async {
      final storage = SecureAttendanceStorage();
      await storage.savePendingDeviceEnrollmentCompletion('driver-a');

      expect(await storage.readPendingDeviceEnrollmentCompletion(), 'driver-a');

      await storage.clearPendingDeviceEnrollmentCompletion();
      expect(await storage.readPendingDeviceEnrollmentCompletion(), isNull);
    },
  );
}
