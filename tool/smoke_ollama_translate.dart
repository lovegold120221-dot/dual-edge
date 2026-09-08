import 'dart:convert';
import 'dart:io';

/// Smoke-check the local eb-translator model (gemma3:4b via Modelfile).
///
/// Usage: dart run tool/smoke_ollama_translate.dart [config-json]
/// Reads OLLAMA_URL / OLLAMA_MODEL from the JSON file when given, otherwise
/// defaults to http://localhost:11434 + eb-translator. Exits non-zero when
/// Ollama is unreachable, the model is missing, or no translation comes back.
Future<void> main(List<String> arguments) async {
  var ollamaUrl = 'http://localhost:11434';
  var model = 'eb-translator';

  if (arguments.isNotEmpty) {
    final configFile = File(arguments.first);
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
    final url = decoded['OLLAMA_URL']?.toString().trim() ?? '';
    final name = decoded['OLLAMA_MODEL']?.toString().trim() ?? '';
    if (url.isNotEmpty) ollamaUrl = url;
    if (name.isNotEmpty) model = name;
  }

  final base = ollamaUrl.replaceAll(RegExp(r'/+$'), '');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final tags = await _getJson(client, '$base/api/tags');
    final installed = <String>[];
    final rawModels = tags['models'];
    if (rawModels is List) {
      for (final entry in rawModels) {
        if (entry is Map && entry['name'] != null) {
          installed.add(entry['name'].toString());
        }
      }
    }
    final wantBase = model.split(':').first;
    final found = installed.any(
      (name) =>
          !name.contains(':cloud') &&
          (name == model ||
              name == '$wantBase:latest' ||
              name.split(':').first == wantBase),
    );
    if (!found) {
      stderr.writeln(
        'Model "$model" not found locally. '
        'Install it with: ollama pull gemma3:4b && '
        'ollama create eb-translator -f Modelfile',
      );
      exitCode = 1;
      return;
    }

    final translated = await _chat(
      client,
      '$base/api/chat',
      model,
      'Translate the following text from English (US) to Dutch (Flemish). '
          'Output only the translation.\n\nText:\nGood morning, how can I help you?',
    );
    if (translated.isEmpty) {
      stderr.writeln('Ollama returned an empty translation.');
      exitCode = 1;
      return;
    }
    stdout.writeln('eb-translator smoke OK [$model]: $translated');
  } on SocketException catch (error) {
    stderr.writeln('Ollama is not reachable at $ollamaUrl: $error');
    exitCode = 1;
  } on HttpException catch (error) {
    stderr.writeln('Ollama request failed: $error');
    exitCode = 1;
  } finally {
    client.close();
  }
}

Future<Map<String, dynamic>> _getJson(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close().timeout(const Duration(seconds: 10));
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw HttpException('GET $url -> ${response.statusCode}: $body');
  }
  return Map<String, dynamic>.from(jsonDecode(body) as Map);
}

Future<String> _chat(
  HttpClient client,
  String url,
  String model,
  String prompt,
) async {
  final request = await client.postUrl(Uri.parse(url));
  request.headers.contentType = ContentType.json;
  request.write(
    jsonEncode(<String, dynamic>{
      'model': model,
      'stream': false,
      'options': <String, dynamic>{
        'temperature': 0,
        'top_p': 0.9,
        'top_k': 40,
        'num_ctx': 2048,
        'num_predict': 512,
      },
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content':
              'You are eb-translator, a strict translation engine. '
              'Output ONLY the translated text.',
        },
        <String, String>{'role': 'user', 'content': prompt},
      ],
    }),
  );
  final response = await request.close().timeout(const Duration(seconds: 90));
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw HttpException('POST $url -> ${response.statusCode}: $body');
  }
  final data = jsonDecode(body);
  if (data is Map) {
    final message = data['message'];
    if (message is Map && message['content'] != null) {
      return message['content'].toString().trim();
    }
  }
  return '';
}
