# Silent Whisper

Push-to-talk dictation for macOS. Hold **right ⌥**, talk, let go — the text is transcribed
on-device and pasted where your cursor already is.

No account, no network, no subscription. Whisper runs locally through
[WhisperKit](https://github.com/argmaxinc/WhisperKit) on the Neural Engine.

## Install

```sh
brew install --cask silentwhisperhq/tap/silentwhisper
```

Or grab the latest `.zip` from [Releases](https://github.com/silentwhisperhq/SilentWhisper/releases),
unzip, and drag `SilentWhisper.app` to `/Applications`.

macOS will ask for two permissions on first launch:

- **Microphone** — to hear you.
- **Accessibility** — for the global hotkey and for pressing ⌘V on your behalf.

The app updates itself from here on: it checks GitHub daily and offers the new build in Settings.

## Use

| | |
|---|---|
| Hold right ⌥ | record while held, transcribe on release |
| Click the blob | toggle recording |
| Menu bar icon | Settings, quit |

The blob only appears while something is happening, then fades out. It lives above every
window and follows you across Spaces and full-screen apps.

### Languages

Language is a list of checkboxes, and the number you tick is the setting. None means Whisper
detects from all 99, which is where a stray language comes from on short takes. One pins it —
no detection runs, so it cannot land anywhere else. Several keep detection inside the languages
you actually speak. Ticking the two or three you use is usually the right answer.

A take is one language either way: Whisper labels each 30-second window once, so half Turkish
and half French in a single recording does not work.

The `.en` models are English-only and will return confident nonsense for anything else — pick a
model without the `.en` suffix. Bigger models are more accurate and slower; `small` is the
smallest one that handles non-English properly.

### Microphone

Follows the system input and re-reads it on every take, so switching devices needs no restart.
Pick a specific mic in Settings to ignore the system default — if it is unplugged or asleep,
the app falls back to the system input rather than failing.

## Build from source

```sh
scripts/build.sh          # builds SilentWhisper.app
scripts/makeicon.sh       # regenerates the icon
scripts/release.sh 1.0.1  # builds, tags, and publishes a GitHub release
.build/debug/SilentWhisper --selftest   # checks the blob animation maths
```

Requires Swift 5.10+ and macOS 14+.

**On signing:** without an Apple developer certificate the app is signed ad-hoc, and macOS
revokes its Accessibility permission on every rebuild. If the hotkey stops working after a
rebuild, remove the stale entry in *System Settings → Privacy & Security → Accessibility*
and add the app again. With a real certificate in your keychain, `build.sh` picks it up
automatically and the grant sticks.

---

## Licence

MIT — free and open source, for anyone, including commercially. No licence key, no account, no
analytics. See [LICENSE](LICENSE).

Transcription runs on-device. The network is touched to download a model the first time you pick
it, to check for updates, and — only if you switch the AI pass on — to reach the provider you
chose.
