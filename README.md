<div align="center">

<img src=".github/assets/banner.svg" width="100%" alt="WoofPlay: video streaming, built natively in Swift" />

[![iOS 26+](https://img.shields.io/badge/iOS-26%2B-black?logo=apple)](#install)
[![SwiftUI](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)](app/WoofPlay)
[![Player: mpv](https://img.shields.io/badge/player-mpv-691f69)](https://mpv.io)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

**A free, open source video streaming app for iPhone, built from scratch in SwiftUI.**

<img src=".github/assets/home.png" width="31%" alt="Explore" />&nbsp;
<img src=".github/assets/player.png" width="31%" alt="Video page" />&nbsp;
<img src=".github/assets/subs.png" width="31%" alt="Following with New Videos" />

<sub>The app's screens, with video content replaced by placeholders.</sub>

</div>

## Highlights

| | |
| --- | --- |
| 📺 **YouTube and Twitch** | YouTube videos and Twitch live streams in one app, with one player, one live chat and one Follow button. |
| 🎧 **Background and Picture in Picture** | Audio keeps playing when you lock the phone, and the video can float over other apps. |
| ⏭️ **SponsorBlock** | The seek bar marks sponsors and other segments from the community list, and each kind can skip, show a button or do nothing. Dislike counts come from Return YouTube Dislike. DeArrow can replace clickbait titles and thumbnails. All three are optional. |
| 🧊 **Native iOS 26** | Liquid Glass buttons, zoom transitions, SF Symbols, system menus, tab bar and sheets. Dynamic Type, Dark Mode and Reduce Motion are respected. |

## Features

- Explore and Following feeds that mix YouTube videos and live Twitch streams
- Home starts with Quick Picks (pages of videos, with your pins first) and Live Now (followed Twitch channels on air)
- mpv player with quality, speed, captions, chapters and a floating miniplayer
- Live chat with Super Chats, Bits, subs and raids
- Comments with replies, sorting, editing and reporting
- Shorts, downloads, playlists, Watch Later and History
- Downloaded videos keep their description, chapters and channel for offline viewing
- Your own video and audio files: long press Downloads in Library and choose Add Files
- Torrents: share a magnet link to WoofPlay and its video and audio files land in Downloads
- Offline mode: without a connection, Home shows your downloads and a sleeping pup takes the title
- Several Google accounts and a Twitch account
- Watch Together, and playback on a TV
- Accent colours that also change the app icon

Removing Twitch's ads breaks Twitch's Terms of Service.

## Speed

- Feeds are parsed away from the main thread, so scrolling doesn't stall while a page loads.
- Explore opens on the last saved page while the new one arrives.
- Images are decoded at the size they are shown and held in a memory-limited cache.
- A stream address is reused for 30 minutes, so reopening a video starts at once.

## Privacy

- The app has no analytics and no server of its own. It talks to YouTube and Twitch directly.
- SponsorBlock and Return YouTube Dislike receive the ID of each video you watch. Turn them off in Settings to stop that.
- DeArrow is off by default. When on, its title list receives part of a code shared by many videos, and its thumbnail server receives the ID of each video with a new thumbnail, also in Incognito.
- Watch Together sends your room code, the video and its playback position to a Metrolist server. The server can be changed in Settings > Integrations.
- Torrents connect only with encryption, stop uploading once finished, and skip files that aren't video or audio. Other peers still see your IP address; only a VPN hides it.
- Crash reports stay on the phone until you choose to share them from Settings.

## Install

You need iOS 26 or later. This project does not publish IPA files, so you build your own.

1. Fork this repository.
2. Open the **Actions** tab and run the **Native app** workflow.
3. Download the `WoofPlay-native` artifact from the finished run. It contains an unsigned `WoofPlay.ipa` and expires after one day.
4. Sideload it with a tool that re-signs apps with your Apple ID, such as AltStore, SideStore or Sideloadly.
5. Open WoofPlay and sign in.

### Build on a Mac

You need Xcode 26.

```bash
brew install xcodegen cmake ninja boost
```

The torrent engine is compiled once from libtorrent's source, which takes a few minutes:

```bash
app/Torrent/build.sh
```

```bash
cd app && xcodegen generate && open WoofPlay.xcodeproj
```

## Credits

- [SwiftyTube](https://github.com/686udjie/SwiftyTube): Swift client for YouTube's InnerTube API
- [Trop](https://github.com/686udjie/Trop) and [Woof Music](https://github.com/LaskyWolf/WoofMusic): design and code this app is based on
- [mpv](https://mpv.io) and [MPVKit](https://github.com/streamyfin/MPVKit): video playback
- [libtorrent](https://libtorrent.org) and [Boost](https://www.boost.org): torrent downloads
- [SponsorBlock](https://sponsor.ajay.app), [DeArrow](https://dearrow.ajay.app) and [Return YouTube Dislike](https://returnyoutubedislike.com): community data

## License

[GPLv3](LICENSE). WoofPlay is not affiliated with, endorsed or sponsored by Google or YouTube.
