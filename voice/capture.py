#!/usr/bin/env python3
"""Optional local Whistle capture. No downloads or HTTP during capture."""
import argparse
import array
import ctypes
import json
import os
from pathlib import Path
import select
import sys
import time
import wave

ROOT = Path(__file__).resolve().parent


def transcribe(samples, library, weights):
    lib = ctypes.CDLL(str(library))
    lib.needle_load.argtypes = [ctypes.c_char_p, ctypes.c_uint64]
    lib.needle_load.restype = ctypes.c_int
    lib.needle_transcribe.argtypes = [ctypes.POINTER(ctypes.c_float), ctypes.c_int,
                                     ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int,
                                     ctypes.c_char_p, ctypes.c_int]
    lib.needle_transcribe.restype = ctypes.c_int
    lib.needle_last_error.restype = ctypes.c_char_p
    data = weights.read_bytes()
    if lib.needle_load(data, len(data)) < 0:
        raise RuntimeError(lib.needle_last_error().decode(errors="replace"))
    buffer = ctypes.create_string_buffer(16384)
    pcm = array.array("f", samples)
    source = (ctypes.c_float * len(pcm)).from_buffer(pcm)
    if lib.needle_transcribe(source, len(pcm), None, None, 0, buffer, len(buffer)) < 0:
        raise RuntimeError(lib.needle_last_error().decode(errors="replace"))
    text = json.loads(buffer.value)["text"]
    if not isinstance(text, str):
        raise RuntimeError("Whistle returned an invalid transcript")
    return " ".join("".join(c for c in text if c.isprintable() or c.isspace()).split())


def wav_samples(path):
    with wave.open(str(path), "rb") as source:
        if (source.getframerate(), source.getnchannels(), source.getsampwidth()) != (16000, 1, 2):
            raise RuntimeError("Use a 16 kHz mono PCM16 WAV file")
        if source.getnframes() > 480000:
            raise RuntimeError("Voice clips must be at most 30 seconds")
        pcm = array.array("h", source.readframes(source.getnframes()))
        if sys.byteorder != "little":
            pcm.byteswap()
        return [v / 32768 for v in pcm]


def record():
    if not sys.stdin.isatty():
        raise RuntimeError("Recording needs an interactive terminal")
    import numpy
    import sounddevice
    import soxr
    rate = int(sounddevice.query_devices(kind="input")["default_samplerate"])
    pcm = numpy.zeros(30 * rate, numpy.float32)
    count = 0
    def collect(data, *_):
        nonlocal count
        size = min(len(data), len(pcm) - count)
        pcm[count:count + size] = data[:size, 0]
        count += size
    print("Recording locally. Enter stops. Ctrl-C cancels. Maximum 30 seconds.", file=sys.stderr, flush=True)
    deadline = time.monotonic() + 30
    with sounddevice.InputStream(samplerate=rate, channels=1, dtype="float32", callback=collect):
        while time.monotonic() < deadline:
            if select.select([sys.stdin], [], [], min(0.1, max(0, deadline - time.monotonic())))[0]:
                if sys.stdin.readline() == "":
                    raise KeyboardInterrupt
                break
    print("Recording stopped. Transcribing locally.", file=sys.stderr, flush=True)
    samples = pcm[:count]
    return samples if rate == 16000 else soxr.resample(samples, rate, 16000, quality="HQ")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", type=Path, help="Transcribe a local 16 kHz mono PCM16 WAV instead of recording")
    parser.add_argument("--library", type=Path, default=os.getenv("DOIN_WHISTLE_LIBRARY", str(ROOT / "models" / ("libneedle.dylib" if sys.platform == "darwin" else "libneedle.so"))))
    parser.add_argument("--weights", type=Path, default=os.getenv("DOIN_WHISTLE_WEIGHTS", str(ROOT / "models" / "whistle.cact")))
    args = parser.parse_args()
    try:
        if not args.library.is_file() or not args.weights.is_file():
            raise RuntimeError("Voice is not configured. See docs/voice.md for explicit local setup.")
        ctypes.CDLL(str(args.library))
        audio = wav_samples(args.file) if args.file else record()
        text = transcribe(audio, args.library, args.weights) if len(audio) else ""
        print(text)
        if not text:
            print("No speech detected.", file=sys.stderr)
        return 0
    except KeyboardInterrupt:
        print("Recording cancelled. Nothing submitted.", file=sys.stderr)
        return 130
    except Exception as error:
        print(f"Voice unavailable. {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
