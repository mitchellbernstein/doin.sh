# Local voice

The optional helper converts speech to an editable input draft. Whistle is speech recognition, not a language model. The selected doin AI handles the transcript only after the user submits it.

The adapter must handle missing runtime or weights, microphone denial, cancellation, silence, clips longer than 30 seconds, model paths with spaces, invalid WAV formats, terminal escape sequences in model output, and accidental network access. These are the verification targets before implementation.

The TUI contract is `DOIN_VOICE_COMMAND`, an executable path invoked without arguments outside terminal raw mode. It inherits stdin and stderr. Stdout contains only a UTF-8 transcript, at most 16 KiB. Exit 0 means a draft or silence, 130 means cancellation, and 2 means setup or capture failure. The caller must never execute the returned draft automatically.

## Explicit setup

Nothing downloads at doin startup or during `/voice`. The helper uses the C API directly, without Cactus telemetry or HTTP clients. Audio stays in process memory. It never writes microphone clips to disk. Recording stops after 30 seconds or Enter. Ctrl-C discards the clip.

The optional microphone packages are `numpy`, `sounddevice`, and `soxr`. Python, PortAudio, model weights, and the native engine are additional optional requirements, not dependencies of the core executable. Linux may need its distribution's PortAudio package. macOS still requires the system microphone permission.

The following setup was verified on this Mac. Run from the repository directory. These commands explicitly download the optional dependencies and models.

```sh
uv venv voice/.venv
uv pip install --python voice/.venv/bin/python 'cactus-needle[mic]==3.1.0'
NEEDLE_TELEMETRY=0 voice/.venv/bin/python -c 'from needle.agent import fetch; print(fetch.fetch_library(dest_dir="voice/models", generation=3))'
curl -fL 'https://huggingface.co/Cactus-Compute/whistle/resolve/b358ddadd89b7a713b5aa131f23032d3cca1b251/whistle.cact' -o voice/models/whistle.cact
export DOIN_VOICE_COMMAND="$PWD/voice/doin-voice"
```

The installed Cactus package is used only for explicit native-engine setup. The capture helper itself uses Python's standard library for file transcription. Override engine and weights with `DOIN_WHISTLE_LIBRARY` and `DOIN_WHISTLE_WEIGHTS` to use an existing offline installation. Both accept paths containing spaces.

The downloaded engine was version 3.1.0 for macOS arm64. Its size was 1,053,712 bytes and SHA256 was `6c3d79e04c48656b275feb9b4157b43fc20a6efbb5993d0aff9e6414eaef21be`. Whistle was 16,919,407 bytes and SHA256 was `b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb`. The tested optional virtual environment occupied 45 MB. Upstream engine downloads use Cactus's versioned wheel catalog. Core doin stays independent of that Python environment.

## Verification

Generate a speech fixture without using the microphone, then run the real local engine checks.

```sh
mkdir -p artifacts/voice
say -o artifacts/voice/spoken.aiff 'Add a task to ship the first release tomorrow.'
ffmpeg -v error -y -i artifacts/voice/spoken.aiff -ar 16000 -ac 1 -c:a pcm_s16le artifacts/voice/spoken.wav
voice/.venv/bin/python voice/check.py
```

Seven checks passed on macOS arm64. They cover real synthesized speech, real-engine silence, an overlong clip, missing weights without downloads, noninteractive recording refusal, and invalid-library failure without fallback downloads, and invocation through an installed symlink with spaces. The reproducible result is `artifacts/voice/check.json`.

The real model transcribed the generated sentence as "at a task to ship the first release tomorrow." This recognition error is one reason the TUI must show an editable draft rather than execute it. Actual microphone permission, device selection, Enter stop, automatic recording timeout, and Ctrl-C cancellation still require an interactive acceptance check. No microphone was opened during development verification. Linux was not verified.

## Primary sources

[Cactus's Whistle release](https://cactuscompute.com/blog/whistle) describes the speech model, 30-second limit, and C API. [The upstream Whistle implementation](https://github.com/cactus-compute/needle/blob/9571a58b0ad3d0e4500afa6f4e00cffb8d6d1818/needle/agent/whistle.py) defines the exact `needle_load` and `needle_transcribe` signatures used here. [The upstream runtime loader](https://github.com/cactus-compute/needle/blob/9571a58b0ad3d0e4500afa6f4e00cffb8d6d1818/needle/__init__.py) shows implicit fallback downloads, which this adapter avoids. [The model revision](https://huggingface.co/Cactus-Compute/whistle/tree/b358ddadd89b7a713b5aa131f23032d3cca1b251) pins the verified weights.

Model the Domain shaped the integration. Voice returns an editable text draft with distinct success, cancellation, and failure exits. It has no authority to mutate tasks or submit AI requests.

[Sounddevice 0.5.6 stream documentation](https://python-sounddevice.readthedocs.io/en/0.5.6/api/streams.html) specifies context-managed stream closure and callback constraints. The adapter preallocates a 30-second buffer and copies each input block into that buffer. [Python SoXR documentation](https://python-soxr.readthedocs.io/en/latest/) specifies the sample-rate conversion used after capture.

The Whistle weights and upstream engine are Apache-2.0 licensed. The [pinned model license](https://huggingface.co/Cactus-Compute/whistle/blob/b358ddadd89b7a713b5aa131f23032d3cca1b251/LICENSE) applies to model redistribution. No weights or third-party engine binary are committed to this repository.
