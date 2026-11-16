<div align="center">

<img src=".github/assets/banner.svg" width="100%" alt="WoofTube: YouTube, rebuilt natively for iPhone" />

[![iOS 26+](https://img.shields.io/badge/iOS-26%2B-black?logo=apple)](#install)
[![SwiftUI](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)](app/WoofTube)
[![Player: mpv](https://img.shields.io/badge/player-mpv-691f69)](https://mpv.io)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

**A free, open source YouTube client for iPhone, written from scratch in SwiftUI.**
It contains no YouTube code and shows no ads.

<img src=".github/assets/home.png" width="31%" alt="Explore" />&nbsp;
<img src=".github/assets/player.png" width="31%" alt="Video page" />&nbsp;
<img src=".github/assets/subs.png" width="31%" alt="Following with New Videos" />

<sub>The app's screens, with video content replaced by placeholders.</sub>

</div>

## Highlights

| | |
| --- | --- |
| 🚫 **No ads** | The app plays the video streams directly, so there are no ad breaks or banners. |
| 🎧 **Background and Picture in Picture** | Audio keeps playing when you lock the phone, and the video can float over other apps. |
| ⬇️ **Real downloads** | Videos download in the background and retry when YouTube's address expires. |
| ⏭️ **SponsorBlock** | The seek bar marks sponsors and other segments from the community list, and each kind can skip, show a button or do nothing. Dislike counts come from Return YouTube Dislike. DeArrow can replace clickbait titles and thumbnails. All three are optional. |
| 🧊 **Native iOS 26** | Liquid Glass buttons, zoom transitions, SF Symbols, system menus, tab bar and sheets. Dynamic Type, Dark Mode and Reduce Motion are respected. |

## Features

### Explore and Following
- Your own Explore feed, with filter chips and videos you have already seen moved out of the way
- Jump Back In card: the latest unfinished video and the followed Twitch channels that are live
- Filters stay at the top while you scroll, over a fade
- New Videos row on Following: today's uploads as cards in the colour of their cover, with Watch Later and Play buttons
- Shorts shelves (a two-column grid when a Shorts filter is on), community posts with polls, and playlists in the feed
- LIVE, New and UPCOMING marks under the channel picture, and Like and Dislike buttons under each card
- Long-press menus on videos: Watch Later, playlists, share, download and feedback

### Twitch
- Live streams, clips and past broadcasts in the same player as YouTube, without ads
- Live chat shared with YouTube's, including Super Chats, Bits, subs and raids
- Sign in with a device code and your own Twitch Client ID. Followed live channels appear in Jump Back In
- Twitch results in search and Up Next, a Streams filter, and creator pages
- One Follow button for YouTube and Twitch channels
- Removing Twitch's ads breaks Twitch's Terms of Service

### Player
- mpv engine with up to the quality you choose
- Playback speed, captions, audio tracks, chapters and thumbnail previews while seeking
- Live streams with live chat, and a double tap on the right to catch up when the stream trails
- Stable Volume evens out loud and quiet parts
- End screen cards over the last seconds of a video
- Haptics on seeks, skips, Play and Pause, speed and quality changes, and results
- Lock screen and Control Center controls, and AirPlay audio
- Miniplayer that floats above the tabs, with light from the video behind it and a progress line on its edge. Drag it to the bottom of the screen to close it
- Watch Together: watch the same video in sync with friends in a room, from the ••• menu
- Sleep timer and autoplay
- Reads less ahead on cellular and hotspots (30 seconds or 50 MB) than on Wi-Fi (2 minutes or 200 MB)

### Video page
- Likes, dislike estimates, Follow, Watch Later, playlists and share
- Comments and replies, sorted by Top or Newest, with likes and dislikes. Edit, delete or report a comment from its menu
- A time in a comment or description plays from there
- Up Next, channel pages with Shorts, Live, Podcasts and Releases tabs, and search inside a channel

### Shorts
- Vertical swipe through YouTube's own Shorts sequence
- The next Short's address is loaded ahead of the swipe

### Library
- Watch Later, Liked Videos and your playlists
- Create and edit playlists
- Downloads with quality choice, progress on each row and Cancel All

### Accounts and search
- Google sign-in inside the app, with several accounts, each keeping its own data
- History and the notification inbox, with an unread badge, are icons at the top of every tab
- Search with suggestions and history, filters for Never Seen and Live videos, and an incognito mode that stops recording it
- Opens YouTube links pasted in search, and `youtube://`, `vnd.youtube://` and `wooftube://` links from other apps
- Checks GitHub for a newer release and marks the profile picture when one is out
- Adds WoofTube to the share sheet, so a shared YouTube link opens in the app
- Plays the video on a TV linked with its code in Settings > Integrations, in YouTube on the TV or SmartTube
- Can stop saving search and watch history, in Settings > Privacy

### Look
- Accent colours that also change the app icon
- Light, dark or system appearance
- Icons with their own animation that follow the real state: the speed needle, the download ring, the sleep timer countdown
- Pages open by growing out of what you tapped
- Settings for the Library layout, the start tab and a left-handed tab bar
- Three cover sizes for videos and two for Shorts, the same across the app

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
- Crash reports stay on the phone until you choose to share them from Settings.

## Install

You need iOS 26 or later. This project does not publish IPA files, so you build your own.

1. Fork this repository.
2. Open the **Actions** tab and run the **Native app** workflow.
3. Download the `WoofTube-native` artifact from the finished run. It contains an unsigned `WoofTube.ipa` and expires after one day.
4. Sideload it with a tool that re-signs apps with your Apple ID, such as AltStore, SideStore or Sideloadly.
5. Open WoofTube and sign in.

### Build on a Mac

You need Xcode 26.

```bash
brew install xcodegen
```

```bash
cd app && xcodegen generate && open WoofTube.xcodeproj
```

## Account risk

Google can challenge or restrict an account used in an unofficial app, and posting comments is more visible than watching. Test with a second account.

## Project status

Version 1.6. Each feature still needs testing on more devices.

## Credits

- [SwiftyTube](https://github.com/686udjie/SwiftyTube): Swift client for YouTube's InnerTube API
- [Trop](https://github.com/686udjie/Trop) and [Woof Music](https://github.com/LaskyWolf/WoofMusic): design and code this app is based on
- [mpv](https://mpv.io) and [MPVKit](https://github.com/streamyfin/MPVKit): video playback
- [SponsorBlock](https://sponsor.ajay.app), [DeArrow](https://dearrow.ajay.app) and [Return YouTube Dislike](https://returnyoutubedislike.com): community data

## License

[GPLv3](LICENSE). WoofTube is not affiliated with, endorsed or sponsored by Google or YouTube.
