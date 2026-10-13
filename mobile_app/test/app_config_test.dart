import 'package:flutter_test/flutter_test.dart';
import 'package:offline_trucking_attendance/src/app_config.dart';

void main() {
  test('verified Render origin is the packaged default', () {
    expect(AppConfig.apiBaseUrl, 'https://agila-thesis.onrender.com');
  });

  test('development accepts explicit HTTP and HTTPS server origins', () {
    expect(
      AppConfig.backendUri('http://127.0.0.1:8080', releaseMode: false).host,
      '127.0.0.1',
    );
    expect(
      AppConfig.backendUri(
        'https://api.example.test',
        releaseMode: false,
      ).scheme,
      'https',
    );
  });

  test('release configuration requires HTTPS', () {
    expect(
      () => AppConfig.backendUri('http://api.example.test', releaseMode: true),
      throwsA(isA<FormatException>()),
    );
    expect(
      AppConfig.backendUri('https://api.example.test', releaseMode: true).host,
      'api.example.test',
    );
  });

  test('release configuration cannot restore persisted Debug Mode', () {
    expect(AppConfig.debugModeEnabled(true, releaseMode: true), isFalse);
    expect(AppConfig.debugModeEnabled(true, releaseMode: false), isTrue);
    expect(AppConfig.debugModeEnabled(false, releaseMode: false), isFalse);
  });

  test(
    'server address rejects credentials, query, and unsupported schemes',
    () {
      for (final value in [
        'ftp://api.example.test',
        'https://user:pass@api.example.test',
        'https://api.example.test/unexpected/path',
        'https://api.example.test?token=secret',
        'not-a-url',
      ]) {
        expect(
          () => AppConfig.backendUri(value, releaseMode: false),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );
}
