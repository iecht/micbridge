# MicBridge

English | [简体中文](README.zh-CN.md)

Use one Mac's microphone (say, a MacBook Air) as the audio input of another Mac on the same LAN that has none (say, a Mac mini). As soon as an app on the Mac mini starts recording, the MacBook's microphone switches on automatically.

## How it works

```
An app on the Mac mini starts recording from BlackHole
  → Receiver notices (Core Audio per-process recording state)
  → tells the MacBook over a persistent TCP connection to switch its mic on
  → Sender on the MacBook streams 16-bit PCM audio
  → Receiver plays it into BlackHole → the app hears the MacBook's mic
3 s after the app stops recording → Receiver tells the MacBook to switch the mic off (the orange indicator goes out)
```

- The two Macs find each other via Bonjour; no IP addresses to configure.
- The connection stays up, so audio usually arrives 0.4–1 s after recording starts.
- The MacBook's microphone is off whenever nothing is recording.

## Requirements

- Both Macs on macOS 14.2 or later, on the same local network.
- Xcode Command Line Tools (`xcode-select --install`) for building.
- On the receiving Mac (the one without a mic): the [BlackHole](https://existential.audio/blackhole/) virtual audio driver.

## Install

**Receiver (Mac mini)**

```bash
brew install --cask blackhole-2ch
git clone https://github.com/iecht/micbridge.git && cd micbridge
./install.sh receiver
```

- This makes BlackHole 2ch the system's default input device. If BlackHole doesn't show up after installing, restart the audio service with `sudo killall coreaudiod`.
- If Bonjour can't find the sender, give its address directly: `./install.sh receiver --host 192.168.x.x`
- You can feed a different virtual device instead, e.g. Rogue Amoeba Loopback: `./install.sh receiver --device "Loopback Audio"`

**Sender (MacBook Air)**

```bash
git clone https://github.com/iecht/micbridge.git && cd micbridge
./install.sh sender
```

On first run macOS asks for **Microphone** and **Local Network** access; allow both.

Both sides run in the background as login items: they start at login and restart if they crash. To remove either one, run `./install.sh uninstall` on that Mac.

## Usage

On the Mac mini, open any app that needs a microphone (video calls, dictation, recording software), choose **BlackHole 2ch** as the input (it's already the default), and start talking.

## Receiver options

| Option | Effect |
|---|---|
| `--host IP` | Connect to this address instead of using Bonjour |
| `--port N` | Port (default 50555; must match on both sides) |
| `--device NAME` | Virtual device to feed (default: BlackHole) |
| `--always-on` | Keep the sender's mic on all the time, for zero startup delay |
| `--no-set-default` | Don't change the system's default input device |

## Logs

- Sender: `~/Library/Logs/micbridge-sender.log`
- Receiver: `~/Library/Logs/micbridge-receiver.log`

## Known limitations

- A MacBook's microphone is **disabled in hardware while the lid is closed**, and a sleeping MacBook can't be reached. Keep the lid open and the machine awake (the sender prevents idle sleep while streaming).
- Because the connection is persistent, a recording only waits for the sender's microphone to start (typically 0.4–1 s). For no wait at all use `--always-on`, at the cost of the mic indicator staying lit.
- End-to-end latency is roughly 50–150 ms: fine for speech, calls and dictation, not for live instrument monitoring.
- Audio travels over the LAN unencrypted.

## License

MIT
