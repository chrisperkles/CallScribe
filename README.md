# CallScribe

A menu bar button that records your Mac — both sides of a call, or a meeting in
the room — and transcribes it locally the moment you stop.

Everything runs on your machine. No account, no cloud, no audio leaves the Mac.

```
[00:00:00] Them:
  Could you send the revised quote before Friday?

[00:00:09] Me:
  Yes — I'll have it over to you Thursday morning.
```

## Install

Requires Apple Silicon and macOS 15 or newer.

```sh
git clone https://github.com/chrisperkles/CallScribe.git
cd CallScribe
./install.sh
```

The script installs what's missing (Xcode Command Line Tools, `cmake`), compiles
the speech engine, builds the app and launches it. First run takes a few minutes;
after that a microphone icon sits in the menu bar.

Then, in the app:

1. Click the icon and pick a speech model — downloaded once (~550 MB), reused forever.
2. Start a recording. macOS asks for **Microphone** and **audio recording**
   permission. Both are required.

CallScribe starts with your Mac from then on. To update, `git pull && ./install.sh`.

## Using it

Click the menu bar icon and choose:

- **Record Call** — Zoom, Teams, Meet, FaceTime, a phone call on speaker.
  Captures the far end (what your Mac plays) and you (your microphone) as two
  separate tracks, then merges them into one labelled transcript.
- **Record Meeting (room)** — people sitting together. Microphone only,
  transcribed without guessing who said what.

**Stop & Transcribe** when done. A notification appears when the transcript is
ready. Output lands in `~/Recordings/CallScribe/<date and time>/`:

```
them.caf         the far end, untouched
me.caf           you, untouched
transcript.txt   merged, chronological, labelled
```

## Getting good transcripts

- **Wear headphones on calls.** On speakers your microphone also picks up the far
  end; CallScribe detects and strips most of that echo, but headphones remove the
  problem entirely.
- **In a meeting room, put the Mac near whoever is talking**, or use an external
  mic. A laptop at the end of a long table gives thin audio, and thin audio
  transcribes badly.
- Language is auto-detected. Pinning it helps if your calls are always German:
  `defaults write at.skyline.CallScribe language de`

## Before recording other people

Recording a conversation is regulated differently depending on where the
participants are. In Austria and most of the EU, tell them and get their
agreement. CallScribe does not announce itself.

## Settings

```sh
defaults write at.skyline.CallScribe language de          # or "auto"
defaults write at.skyline.CallScribe recordingsRoot ~/Documents/Calls
defaults write at.skyline.CallScribe modelPath /path/to/ggml-model.bin
```

Read again at the start of every recording — no restart needed.

## When something's wrong

```sh
/Applications/CallScribe.app/Contents/MacOS/CallScribe --selftest 10
```

Records ten seconds, transcribes it, and prints a diagnostic: engine and model in
use, whether permissions were granted, and the measured level of each track. Add
`--meeting` to test room mode.

## How it works

macOS 14.4 added Core Audio *process taps*, which let an app read system output
directly. CallScribe creates a private global tap wrapped in a private aggregate
device — so there's no BlackHole or virtual driver to install, no output device to
switch before a call, and you still hear the call normally while it records.

The microphone is recorded separately rather than mixed in, which is what makes
speaker labelling possible. Both tracks are converted to 16 kHz mono with
AVFoundation, transcribed by whisper.cpp, and merged by timestamp.

Whisper invents dialogue when fed near-silence, so three guards sit in front of
it: a level gate per track, collapsing of repeated cues, and cross-track echo
suppression that drops any cue where the *other* track is much louder over the
same moment — which can never discard speech said while the other side was quiet.

| Source | Role |
| --- | --- |
| `SystemAudioRecorder.swift` | Core Audio process tap |
| `MicRecorder.swift` | Microphone, separate track |
| `AudioPrep.swift` | Conversion, level analysis, normalization |
| `Transcriber.swift` | whisper.cpp, SRT parsing, echo suppression, merge |
| `ModelStore.swift` | First-run model download |

The speech engine is a statically linked `whisper-cli` (2.9 MB, Metal shaders
embedded) built by `vendor-whisper.sh` and copied into the bundle, so the app has
no runtime dependency on Homebrew, ffmpeg or Python. The finished bundle is 6.5 MB.

`./build.sh` rebuilds and reinstalls without re-running the prerequisite checks.
