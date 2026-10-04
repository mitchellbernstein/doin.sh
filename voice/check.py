#!/usr/bin/env python3
"""Reproducible adapter E2E using the real engine and a local speech WAV."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import wave

ROOT = Path(__file__).resolve().parent
ARTIFACTS = ROOT.parent / "artifacts" / "voice"
ARTIFACTS.mkdir(parents=True, exist_ok=True)
results = []

def run(name, args, expected, contains=None, env=None):
    result = subprocess.run([sys.executable, str(ROOT / "capture.py"), *args],
                            env=env, capture_output=True, text=True, timeout=20)
    assert result.returncode == expected, (name, result.stderr)
    if contains:
        assert contains in result.stdout + result.stderr, (name, result.stdout, result.stderr)
    results.append({"scenario": name, "exit": result.returncode,
                    "stdout": result.stdout, "stderr": result.stderr})

with tempfile.TemporaryDirectory(prefix="doin voice ") as folder:
    folder = Path(folder)
    shutil.copy(ROOT / "models" / "whistle.cact", folder / "weights with spaces.cact")
    common = ["--weights", str(folder / "weights with spaces.cact")]
    link = folder / "installed voice"
    link.symlink_to(ROOT / "doin-voice")
    linked = subprocess.run([str(link), "--file", str(ARTIFACTS / "spoken.wav")], capture_output=True, text=True, timeout=20)
    assert linked.returncode == 0 and "ship the first release tomorrow" in linked.stdout, ("installed symlink", linked.stderr)
    results.append({"scenario": "installed symlink with spaces", "exit": linked.returncode, "stdout": linked.stdout, "stderr": linked.stderr})
    run("real synthesized speech", [*common, "--file", str(ARTIFACTS / "spoken.wav")], 0, "ship the first release tomorrow")
    silence = folder / "silence.wav"
    with wave.open(str(silence), "wb") as wav:
        wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        wav.writeframes(bytes(32000))
    run("silence returns no draft", [*common, "--file", str(silence)], 0, "No speech detected")
    with wave.open(str(silence), "wb") as wav:
        wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        wav.writeframes(bytes(32_000 * 31))
    run("overlong clip rejected", [*common, "--file", str(silence)], 2, "at most 30 seconds")
    run("missing weights no download", ["--weights", str(folder / "missing")], 2, "not configured")
    run("noninteractive recording refused", common, 2, "interactive terminal")
    run("invalid library no fallback download", [*common, "--library", str(silence), "--file", str(ARTIFACTS / "spoken.wav")], 2, "Voice unavailable")
(ARTIFACTS / "check.json").write_text(json.dumps(results, indent=2) + "\n")
print(f"Passed {len(results)} adapter scenarios. {ARTIFACTS / 'check.json'}")
