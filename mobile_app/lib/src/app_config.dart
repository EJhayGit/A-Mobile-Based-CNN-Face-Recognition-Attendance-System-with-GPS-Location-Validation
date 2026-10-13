import 'package:flutter/foundation.dart';

class AppConfig {
  const AppConfig._();

  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://agila-thesis.onrender.com',
  );

  static bool debugModeEnabled(
    bool storedValue, {
    bool releaseMode = kReleaseMode,
  }) => !releaseMode && storedValue;

  static Uri backendUri(String value, {bool releaseMode = kReleaseMode}) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        !{'', '/'}.contains(uri.path) ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const FormatException(
        'Enter the complete server address supplied by your manager.',
      );
    }
    if (releaseMode && uri.scheme != 'https') {
      throw const FormatException('The production server must use HTTPS.');
    }
    return uri;
  }
}
