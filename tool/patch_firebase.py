
from pathlib import Path
p = Path("lib/firebase_options.dart")
fo = p.read_text()
old = """      case TargetPlatform.macOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for macos - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );"""
new = """      case TargetPlatform.macOS:
        // Not configured for macOS; local edge builds skip Firebase in main.dart.
        return ios;"""
if old in fo:
    p.write_text(fo.replace(old, new))
    print("patched")
else:
    print("NOT_FOUND")
