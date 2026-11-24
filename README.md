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

Download `CallScribe-<version>.dmg` from the
[latest release](https://github.com/chrisperkles/CallScribe/releases/latest),
open it and drag CallScribe into Applications. A microphone icon appears in the
menu bar.

Then, in the app:

1. Click the icon and pick a speech model — downloaded once (~550 MB), reused forever.
2. Start a recording. macOS asks for **Microphone** and **audio recording**
   permission. Both are required.

CallScribe starts with your Mac from then on.

### Updates

Once a day CallScribe checks for a new version. One it finds waits in the panel
as **Update to CallScribe …** — click it, then *Install and Relaunch*. Never in
the middle of a call: an update accepted while recording goes in once the
transcript is done. *Check for Updates…* at the bottom of the panel checks now.

### From source

```sh
git clone https://github.com/chrisperkles/CallScribe.git
cd CallScribe
./install.sh
```

The script installs what's missing (Xcode Command Line Tools, `cmake`), compiles
the speech engine, builds the app and launches it. `./build.sh` rebuilds and
reinstalls without the prerequisite checks. Releases are cut with `release.sh` —
see [RELEASING.md](RELEASING.md).

## Using it

Click the menu bar icon and choose:

- **Record Call** — Zoom, Teams, Meet, FaceTime, a phone call on speaker.
  Captures the far end (what your Mac plays) and you (your microphone) as two
  separate tracks, then merges them into one labelled transcript.
- **Record Meeting (room)** — people sitting together. Microphone only,
  transcribed without guessing who said what.

You don't have to remember: when another app opens the microphone — a Zoom or
Teams call, FaceTime, Meet in a browser tab — a small **Record this call?**
popup appears in the top-right corner. **Record** starts a call recording,
**Not now** (or waiting 25 seconds) makes it go away, and it asks once per call.
Nothing is recorded unless you click. Turn it off with *Ask to record when a
call starts* in the menu.

The same popup comes back when the call app lets go of the microphone while
you are recording: **Call ended — stop recording?** **Stop** transcribes right
away; ignoring it keeps recording, so a false alarm never cuts a call short.

**Stop & Transcribe** when done. A notification appears when the transcript is
ready. Output lands in `~/Recordings/CallScribe/<date and time> – <title>/`:

```
them.m4a         the far end
me.m4a           you
transcript.txt   merged, chronological, labelled
meta.json        title, short summary, names, to-dos (with Apple Intelligence)
```

### Titles

On macOS 26 or later with Apple Intelligence turned on, CallScribe reads the
transcript with Apple's on-device model and names the folder after the call —
`2026-11-23 13.22.17 – Reform – Challenge-App` instead of just the date. It runs
on the Mac like everything else; nothing is sent anywhere. Rename a folder in
Finder whenever a title is off: keep the date at the front and CallScribe shows
your name for it.

Everywhere else — macOS 15, a Mac without Apple Intelligence, Apple Intelligence
turned off or still downloading, or a call it declines to summarise — recordings
keep their date names, exactly as before. Turn titles off with *Name recordings
with Apple Intelligence* in the panel.

For recordings made before titles existed:

```sh
/Applications/CallScribe.app/Contents/MacOS/CallScribe --title-all --dry-run   # show the titles
/Applications/CallScribe.app/Contents/MacOS/CallScribe --title-all             # rename the folders
```

### Disk space

While recording, CallScribe writes uncompressed audio (about 1.2 GB per hour),
because that survives a crash mid-call. Once the transcript exists it is
replaced by AAC `.m4a` — about 40 MB per hour, the same for speech. Recordings
from earlier versions are compressed the same way the first time the new version
starts. A file is only deleted after its compressed copy has been checked.

## Getting good transcripts

- **Wear headphones on calls.** On speakers your microphone also picks up the far
  end; CallScribe detects and strips most of that echo, but headphones remove the
  problem entirely.
- **In a meeting room, put the Mac near whoever is talking**, or use an external
  mic. A laptop at the end of a long table gives thin audio, and thin audio
  transcribes badly.
- **Set your languages** in the panel (Languages: German, English, …). With one
  language everything is transcribed in it; with several, each side of the call
  gets whichever of them it sounds like. Left on "any", a call can come out in
  a language nobody spoke.

## Before recording other people

Recording a conversation is regulated differently depending on where the
participants are. In Austria and most of the EU, tell them and get their
agreement. CallScribe does not announce itself.

## Settings

```sh
defaults write at.skyline.CallScribe languages "de,en"     # what the panel sets; "" = any
defaults write at.skyline.CallScribe language de           # older key: always this one, overrides the panel
defaults write at.skyline.CallScribe recordingsRoot ~/Documents/Calls
defaults write at.skyline.CallScribe modelPath /path/to/ggml-model.bin
defaults write at.skyline.CallScribe nameRecordings -bool false   # no titles
defaults write at.skyline.CallScribe compressAudio -bool false    # keep the raw .caf files
defaults write at.skyline.CallScribe corrections "Lansing=Lenzing, Kai-Burg=KRAIBURG"
```

`corrections` fixes names speech recognition keeps mishearing, as whole words
and ignoring case, in every new transcript and in the titles.

Read again at the start of every recording — no restart needed.

## When something's wrong

```sh
/Applications/CallScribe.app/Contents/MacOS/CallScribe --selftest 10
```

Records ten seconds, transcribes it, and prints a diagnostic: engine and model in
use, whether permissions were granted, and the measured level of each track. Add
`--meeting` to test room mode.

```sh
/Applications/CallScribe.app/Contents/MacOS/CallScribe --transcribe ~/Recordings/CallScribe/"2026-11-10 14.01.18"
```

Rebuilds `transcript.txt` from the audio already in a session folder (`.caf` or
`.m4a`), for a recording whose transcription failed or that you repaired by hand.

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

One trap in the level gate: while a call app runs voice processing on the
built-in microphone (Safari/WebRTC, Teams, Zoom), other apps get the raw,
unamplified mic array — three channels, speech about 35 dB below normal. Such a
track is judged against its own room tone instead, lifted, and transcribed in the
language the other side was heard in.

Whisper's own language guess listens to a track's first 30 seconds only, which
on a call is hellos, waiting or silence; one German call came out Icelandic on
one side and Spanish on the other. CallScribe instead cuts each track's three
busiest 30-second stretches (most time within 20 dB of its loudest speech), asks
whisper for the language of each, and lets only the languages set in the panel
win. With a single language set, there is no guessing at all.

| Source | Role |
| --- | --- |
| `SystemAudioRecorder.swift` | Core Audio process tap |
| `MicRecorder.swift` | Microphone, separate track |
| `AudioPrep.swift` | Conversion, level analysis, normalization |
| `Transcriber.swift` | whisper.cpp, SRT parsing, echo suppression, merge |
| `Titler.swift` | Titles with the on-device Apple Intelligence model (macOS 26+) |
| `AudioCompressor.swift` | Raw .caf → AAC .m4a once transcribed |
| `SessionFolder.swift` | Folder names, titles, finding a session's audio |
| `ModelStore.swift` | First-run model download |
| `CallDetector.swift` | Spots other apps opening the microphone |
| `CallPrompt.swift` | The record / stop popup |
| `Updater.swift` | In-app updates (Sparkle), held back while recording |

The speech engine is a statically linked `whisper-cli` (2.9 MB, Metal shaders
embedded) built by `vendor-whisper.sh` and copied into the bundle, so the app has
no runtime dependency on Homebrew, ffmpeg or Python. The finished bundle is 6.5 MB.
