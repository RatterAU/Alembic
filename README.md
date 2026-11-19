<div align="center">

<img src="docs/icon-1024.png" width="128" alt="Alembic icon: a white alembic flask with purple liquid on a purple gradient">

# Alembic

**Any video, straight onto your iPhone. No computer, no cable, no dodgy websites.**

Copy a link, paste it, tap Download. The real yt-dlp and FFmpeg do the work on the phone itself.

<br>

<picture>
  <source srcset="https://github.com/RatterAU/Alembic/raw/main/docs/promo/alembic-film.avif" type="image/avif">
  <img src="docs/promo/alembic-film.jpg" width="100%" alt="Alembic in 40 seconds, filmed in the real app. Any video, straight onto your iPhone. Copy a link, paste it, and every format on offer appears. Pick the quality and see the file size first, 81.5 MB down to 41.7 MB. Pick the container; if it can't hold the streams, Alembic warns you and one tap fixes it. Just the audio, as M4A, MP3, Opus, FLAC or WAV. Just the part you want, by time or by chapter. Sponsor segments cut out with no re-encoding, the audio still in sync. Cover art, chapters and subtitles written into the file, straight to Photos. Four downloads at once. No ads, no accounts.">
</picture>

<sub>Recorded in the real app · [download it with sound](docs/promo/alembic-film.mp4) (MP4, 1080p)</sub>

<br><br>

### [Get it for iPhone](#install-it)

<sub>Free, no App Store, no sign-up. iOS 26 or newer. Latest: [version 1.0](../../releases/latest).</sub>

<sub>**Already use LiveContainer, SideStore or AltStore?** Add [my app source](https://ratterau.github.io/apps/) once and install and update Alembic with one tap.</sub>

<br>

![iOS 26+](https://img.shields.io/badge/iOS-26%2B-3B1D5C?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white)
![GPL-3.0](https://img.shields.io/badge/licence-GPL--3.0-555?style=flat-square)
![No ads](https://img.shields.io/badge/ads-none-1F7A4D?style=flat-square)
![No accounts](https://img.shields.io/badge/accounts-none-1F7A4D?style=flat-square)
![No tracking](https://img.shields.io/badge/analytics-none-1F7A4D?style=flat-square)

[**Why**](#why) · [**What it does**](#what-it-does) · [**Install it**](#install-it) · [**Under the hood**](#under-the-hood) · [**Security**](#security) · [**Building**](#building-it-yourself)

</div>

---

## Why

You want a video on your iPhone. Not a link to it: the actual file, for the flight, the gym, or before it disappears.

Here's how that usually goes. Open the laptop. Find a downloader website, dodge the fake *Download* buttons and the pop-ups, and get back a 720p file with the sound slightly off. Then get it onto the phone: plug in a cable, wait on AirDrop, or upload it to the cloud just to download it again. Ten minutes and two devices for one video.

Alembic is the proper way. Copy the link on your iPhone, paste it, tap Download. You pick the quality and get exactly that, and it's in your library a few seconds later. No computer, no cable, no ads, no nonsense.

Under the hood it's [yt-dlp](https://github.com/yt-dlp/yt-dlp), the open-source downloader power users swear by, running for real on the phone. No server in the middle, nothing to pay for, nothing watching.

<br>

<div align="center">

<img src="docs/screenshots/media.png" width="260" alt="Spring, a Blender open movie, looked up in Alembic: thumbnail, title, Video or Audio only, quality, video codec, audio codec and container choices">
&nbsp;
<img src="docs/screenshots/downloads.png" width="260" alt="Four downloads at once: Spring, Big Buck Bunny saved as M4A, Tears of Steel and Sintel downloading with progress">
&nbsp;
<img src="docs/screenshots/library.png" width="260" alt="The library: Tears of Steel, Spring, Sintel and Big Buck Bunny with thumbnails, format, length and size">

<sub><b>Paste it</b> · <b>Pick it</b> · <b>Keep it</b></sub>

</div>

## What it does

**Paste a link, see what's there.** YouTube, X, Instagram, Reddit, TikTok or [any of the sites yt-dlp supports](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md). Alembic shows the title, length and every stream on offer.

**Simple when you want it, exact when you need it.** Pick a quality and you're done. Or choose codecs (AV1, VP9, HEVC, H.264 for video; Opus or AAC for audio) and a container (MP4, MKV, WebM, MOV). Or turn on *Choose exact streams* and pair any video stream with any audio stream, like `yt-dlp -F`. Containers that can't hold your streams are caught before you download, not after.

**Audio only.** M4A, MP3, Opus, FLAC or WAV. When the stream is already in the format you asked for, it's saved as is, with no re-encoding.

**Just the part you want.** Download a clip by time or by chapter. Only that part is fetched.

**Finished files are finished.** Cover art, title, artist and chapters are written into the file. Subtitles in any language, including YouTube's automatic ones. SponsorBlock cuts out sponsors, self-promos and subscribe reminders, with no re-encoding and the audio still in sync.

**Playlists and channels.** Tick the videos you want and choose one quality for all of them.

**A library on the phone.** Everything you've downloaded, with thumbnails, search and Apple's own player (AirPlay, Picture in Picture). Save to Photos, share, or turn MKV and WebM into MP4 without losing quality. Every file is in the Files app too.

**Several at once.** Up to five downloads in parallel, with progress, speed and time left. Cancel any of them, or retry and it picks up where it stopped.

**Always current.** Sites change and yt-dlp keeps up. Alembic updates yt-dlp by itself, from yt-dlp's official releases only, and only after checking yt-dlp's signature (see [Security](#security)).

<div align="center">
<br>
<img src="docs/screenshots/media-dark.png" width="260" alt="Spring looked up in dark mode, with its thumbnail, quality and codec choices">
&nbsp;
<img src="docs/screenshots/library-dark.png" width="260" alt="The library in dark mode: Tears of Steel, Spring, Sintel and Big Buck Bunny">
&nbsp;
<img src="docs/screenshots/settings.png" width="260" alt="Settings: yt-dlp version, release channel, automatic updates and parallel downloads">

<sub>Real screenshots, with Blender Foundation open movies.</sub>
</div>

> [!NOTE]
> Alembic never signs in to anything and never touches your accounts or cookies, so there's no account to get banned.

## Install it

It isn't on the App Store. You need an iPhone on iOS 26 or newer and [LiveContainer](https://github.com/LiveContainer/LiveContainer) (or SideStore/AltStore).

> [!TIP]
> **The easy way:** open **[ratterau.github.io/apps](https://ratterau.github.io/apps/)** on your iPhone and tap **LiveContainer**. Then install Alembic from LiveContainer's **Sources** tab. Updates show up there by themselves, and it doesn't use one of your 3 app slots.

Or, in LiveContainer: tap **+** → **Install from URL** and paste:

```
https://github.com/RatterAU/Alembic/releases/latest/download/Alembic.ipa
```

New to LiveContainer? The step-by-step setup (iloader, pairing file, SideStore, refreshing every 7 days) is in [Contrail's install guide](https://github.com/RatterAU/Contrail#option-a-livecontainer--sidestore). It works the same for Alembic.

**Where your files go:** the Files app, under *On My iPhone → Alembic*. Under LiveContainer, look in LiveContainer's folder under *Data → Application*.

**Keep Alembic open during big downloads.** iOS pauses apps in the background after a short while. Alembic lets you know if that happens, and Retry picks up where it stopped.

## Under the hood

iOS apps can't run other programs, so Alembic brings everything inside the app:

| Part | How |
|:--|:--|
| **yt-dlp** | The official release, running on CPython 3.13 ([BeeWare](https://github.com/beeware/Python-Apple-support)) embedded in the app. Unchanged, so it behaves exactly like yt-dlp on a computer |
| **FFmpeg 9** | Built for iOS with only what yt-dlp needs (7 MB). `ffmpeg` and `ffprobe` are built as libraries; when yt-dlp starts them, Python's `subprocess` runs them in-process on a thread, wired to real pipes, so yt-dlp needs no changes |
| **YouTube challenges** | yt-dlp normally needs Deno or Node for these. Alembic runs yt-dlp's own solver script in WebKit, in a locked-down hidden page with no network access |
| **SponsorBlock cuts** | Each cut is moved to the next keyframe before yt-dlp joins the pieces, so they're joined without re-encoding and the audio stays in sync |
| **The app** | SwiftUI, Liquid Glass, iOS 26+ |

```
App/          SwiftUI app, Python host (PythonHost.m), in-process FFmpeg runner (ToolRunner.c)
Engine/       The Python side: api.py (commands and jobs), procs.py (subprocess bridge),
              jsc.py (WebKit solver), sponsorblock.py (keyframe-aligned cuts),
              updater.py + pgp.py (signed updates), tests/
scripts/      build-ffmpeg.sh, fetch-engine.sh, install-python.sh (Xcode build phase)
project.yml   XcodeGen project
```

## Security

- **Every download is pinned.** FFmpeg, LAME, Opus, Mbed TLS, BeeWare's Python and yt-dlp are fetched by SHA-256 or signature. The Python packages are installed with `pip --require-hashes`.
- **yt-dlp updates are signature-checked.** An update is used only if yt-dlp's `SHA2-256SUMS` carries a valid signature from yt-dlp's release key (fingerprint `AC0CBBE6848D6A873464AF4E57CF65933B5A7581`, pinned in the app), and the file matches that checksum. The version is read from inside the verified file. Older versions are refused, and each update is tested before use: if it doesn't work, the previous version stays.
- **Nothing runs from outside the app.** yt-dlp plugins are off. Links are never passed as command-line options.
- **FFmpeg checks HTTPS certificates** against the bundled, hash-pinned `certifi` list.

## Building it yourself

You need a Mac with Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and CMake (`brew install xcodegen cmake`).

```bash
git clone https://github.com/RatterAU/Alembic.git && cd Alembic
scripts/build-ffmpeg.sh       # FFmpeg + LAME + Opus + Mbed TLS for iPhone, simulator and Mac (about 15 min)
scripts/fetch-engine.sh       # Python support, yt-dlp and Python packages, all verified
xcodegen generate
xcodebuild -scheme Alembic -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
python3 Engine/tests/smoke.py /tmp/alembic-tests   # engine tests on the Mac (needs network)
```

## Privacy

No accounts, no ads, no analytics. Alembic only connects to the sites you download from, to GitHub to update yt-dlp, and, if you turn on sponsor cutting, to the SponsorBlock service.

## Licence

Alembic is free software under the [GNU GPL 3.0 or later](LICENSE).

It's built on [yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense), [FFmpeg](https://ffmpeg.org) (LGPL 3.0+), [LAME](https://lame.sourceforge.io) (LGPL), [Opus](https://opus-codec.org) (BSD), [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) (Apache 2.0), [Python](https://www.python.org) (PSF) via [BeeWare](https://github.com/beeware/Python-Apple-support), [Mutagen](https://github.com/quodlibet/mutagen) (GPL 2.0+) and [certifi](https://github.com/certifi/python-certifi) (MPL 2.0). The screenshots show [Blender Foundation](https://studio.blender.org/films/) open movies (CC BY).
