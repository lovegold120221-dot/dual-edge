import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/smoke_firebase_rest.dart <config-json>',
    );
    exitCode = 64;
    return;
  }

  final configFile = File(arguments.single);
  if (!configFile.existsSync()) {
    stderr.writeln('Configuration file not found.');
    exitCode = 66;
    return;
  }

  final decoded = jsonDecode(await configFile.readAsString());
  if (decoded is! Map) {
    stderr.writeln('Configuration must be a JSON object.');
    exitCode = 65;
    return;
  }
  final apiKey = decoded['FIREBASE_API_KEY']?.toString().trim() ?? '';
  final databaseUrl = decoded['FIREBASE_DATABASE_URL']?.toString().trim() ?? '';
  if (apiKey.isEmpty || databaseUrl.isEmpty) {
    stderr.writeln('Firebase API key or database URL is empty.');
    exitCode = 78;
    return;
  }

  final client = http.Client();
  try {
    final authUri = Uri.https(
      'identitytoolkit.googleapis.com',
      '/v1/accounts:lookup',
      <String, String>{'key': apiKey},
    );
    final authResponse = await client
        .post(
          authUri,
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(const <String, String>{
            'idToken': 'deliberately-invalid-smoke-token',
          }),
        )
        .timeout(const Duration(seconds: 20));
    final authBody = _jsonMap(authResponse.body);
    final authError = _jsonMap(authBody['error']);
    final authMessage = authError['message']?.toString() ?? '';
    if (authResponse.statusCode != 400 ||
        !authMessage.startsWith('INVALID_ID_TOKEN')) {
      throw StateError('Firebase Authentication rejected the project setup.');
    }

    final normalizedDatabaseUrl = databaseUrl.replaceFirst(RegExp(r'/+$'), '');
    final databaseResponse = await client
        .get(Uri.parse('$normalizedDatabaseUrl/.json?shallow=true'))
        .timeout(const Duration(seconds: 20));
    if (databaseResponse.statusCode != 200 &&
        databaseResponse.statusCode != 401 &&
        databaseResponse.statusCode != 403) {
      throw StateError('Firebase Realtime Database endpoint is not reachable.');
    }

    stdout.writeln(
      'Firebase Authentication and Realtime Database endpoints are reachable.',
    );
  } on Object catch (error) {
    final safeMessage = error
        .toString()
        .replaceAll(apiKey, '[REDACTED]')
        .replaceAll(databaseUrl, '[REDACTED_DATABASE_URL]');
    stderr.writeln('Firebase REST setup failed: $safeMessage');
    exitCode = 1;
  } finally {
    client.close();
  }
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is String) {
    try {
      return _jsonMap(jsonDecode(value));
    } on FormatException {
      return <String, dynamic>{};
    }
  }
  if (value is! Map) return <String, dynamic>{};
  return value.map<String, dynamic>(
    (key, nestedValue) => MapEntry(key.toString(), nestedValue),
  );
}
