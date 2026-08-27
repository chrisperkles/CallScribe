# CallScribe

A menu bar button that records your Mac's audio — both sides of a call — and
transcribes it locally with whisper.cpp the moment you stop.

No virtual audio driver, no output-device switching. It uses the Core Audio
process-tap API (macOS 14.4+) to tap system output directly, and records your
microphone as a **separate track**, so the transcript can tell you apart from
the other side.

## Install

```sh
./build.sh              # builds, signs and installs to /Applications
open /Applications/CallScribe.app
```

Requirements (already present if `./build.sh` ran):

```sh
brew install ffmpeg whisper-cpp
# a model, e.g.:
curl -L -o ~/whisper-models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

On first recording macOS asks for **Microphone** and **Audio Recording**
permission. Both live in System Settings › Privacy & Security.

## Use

Click the 🎤 in the menu bar → **Start Recording**. The icon turns into a red
record dot and the menu shows elapsed time. Click → **Stop & Transcribe**.
Transcription runs in the background; you get a notification when it's done.

Output lands in `~/Recordings/CallScribe/<timestamp>/`:

```
them.caf         raw system audio (the other side)
me.caf           raw microphone (you)
them.srt, me.srt per-track timestamps
transcript.txt   merged, speaker-labelled, chronological
```

## Verify

```sh
/Applications/CallScribe.app/Contents/MacOS/CallScribe --selftest 10
```

Records 10 seconds, transcribes, prints the result. Use this if something looks
wrong — it reports tool paths and permission status before recording.

## Configure

```sh
defaults write at.skyline.CallScribe modelPath ~/whisper-models/ggml-medium.bin
defaults write at.skyline.CallScribe language de       # or "auto" (default)
defaults write at.skyline.CallScribe recordingsRoot ~/Documents/Calls
defaults write at.skyline.CallScribe whisperPath /opt/homebrew/bin/whisper-cli
defaults write at.skyline.CallScribe ffmpegPath /opt/homebrew/bin/ffmpeg
```

Settings are re-read at the start of every recording — no restart needed.

## Notes

- Use headphones. On speakers, the mic picks up the far end too and both tracks
  transcribe the same words.
- Recording another person is regulated differently by jurisdiction. In Austria
  and most of the EU, get consent.
- `build.sh` signs with your Apple Development certificate when one exists, which
  keeps the granted permissions across rebuilds. Ad-hoc signing works too, but
  macOS re-prompts after every build.
