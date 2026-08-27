# CallScribe

A menu bar button that records your Mac — both sides of a call, or a meeting in
the room — and transcribes it locally the moment you stop. Nothing is uploaded;
the speech engine runs on your own machine.

## For colleagues: installing

1. Open the DMG you were sent and drag **CallScribe** to **Applications**.
2. Launch it. A microphone icon appears in the menu bar, top right.
3. Click it once and choose a speech model. It downloads once (about 550 MB) and
   is reused forever after.
4. The first recording asks for two macOS permissions — **Microphone** and
   **audio recording**. Both are required; click Allow.

That's it. CallScribe starts automatically with your Mac from then on.

## Using it

Click the menu bar icon and pick one:

- **Record Call** — for Zoom, Teams, Meet, FaceTime, a phone call on speaker.
  Captures the other side (what your Mac plays) and you (your microphone) as two
  separate tracks.
- **Record Meeting (room)** — for people sitting together. Microphone only,
  transcribed without guessing who said what.

Click **Stop & Transcribe** when you're done. A notification appears when the
transcript is ready, usually well under a minute.

Everything lands in `~/Recordings/CallScribe/<date and time>/`:

```
them.caf         the other side, untouched
me.caf           you, untouched
transcript.txt   merged, chronological, labelled
```

Calls come out like this:

```
[00:00:00] Them:
  Could you send the revised quote before Friday?

[00:00:09] Me:
  Yes — I'll have it over to you Thursday morning.
```

## Getting good transcripts

- **Wear headphones on calls.** On speakers your microphone also picks up the
  other side. CallScribe detects and removes most of that echo, but headphones
  remove the problem entirely.
- **For meetings in a room, put the Mac near whoever is speaking**, or use an
  external microphone. A laptop at the far end of a table gives thin audio, and
  thin audio transcribes badly.
- Language is auto-detected per recording. If your calls are always German,
  pinning it improves accuracy: `defaults write at.skyline.CallScribe language de`

## Before you record other people

Recording a conversation is regulated differently depending on where everyone
is. In Austria and most of the EU, tell the other participants and get their
agreement. CallScribe does not announce itself.

## Settings

```sh
defaults write at.skyline.CallScribe language de          # or "auto"
defaults write at.skyline.CallScribe recordingsRoot ~/Documents/Calls
defaults write at.skyline.CallScribe modelPath /path/to/ggml-model.bin
```

Re-read at the start of every recording — no restart needed.

## If something goes wrong

```sh
/Applications/CallScribe.app/Contents/MacOS/CallScribe --selftest 10
```

Records ten seconds, transcribes it, and prints a full diagnostic: which engine
and model it used, whether permissions were granted, and the measured audio
level of each track. Add `--meeting` to test room mode.

---

## For maintainers

Self-contained by design: the speech engine is a statically linked `whisper-cli`
(2.9 MB, Metal shaders embedded) built by `vendor-whisper.sh` and shipped inside
the bundle. There is no Homebrew, ffmpeg, or Python dependency — audio conversion
uses AVFoundation directly.

```sh
./build.sh          # build + install locally to /Applications
./release.sh        # notarized DMG + signed Sparkle appcast
```

Building needs Xcode Command Line Tools and `cmake` (`brew install cmake`).
See [RELEASING.md](RELEASING.md) for certificates, notarization and hosting.

| Source | Role |
| --- | --- |
| `SystemAudioRecorder.swift` | Core Audio process tap — system output, no virtual driver |
| `MicRecorder.swift` | Microphone, recorded to a separate track |
| `AudioPrep.swift` | Native 16 kHz mono conversion, level analysis, normalization |
| `Transcriber.swift` | whisper.cpp, SRT parsing, echo suppression, merge |
| `ModelStore.swift` | First-run model download |
| `Updater.swift` | Sparkle in-place updates |
