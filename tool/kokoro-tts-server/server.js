import http from "node:http";
import { execFile } from "node:child_process";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

const HOST = process.env.HOST || "127.0.0.1";
const PORT = Number(process.env.PORT || 8880);

// Supertonic 3 covers 31 languages in one bundle (en, nl, fr, de, ko,
// ja, ...). Remaining covered languages use per-language Piper voices;
// gap languages use local MMS; anything else falls back to Supertonic en.
const SUPERTONIC_BUNDLE =
  "sherpa-onnx-supertonic-3-tts-int8-2026-05-11";
const SUPERTONIC_LANGS = new Set([
  "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et",
  "fi", "fr", "hi", "hr", "hu", "id", "it", "lt", "lv", "nl", "pl",
  "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi",
]);

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MODEL_DIR =
  process.env.KOKORO_MODEL_DIR || path.join(HERE, "models");
const TTS_RELEASE =
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models";

// Per-language Piper voices for languages outside Supertonic's 31
// (sherpa int8 bundles, ~21 MB each, lazy).
// NOTE: keep in sync with lib/data/tts_voices.dart (mobile path).
const PIPER_VOICES = {
  ca: "ca_ES-upc_ona-medium",
  cy: "cy_GB-gwryw_gogleddol-medium",
  eu: "eu_ES-antton-medium",
  fa: "fa_IR-amir-medium",
  is: "is_IS-steinn-medium",
  ku: "ku_TR-berfin_renas-medium",
  lb: "lb_LU-marylux-medium",
  ml: "ml_IN-arjun-medium",
  ne: "ne_NP-chitwan-medium",
  no: "no_NO-talesyntese-medium",
  sq: "sq_AL-edon-medium",
  sr: "sr_RS-serbski_institut-medium",
  sw: "sw_CD-lanfrica-medium",
  ur: "ur_PK-fasih-medium",
};

// Gap languages served by the local MMS sidecar (Meta MMS-TTS, offline
// after first download). Keys are our two-letter codes; values are the
// MMS/ISO 639-3 model codes (facebook/mms-tts-<code>).
const MMS_LANGS = new Map([
  ["tl", "tgl"], // Tagalog (Filipino)
  ["ko", "kor"],
  ["th", "tha"],
  ["ceb", "ceb"],
  ["hau", "hau"],
  ["yor", "yor"],
  ["som", "som"],
  ["amh", "amh"],
  ["tgk", "tgk"],
  ["kaz", "kaz"],
  ["kir", "kir"],
  ["heb", "heb"],
  ["ben", "ben"],
  ["tam", "tam"],
  ["tel", "tel"],
  ["mar", "mar"],
  ["guj", "guj"],
  ["kan", "kan"],
  ["mya", "mya"],
  ["khm", "khm"],
  ["lao", "lao"],
  ["sna", "sna"],
  ["nya", "nya"],
  ["mlg", "mlg"],
  ["mon", "mon"],
  ["smo", "smo"],
]);

// Legacy Kokoro voice ids (sent by older clients) map back to languages.
const VOICE_TO_LANG = {
  af_heart: "en", af_alloy: "en", af_aoede: "en", af_bella: "en",
  af_jessica: "en", af_kore: "en", af_nicole: "en", af_nova: "en",
  af_river: "en", af_sarah: "en", af_sky: "en",
  am_adam: "en", am_echo: "en", am_eric: "en", am_fenrir: "en",
  am_liam: "en", am_michael: "en", am_onyx: "en", am_puck: "en",
  am_santa: "en", bf_alice: "en", bf_emma: "en", bf_isabella: "en",
  bf_lily: "en", bm_daniel: "en", bm_fable: "en", bm_george: "en",
  bm_lewis: "en", orus: "en",
  ef_dora: "es", ff_siwis: "fr", hf_alpha: "hi", if_sara: "it",
  jf_alpha: "ja", pf_dora: "pt", zf_xiaobei: "zh",
};

/** Normalize a display name ("Dutch (Flemish)"), BCP-47 tag, or voice id. */
function resolveLang(input) {
  const raw = String(input || "").trim().toLowerCase();
  if (!raw || raw === "auto") return "en";
  if (VOICE_TO_LANG[raw]) return VOICE_TO_LANG[raw];
  if (SUPERTONIC_LANGS.has(raw)) return raw;
  if (PIPER_VOICES[raw]) return raw;
  if (MMS_LANGS.has(raw)) return raw;
  if (raw === "en" || raw.startsWith("en-") || raw.startsWith("en_")) return "en";
  if (raw.length >= 2) {
    const two = raw.substring(0, 2);
    if (SUPERTONIC_LANGS.has(two)) return two;
    if (PIPER_VOICES[two]) return two;
    if (MMS_LANGS.has(two)) return two;
  }
  if (raw.includes("dutch") || raw.includes("flemish") || raw.includes("nederlands")) return "nl";
  if (raw.includes("english") || raw.includes("american") || raw.includes("british")) return "en";
  if (raw.includes("french") || raw.includes("fran")) return "fr";
  if (raw.includes("spanish") || raw.includes("espa")) return "es";
  if (raw.includes("german") || raw.includes("deutsch")) return "de";
  if (raw.includes("italian")) return "it";
  if (raw.includes("portug")) return "pt";
  if (raw.includes("arab") || raw.includes("darija")) return "ar";
  if (raw.includes("turk")) return "tr";
  if (raw.includes("polish") || raw.includes("polski")) return "pl";
  if (raw.includes("romanian")) return "ro";
  if (raw.includes("ukrain")) return "uk";
  if (raw.includes("hindi")) return "hi";
  if (raw.includes("chinese") || raw.includes("mandarin")) return "zh";
  if (raw.includes("indones")) return "id";
  if (raw.includes("vietnam")) return "vi";
  if (raw.includes("russian")) return "ru";
  if (raw.includes("catalan")) return "ca";
  if (raw.includes("welsh") || raw.includes("cymraeg")) return "cy";
  if (raw.includes("danish")) return "da";
  if (raw.includes("greek")) return "el";
  if (raw.includes("basque")) return "eu";
  if (raw.includes("persian") || raw.includes("farsi")) return "fa";
  if (raw.includes("finnish")) return "fi";
  if (raw.includes("hungarian")) return "hu";
  if (raw.includes("icelandic")) return "is";
  if (raw.includes("kurdish")) return "ku";
  if (raw.includes("luxembourg")) return "lb";
  if (raw.includes("latvian")) return "lv";
  if (raw.includes("malayalam")) return "ml";
  if (raw.includes("nepali")) return "ne";
  if (raw.includes("norwegian")) return "no";
  if (raw.includes("slovak")) return "sk";
  if (raw.includes("slovenian")) return "sl";
  if (raw.includes("albanian")) return "sq";
  if (raw.includes("serbian")) return "sr";
  if (raw.includes("swedish")) return "sv";
  if (raw.includes("urdu")) return "ur";
  if (raw.includes("czech")) return "cs";
  if (raw.includes("swahili")) return "sw";
  // MMS gap languages (local Meta MMS-TTS voices).
  if (raw.includes("tagalog") || raw.includes("filipino")) return "tl";
  if (raw.includes("korean")) return "ko";
  if (raw.includes("thai")) return "th";
  if (raw.includes("cebuano")) return "ceb";
  if (raw.includes("hausa")) return "hau";
  if (raw.includes("yoruba")) return "yor";
  if (raw.includes("somali")) return "som";
  if (raw.includes("amharic")) return "amh";
  if (raw.includes("tajik")) return "tgk";
  if (raw.includes("kazakh")) return "kaz";
  if (raw.includes("kyrgyz")) return "kir";
  if (raw.includes("hebrew")) return "heb";
  if (raw.includes("bengali")) return "ben";
  if (raw.includes("tamil")) return "tam";
  if (raw.includes("telugu")) return "tel";
  if (raw.includes("marathi")) return "mar";
  if (raw.includes("gujarati")) return "guj";
  if (raw.includes("kannada")) return "kan";
  if (raw.includes("burmese") || raw.includes("myanmar")) return "mya";
  if (raw.includes("khmer")) return "khm";
  if (raw.includes("lao")) return "lao";
  if (raw.includes("shona")) return "sna";
  if (raw.includes("chichewa") || raw === "nyanja" || raw.includes("nyanja (")) return "nya";
  if (raw.includes("malagasy")) return "mlg";
  if (raw.includes("mongolian")) return "mon";
  if (raw.includes("samoan")) return "smo";
  return "en";
}

let supertonicEngine = null; // sherpa supertonic-3, 31 languages (lazy)
let supertonicLoading = null;
let sherpa = null; // sherpa-onnx-node (lazy)
let mmsProcess = null;
let mmsReady = false;
const MMS_PORT = Number(process.env.MMS_PORT || 8881);
const PYTHON_BIN =
  process.env.PYTHON_BINARY ||
  process.env.PYTHON_BIN ||
  "python3";
const piperEngines = new Map(); // lang -> { tts, sampleRate, voice }
let lastError = null;

async function ensureSupertonic() {
  if (supertonicEngine) return supertonicEngine;
  if (supertonicLoading) return supertonicLoading;
  supertonicLoading = (async () => {
    const dir = await ensureSupertonicFiles();
    const lib = ensureSherpa();
    const config = {
      model: {
        supertonic: {
          durationPredictor: path.join(dir, "duration_predictor.int8.onnx"),
          textEncoder: path.join(dir, "text_encoder.int8.onnx"),
          vectorEstimator: path.join(dir, "vector_estimator.int8.onnx"),
          vocoder: path.join(dir, "vocoder.int8.onnx"),
          ttsJson: path.join(dir, "tts.json"),
          unicodeIndexer: path.join(dir, "unicode_indexer.bin"),
          voiceStyle: path.join(dir, "voice.bin"),
        },
        debug: false,
        numThreads: 2,
        provider: "cpu",
      },
      maxNumSentences: 1,
    };
    const tts = new lib.OfflineTts(config);
    supertonicEngine = {
      tts,
      sampleRate: tts.sampleRate > 0 ? tts.sampleRate : 24000,
    };
    console.log(
      `[supertonic] ready (${supertonicEngine.sampleRate} Hz, 31 langs)`,
    );
    lastError = null;
    return supertonicEngine;
  })().catch((err) => {
    lastError = String(err);
    supertonicLoading = null;
    supertonicEngine = null;
    console.error("[supertonic] load failed", err);
    throw err;
  });
  return supertonicLoading;
}

async function ensureSupertonicFiles() {
  const dir = path.join(MODEL_DIR, SUPERTONIC_BUNDLE);
  const marker = path.join(dir, ".extracted");
  try {
    await fsp.access(marker);
    return dir;
  } catch { /* download */ }
  const url = `${TTS_RELEASE}/${SUPERTONIC_BUNDLE}.tar.bz2`;
  const dest = path.join(MODEL_DIR, `${SUPERTONIC_BUNDLE}.tar.bz2`);
  console.log(`[supertonic] downloading ${url}`);
  await downloadFile(url, dest);
  console.log("[supertonic] extracting…");
  await execTar(["-xjf", dest, "-C", MODEL_DIR]);
  await fsp.writeFile(marker, new Date().toISOString());
  await fsp.unlink(dest).catch(() => {});
  return dir;
}

function ensureSherpa() {
  if (!sherpa) {
    sherpa = require("sherpa-onnx-node");
  }
  return sherpa;
}

function mmsHealth() {
  return new Promise((resolve) => {
    const req = require("node:http").get(
      `http://127.0.0.1:${MMS_PORT}/health`,
      (res) => {
        res.resume();
        resolve(res.statusCode === 200);
      },
    );
    req.on("error", () => resolve(false));
    req.setTimeout(2000, () => {
      req.destroy();
      resolve(false);
    });
  });
}

async function ensureMms() {
  if (await mmsHealth()) {
    mmsReady = true;
    return true;
  }
  if (!mmsProcess) {
    const { spawn } = require("node:child_process");
    console.log(`[mms] starting sidecar (${PYTHON_BIN} mms_server.py)`);
    mmsProcess = spawn(
      PYTHON_BIN,
      ["mms_server.py", "--port", String(MMS_PORT)],
      { cwd: HERE, stdio: ["ignore", "pipe", "pipe"] },
    );
    mmsProcess.stdout.on("data", (d) =>
      process.stdout.write(`[mms] ${d}`),
    );
    mmsProcess.stderr.on("data", (d) =>
      process.stderr.write(`[mms] ${d}`),
    );
    mmsProcess.on("exit", (code) => {
      console.error(`[mms] sidecar exited (${code})`);
      mmsProcess = null;
      mmsReady = false;
    });
  }
  for (let i = 0; i < 120; i++) {
    await new Promise((r) => setTimeout(r, 500));
    if (await mmsHealth()) {
      mmsReady = true;
      return true;
    }
  }
  throw new Error("MMS sidecar did not become healthy");
}

function postMms(text, lang) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ text, lang });
    const req = require("node:http").request(
      {
        host: "127.0.0.1",
        port: MMS_PORT,
        path: "/tts",
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body),
        },
      },
      (res) => {
        if (res.statusCode !== 200) {
          res.resume();
          reject(new Error(`mms sidecar failed (${res.statusCode})`));
          return;
        }
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve(Buffer.concat(chunks)));
        res.on("error", reject);
      },
    );
    req.on("error", reject);
    req.setTimeout(120000, () => {
      req.destroy(new Error("mms sidecar timed out"));
    });
    req.end(body);
  });
}

async function downloadFile(url, dest, redirects = 5) {
  await fsp.mkdir(path.dirname(dest), { recursive: true });
  const partial = `${dest}.partial`;
  let offset = 0;
  try {
    const stat = await fsp.stat(partial);
    offset = stat.size;
  } catch { /* fresh download */ }
  const data = await fetchUrl(url, offset, redirects);
  const flag = data.resumed ? "a" : "w";
  if (!data.resumed) offset = 0;
  const handle = await fsp.open(partial, flag);
  try {
    for await (const chunk of data.stream) {
      await handle.write(chunk);
    }
  } finally {
    await handle.close();
  }
  await fsp.rename(partial, dest);
}

function fetchUrl(url, offset, redirects) {
  return new Promise((resolve, reject) => {
    const doGet = (current, left) => {
      if (left < 0) return reject(new Error("too many redirects"));
      const lib = current.startsWith("https") ? require("node:https") : require("node:http");
      const req = lib.get(
        current,
        { headers: offset > 0 ? { Range: `bytes=${offset}-` } : {} },
        (res) => {
          if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
            res.resume();
            doGet(new URL(res.headers.location, current).toString(), left - 1);
            return;
          }
          if (res.statusCode !== 200 && res.statusCode !== 206) {
            res.resume();
            reject(new Error(`download failed (${res.statusCode}): ${current}`));
            return;
          }
          resolve({ stream: res, resumed: res.statusCode === 206 });
        },
      );
      req.on("error", reject);
    };
    doGet(url, redirects);
  });
}

function execTar(args, cwd) {
  return new Promise((resolve, reject) => {
    execFile("tar", args, { cwd }, (err, stdout, stderr) => {
      if (err) reject(new Error(`tar failed: ${stderr || err.message}`));
      else resolve(stdout);
    });
  });
}

async function ensurePiper(lang) {
  const cached = piperEngines.get(lang);
  if (cached) return cached;
  const voice = PIPER_VOICES[lang];
  if (!voice) throw new Error(`no Piper voice for language: ${lang}`);
  const bundle = `vits-piper-${voice}-int8`;
  const dir = path.join(MODEL_DIR, bundle);
  const marker = path.join(dir, ".extracted");
  let ready = false;
  try {
    await fsp.access(marker);
    ready = true;
  } catch { /* needs download */ }
  if (!ready) {
    const url = `${TTS_RELEASE}/${bundle}.tar.bz2`;
    const dest = path.join(MODEL_DIR, `${bundle}.tar.bz2`);
    console.log(`[piper:${lang}] downloading ${url}`);
    await downloadFile(url, dest);
    console.log(`[piper:${lang}] extracting…`);
    await execTar(["-xjf", dest, "-C", MODEL_DIR]);
    await fsp.writeFile(marker, new Date().toISOString());
    await fsp.unlink(dest).catch(() => {});
  }
  // Inner model file: <voice>.onnx (int8 bundles keep the fp32 base name).
  const entries = await fsp.readdir(dir);
  const onnx = entries.find((n) => n.endsWith(".onnx") && !n.endsWith(".json"));
  if (!onnx) throw new Error(`no .onnx found in ${dir}`);
  if (!entries.includes("tokens.txt")) {
    throw new Error(`no tokens.txt found in ${dir}`);
  }
  const lib = ensureSherpa();
  const config = {
    model: {
      vits: {
        model: path.join(dir, onnx),
        tokens: path.join(dir, "tokens.txt"),
        dataDir: path.join(dir, "espeak-ng-data"),
      },
      debug: false,
      numThreads: 2,
      provider: "cpu",
    },
    maxNumSentences: 1,
  };
  const tts = new lib.OfflineTts(config);
  const rate =
    tts.sampleRate && tts.sampleRate > 0 ? tts.sampleRate : 22050;
  const entry = { tts, sampleRate: rate, voice };
  piperEngines.set(lang, entry);
  console.log(`[piper:${lang}] ready (${voice}, ${rate} Hz)`);
  lastError = null;
  return entry;
}

function splitSentences(text) {
  return text
    .split(/(?<=[.!?;:\n])\s+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

// Supertonic speaker IDs by measured pitch (sid 0-3 ≈ 220-245 Hz female;
// sid 4-9 ≈ 97-164 Hz male). Default voice is male.
const SUPERTONIC_MALE_SID = 6; // ~122 Hz
const SUPERTONIC_FEMALE_SID = 0; // ~243 Hz
const FEMININE_VOICES = new Set([
  "female",
  "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica",
  "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
  "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
  "ff_siwis", "if_sara", "pf_dora", "jf_alpha", "zf_xiaobei", "hf_alpha",
]);

/** Supertonic sid for a requested voice (male default). */
function supertonicSid(voice) {
  const v = String(voice || "").trim().toLowerCase();
  if (v === "female" || FEMININE_VOICES.has(v)) return SUPERTONIC_FEMALE_SID;
  return SUPERTONIC_MALE_SID;
}

/** Natural pause inserted between synthesized sentences (fluency). */
const SENTENCE_PAUSE_MS = 180;

function silenceChunk(sampleRate, ms = SENTENCE_PAUSE_MS) {
  return new Float32Array(Math.floor((sampleRate * ms) / 1000));
}

/** Join sentence audios with natural pauses (avoids choppy hard cuts). */
function joinSentences(parts, sampleRate) {
  const chunks = [];
  for (const p of parts) {
    if (chunks.length > 0) chunks.push(silenceChunk(sampleRate));
    chunks.push(p);
  }
  const total = chunks.reduce((n, p) => n + p.length, 0);
  const merged = new Float32Array(total);
  let offset = 0;
  for (const p of chunks) {
    merged.set(p, offset);
    offset += p.length;
  }
  return merged;
}

/** Synthesize with Supertonic in `lang` (must be in SUPERTONIC_LANGS). */
async function synthSupertonic(text, lang, speed, voice) {
  const entry = await ensureSupertonic();
  const lib = ensureSherpa();
  const sid = supertonicSid(voice);
  const parts = [];
  for (const sentence of splitSentences(text)) {
    const audio = entry.tts.generate({
      text: sentence,
      generationConfig: new lib.GenerationConfig({
        sid,
        speed,
        silenceScale: 0.2,
        numSteps: 8,
        extra: { lang },
      }),
    });
    parts.push(audio.samples);
  }
  return {
    wav: encodeWav(joinSentences(parts, entry.sampleRate), entry.sampleRate),
    sid,
  };
}

function encodeWav(samples, sampleRate) {
  const data = Buffer.alloc(samples.length * 2);
  for (let i = 0; i < samples.length; i++) {
    const clamped = Math.max(-1, Math.min(1, samples[i]));
    data.writeInt16LE(Math.round(clamped * 32767), i * 2);
  }
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + data.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(data),
  });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || "/", `http://${HOST}:${PORT}`);

    if (req.method === "GET" && url.pathname === "/health") {
      return sendJson(res, 200, {
        ok: true,
        supertonicReady: Boolean(supertonicEngine),
        piper: [...piperEngines.keys()],
        mmsReady,
        multilingual: true,
        error: lastError,
      });
    }

    if (req.method === "GET" && url.pathname === "/voices") {
      return sendJson(res, 200, {
        supertonic: [...SUPERTONIC_LANGS].map((lang) => ({
          lang,
          engine: "supertonic",
        })),
        piper: Object.fromEntries(
          Object.entries(PIPER_VOICES).map(([lang, voice]) => [
            lang,
            { engine: "piper", voice },
          ]),
        ),
        mms: [...MMS_LANGS].map(([lang, mms]) => ({
          lang,
          engine: "mms",
          voice: `mms-tts-${mms}`,
        })),
      });
    }

    if (req.method === "POST" && url.pathname === "/tts") {
      const raw = await readBody(req);
      let payload = {};
      try {
        payload = JSON.parse(raw.toString("utf8") || "{}");
      } catch {
        return sendJson(res, 400, { error: "invalid JSON" });
      }
      const text = String(payload.text || "").trim();
      if (!text) return sendJson(res, 400, { error: "text required" });
      const speed = Number(payload.speed || 1);
      const lang = resolveLang(payload.language || payload.voice || "en");
      const voice = String(payload.voice || "");

      let wavBuffer;
      let usedVoice = `supertonic-${lang}`;
      let engine = "supertonic";
      // Supertonic first (best quality), then Piper, then MMS gaps,
      // then Supertonic English fallback.
      if (SUPERTONIC_LANGS.has(lang)) {
        engine = "supertonic";
        const out = await synthSupertonic(text, lang, speed, voice);
        wavBuffer = out.wav;
        usedVoice = `supertonic-${lang}-sid${out.sid}`;
      } else if (PIPER_VOICES[lang]) {
        engine = "piper";
        const entry = await ensurePiper(lang);
        usedVoice = entry.voice;
        const lib = ensureSherpa();
        const parts = [];
        for (const sentence of splitSentences(text)) {
          const audio = entry.tts.generate({
            text: sentence,
            generationConfig: new lib.GenerationConfig({
              sid: 0,
              speed,
              silenceScale: 0.2,
            }),
          });
          parts.push(audio.samples);
        }
        wavBuffer = encodeWav(
          joinSentences(parts, entry.sampleRate),
          entry.sampleRate,
        );
      } else if (MMS_LANGS.has(lang)) {
        engine = "mms";
        const mms = MMS_LANGS.get(lang);
        usedVoice = `mms-tts-${mms}`;
        await ensureMms();
        wavBuffer = await postMms(text, mms);
      } else {
        // Fallback: Supertonic English.
        engine = "supertonic";
        const out = await synthSupertonic(text, "en", speed, voice);
        wavBuffer = out.wav;
        usedVoice = `supertonic-en-sid${out.sid}`;
      }

      res.writeHead(200, {
        "Content-Type": "audio/wav",
        "Content-Length": wavBuffer.length,
        "X-TTS-Voice": usedVoice,
        "X-TTS-Engine": engine,
        "X-TTS-Language": lang,
      });
      res.end(wavBuffer);
      return;
    }

    sendJson(res, 404, { error: "not found" });
  } catch (err) {
    console.error("[kokoro] request error", err);
    lastError = String(err);
    sendJson(res, 500, { error: String(err && err.message || err) });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[tts] listening on http://${HOST}:${PORT} (multilingual)`);
  // Warm Supertonic in background; Piper/MMS load on first use.
  ensureSupertonic().catch(() => {});
});
