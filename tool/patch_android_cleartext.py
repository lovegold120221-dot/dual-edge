from pathlib import Path
p = Path("android/app/src/main/AndroidManifest.xml")
t = p.read_text()
if "usesCleartextTraffic" not in t:
    t = t.replace(
        "<application",
        '<application\n        android:usesCleartextTraffic="true"',
        1,
    )
    p.write_text(t)
    print("added cleartext")
else:
    print("already has cleartext")
