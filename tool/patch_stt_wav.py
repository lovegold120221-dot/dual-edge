from pathlib import Path
import re

path = Path('lib/services/stt_service.dart')
text = path.read_text()
old = '''  Future<File> _writeTempWav(List<int> pcmData) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/stt_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(_buildWavBytes(pcmData), flush: true);
    return file;
  }'''
new = '''  Future<File> _writeTempWav(List<int> pcmData) async {
    final dir = await getTemporaryDirectory();
    await Directory(dir.path).create(recursive: true);
    final file = File(
      '${dir.path}/stt_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(_buildWavBytes(pcmData), flush: true);
    if (!await file.exists()) {
      throw StateError('Failed to write temp WAV at ${file.path}');
    }
    return file;
  }'''
if old not in text:
    # try flexible match
    m = re.search(r'Future<File> _writeTempWav\(List<int> pcmData\) async \{.*?\n  \}', text, re.S)
    if not m:
        raise SystemExit('writeTempWav block not found')
    text = text[:m.start()] + new + text[m.end():]
    path.write_text(text)
    print('patched via regex')
else:
    path.write_text(text.replace(old, new))
    print('patched exact')
