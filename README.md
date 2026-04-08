# Santcasp

Prebuilt [snapclient and snapserver](https://github.com/snapcast/snapcast) binaries for Linux, macOS and Windows.

> Fork maintained by [Claudio Loletti](https://github.com/lollonet) — based on [Snapcast](https://github.com/snapcast/snapcast) by [Johannes Pohl](https://github.com/badaix).
> All credit for the original software goes to the upstream project and its [contributors](https://github.com/snapcast/snapcast/graphs/contributors).

## What is this?

Santcasp provides ready-to-use **snapclient** and **snapserver** packages so you don't have to build from source. The upstream project distributes packages via its own CI/release process; this fork offers additional per-distro builds and a Windows binary.

Client and server are packaged separately — install only what you need.

For documentation on how snapclient works, configuration, and audio backends, see the [upstream README](https://github.com/snapcast/snapcast#readme).

## Downloads

Grab the latest builds from the [Releases](https://github.com/lollonet/santcasp/releases) page.

### Available platforms

| Platform | Arch | Client | Server |
|----------|------|--------|--------|
| Ubuntu 24.04 | amd64 | `.deb`, `.tar.gz` | `.deb`, `.tar.gz` |
| Debian 12 (bookworm) | amd64 | `.deb`, `.tar.gz` | `.deb`, `.tar.gz` |
| Debian 13 (trixie) | amd64 | `.deb`, `.tar.gz` | `.deb`, `.tar.gz` |
| macOS | arm64 | `.tar.gz` | `.tar.gz` |
| Windows | x64 | `.zip` | — * |

\* Snapserver does not compile on Windows ([upstream limitation](https://github.com/snapcast/snapcast/issues/1380)).

### Install (.deb)

```bash
# Client
sudo dpkg -i santcasp_<version>_<distro>_amd64.deb
sudo apt-get install -f

# Server
sudo dpkg -i santcasp-server_<version>_<distro>_amd64.deb
sudo apt-get install -f
```

### Install (tar.gz / zip)

Extract and run the binary directly. On macOS, the bundled `libs/` directory must stay next to the binary. On Windows, keep all `.dll` files in the same directory as `snapclient.exe`.

## Versions

- **v0.34.0** — stable release, matches [upstream v0.34.0](https://github.com/snapcast/snapcast/releases/tag/v0.34.0)
- **v0.35.0-dev** — pre-release from the upstream `develop` branch

## Build info

- Boost 1.90.0
- Linux: built per-distro in Docker containers for correct library linking
- macOS: arm64 (Apple Silicon), CoreAudio backend, bundled Homebrew dylibs
- Windows: native MSVC 2022 build, vcpkg dependencies, WASAPI backend, SSL disabled (client only — snapserver is [not supported on Windows](https://github.com/snapcast/snapcast/issues/1380))

## Upstream

This project is a fork of **Snapcast** — a multiroom client-server audio player where all clients are time synchronized with the server to play perfectly synced audio.

- Upstream repo: https://github.com/snapcast/snapcast
- Original author: [Johannes Pohl](https://github.com/badaix)
- Fork maintainer: [Claudio Loletti](https://github.com/lollonet)
- Upstream releases: https://github.com/snapcast/snapcast/releases

## License

GPLv3+ — same as upstream. See [LICENSE](LICENSE).

Copyright (C) 2014-2025 Johannes Pohl (original Snapcast)
Copyright (C) 2026 Claudio Loletti (santcasp fork — adaptive latency, IPDV jitter measurement)

## Sources

- [pipe](doc/configuration.md#pipe): read audio from a named pipe
- [alsa](doc/configuration.md#alsa): read audio from an alsa device
- [librespot](doc/configuration.md#librespot): launches librespot and reads audio from stdout
- [airplay](doc/configuration.md#airplay): launches airplay and read audio from stdout
- [file](doc/configuration.md#file): read PCM audio from a file
- [process](doc/configuration.md#process): launches a process and reads audio from stdout
- [tcp](doc/configuration.md#tcp-server): receives audio from a TCP socket, can act as client or server
- [pipewire](doc/configuration.md#pipewire): direct audio capture from PipeWire
- [jack](doc/configuration.md#jack): receives audio from a Jack server
- [meta](doc/configuration.md#meta): read and mix audio from other stream sources

### Client

The client will use as audio backend the system's low level audio API to have the best possible control and most precise timing to achieve perfectly synced playback.

Available audio backends are configured using the `--player` command line parameter:

| Backend   | OS      | Description  | Parameters |
| --------- | ------- | ------------ | ---------- |
| alsa      | Linux   | ALSA | `buffer_time=<total buffer size [ms]>` (default 80, min 10)<br>`fragments=<number of buffers>` (default 4, min 2) |
| pulse     | Linux   | PulseAudio | `buffer_time=<buffer size [ms]>` (default 100, min 10)<br>`server=<PulseAudio server>` - default not-set: use the default server<br>`property=<key>=<value>` set PA property, can be used multiple times (default `media.role=music`)  |
| oboe      | Android | Oboe, using OpenSL ES on Android 4.1 and AAudio on 8.1 | |
| opensl    | Android | OpenSL ES | |
| coreaudio | macOS   | Core Audio | |
| wasapi    | Windows | Windows Audio Session API | |
| sld2      | All     | SDL2 Audio (e.g. for LG webOS TVs) | |
| file      | All     | Write audio to file | `filename=<filename>` (`<filename>` = `stdout`, `stderr`, `null` or a filename)<br>`mode=[w\|a]` (`w`: write (discarding the content), `a`: append (keeping the content) |

Parameters are appended to the player name, e.g. `--player alsa:buffer_time=100`. Use `--player <name>:?` to get a list of available options.  
For some audio backends you can configure the PCM device using the `-s` or `--soundcard` parameter, the device is chosen by index or name. Available PCM devices can be listed with `-l` or `--list`  
If you are running MPD and Shairport-sync into a soundcard that only supports 48000 sample rate, you can use `--sampleformat <arg>` and the snapclient will resample the audio from shairport-sync, for example, which is 44100 (i.e.  `--sampleformat 48000:16:*`)

## Test

You can test your installation by copying random data into the server's fifo file

```shell
cat /dev/urandom > /tmp/snapfifo
```

All connected clients should play random noise now. You might raise the client's volume with "alsamixer".
It's also possible to let the server play a WAV file. Simply configure a `file` stream in `/etc/snapserver.conf`, and restart the server:

```ini
[stream]
source = file:///home/user/Musik/Some%20wave%20file.wav?name=test
```

When you are using a Raspberry Pi, you might have to change your audio output to the 3.5mm jack:

``` shell
# The last number is the audio output with 1 being the 3.5 jack, 2 being HDMI and 0 being auto.
amixer cset numid=3 1
```

To setup WiFi on a Raspberry Pi, you can follow this [guide](https://www.raspberrypi.org/documentation/configuration/wireless/wireless-cli.md)

## Control

Snapcast can be controlled using a [JSON-RPC API](doc/json_rpc_api/control.md) over plain TCP, HTTP(S), or Websockets:

- Set client's volume
- Mute clients
- Rename clients
- Assign a client to a stream
- Manage groups
- ...

### WebApp

The server is shipped with [Snapweb](https://github.com/snapcast/snapweb), this WebApp can be reached under `http://<snapserver host>:1780` or `https://<snapserver host>:1788`, if SSL is enabled (see [HTTPS configuration](doc/configuration.md#https)).

<picture>
 <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/snapcast/snapweb/master/snapweb_dark.png">
 <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/snapcast/snapweb/master/snapweb_light.png">
 <img alt="Snapweb" src="https://raw.githubusercontent.com/snapcast/snapweb/master/snapweb_light.png">
</picture>

### Android client

There is an Android client [snapdroid](https://github.com/snapcast/snapdroid) available in [Releases](https://github.com/snapcast/snapdroid/releases/latest) and on [Google Play](https://play.google.com/store/apps/details?id=de.badaix.snapcast)

![Snapcast for Android](doc/snapcast_android_scaled.png)

### Contributions

There is also an unofficial WebApp from @atoomic [atoomic/snapcast-volume-ui](https://github.com/atoomic/snapcast-volume-ui).
This app lists all clients connected to a server and allows you to control individually the volume of each client.
Once installed, you can use any mobile device, laptop, desktop, or browser.

There is also an [unofficial FHEM module](https://forum.fhem.de/index.php/topic,62389.0.html) from @unimatrix27 which integrates a Snapcast controller into the [FHEM](https://fhem.de/fhem.html) home automation system.

There is a [snapcast component for Home Assistant](https://home-assistant.io/components/media_player.snapcast/) which integrates a Snapcast controller in to the [Home Assistant](https://home-assistant.io/) home automation system and a [snapcast python plugin for Domoticz](https://github.com/akamming/domoticz-snapcast) to integrate a Snapcast controller into the [Domoticz](https://domoticz.com/) home automation system.

There is also support for [Music Assistant](https://www.music-assistant.io), a powerful music management system designed to work with Home Assistant. It enables seamless streaming to Snapcast clients from local files or streaming services, with advanced features like multi-room playback, metadata management, and automated library organization.

For a web interface in Python, see [snapcastr](https://github.com/xkonni/snapcastr), based on [python-snapcast](https://github.com/happyleavesaoc/python-snapcast). This interface controls client volume and assigns streams to groups.

Another web interface running on any device is [snapcast-websockets-ui](https://github.com/derglaus/snapcast-websockets-ui), running entirely in the browser, which needs [websockify](https://github.com/novnc/websockify). No configuration needed; features almost all functions; still needs some tuning for the optics.

A web interface called [HydraPlay](https://github.com/mariolukas/HydraPlay) integrates Snapcast and multiple Mopidy instances. It is JavaScript based and uses Angular 7. A Snapcast web socket proxy server is needed to connect Snapcast to HydraPlay over web sockets.

For Windows, there's [Snap.Net](https://github.com/stijnvdb88/snap.net), a control client and player. It runs in the tray and lets you adjust client volumes with just a few clicks. The player simplifies setting up snapclient to play your music through multiple Windows sound devices simultaneously: pc speakers, hdmi audio, any usb audio devices you may have, etc. Snap.Net also runs on Android, and has limited support for iOS.

If you need an extremely small form factor and low power consumption, there is a microcontroller implementation of Snapclient written in C. The [**Snapclient for ESP32**](https://github.com/CarlosDerSeher/snapclient) project provides a lightweight, Snapcast client that runs on ESP32/ESP32-S2 microcontrollers and delivers excellent multiroom synchronization with very low latency.

There's [snapmixer](https://github.com/tremby/snapmixer), a text-mode volume control for all groups and clients.

## Setup of audio players/server

Snapcast can be used with a number of different audio players and servers, and so it can be integrated into your favorite audio-player solution and make it synced-multiroom capable.
The only requirement is that the player's audio can be redirected into the Snapserver's fifo `/tmp/snapfifo`. In the following configuration hints for [MPD](http://www.musicpd.org/) and [Mopidy](https://www.mopidy.com/) are given, which are base of other audio player solutions, like [Volumio](https://volumio.org/) or [RuneAudio](http://www.runeaudio.com/) (both MPD).

The goal is to build the following chain:

```plain
audio player software -> snapfifo -> snapserver -> network -> snapclient -> alsa
```

This [guide](doc/player_setup.md) shows how to configure different players/audio sources to redirect their audio signal into the Snapserver's fifo:

- [MPD](doc/player_setup.md#mpd)
- [Mopidy](doc/player_setup.md#mopidy)
- [FFmpeg](doc/player_setup.md#ffmpeg)
- [mpv](doc/player_setup.md#mpv)
- [MPlayer](doc/player_setup.md#mplayer)
- [Alsa](doc/player_setup.md#alsa)
- [PulseAudio](doc/player_setup.md#pulseaudio)
- [AirPlay](doc/player_setup.md#airplay)
- [Spotify](doc/player_setup.md#spotify)
- [Process](doc/player_setup.md#process)
- [Line-in](doc/player_setup.md#line-in)
- [VLC](doc/player_setup.md#vlc)
- [PlexAmp](doc/player_setup.md#plexamp)

## Roadmap

Unordered list of features that should make it into the v1.0

- [X] **Remote control** JSON-RPC API to change client latency, volume, zone,...
- [X] **Android client** JSON-RPC client and Snapclient
- [X] **Streams** Support multiple streams
- [X] **Debian packages** prebuild deb packages
- [X] **Endian** independent code
- [X] **OpenWrt** port Snapclient to OpenWrt
- [X] **Hi-Res audio** support (like 96kHz 24bit)
- [X] **Groups** support multiple Groups of clients ("Zones")
- [X] **Ports** Snapclient for Windows, Mac OS X,...
- [ ] **JSON-RPC** Possibility to add, remove, rename streams
- [ ] **Protocol specification** Snapcast binary streaming protocol, JSON-RPC protocol
