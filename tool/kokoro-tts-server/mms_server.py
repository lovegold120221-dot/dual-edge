#!/usr/bin/env python3
"""Local MMS-TTS sidecar for gap languages (Tagalog, Korean, Thai, ...).

Sherpa/Kokoro/Piper cover English + ~40 languages; this sidecar covers the
remaining ones with Meta MMS-TTS (facebook/mms-tts-<code>), translated once
per language into Application-independent HF cache and synthesized fully
offline afterwards.

Protocol (localhost only):
  GET  /health          -> {"ok": true, "langs": [...loaded]}
  POST /tts {"text": str, "lang": "tl"} -> PCM16 mono WAV (16 kHz)

Started lazily by the Node Kokoro server; never exposed externally.
"""

import argparse
import io
import json
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import torch
from transformers import VitsModel, VitsTokenizer

RATE = 16000
_models: dict = {}
_models_lock = threading.Lock()


def ensure_model(lang: str):
    with _models_lock:
        if lang in _models:
            return _models[lang]
        model_id = f"facebook/mms-tts-{lang}"
        print(f"[mms] loading {model_id}", flush=True)
        tokenizer = VitsTokenizer.from_pretrained(model_id)
        model = VitsModel.from_pretrained(model_id)
        model.eval()
        _models[lang] = (tokenizer, model)
        print(f"[mms] ready: {lang}", flush=True)
        return _models[lang]


def synthesize(text: str, lang: str) -> bytes:
    tokenizer, model = ensure_model(lang)
    inputs = tokenizer(text, return_tensors="pt")
    with torch.no_grad():
        waveform = model(**inputs).waveform[0]
    samples = (waveform * 32767).clamp(-32768, 32767).short().tolist()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(int(s).to_bytes(2, "little", signed=True) for s in samples))
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    server_version = "mms-sidecar/1.0"

    def _json(self, status: int, body: dict):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            with _models_lock:
                langs = sorted(_models.keys())
            self._json(200, {"ok": True, "langs": langs})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/tts":
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        text = str(payload.get("text", "")).strip()
        lang = str(payload.get("lang", "")).strip().lower()
        if not text:
            self._json(400, {"error": "text required"})
            return
        if not lang:
            self._json(400, {"error": "lang required"})
            return
        try:
            wav = synthesize(text, lang)
        except Exception as e:
            print(f"[mms] error lang={lang}: {e}", flush=True)
            self._json(500, {"error": str(e)})
            return
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.send_header("X-TTS-Engine", "mms")
        self.send_header("X-TTS-Language", lang)
        self.end_headers()
        self.wfile.write(wav)

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8881)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"[mms] listening on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
