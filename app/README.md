# WoofPlay native app

A SwiftUI player for YouTube, Twitch, your own video files and torrents.

## Build

Building needs Xcode 26. Linux users can use the `Native app` GitHub Actions workflow, which produces an unsigned IPA that lasts one day.

On a Mac:

```bash
brew install xcodegen cmake ninja boost
cd app
Torrent/build.sh
xcodegen generate
open WoofPlay.xcodeproj
```

## Account risk

Google can challenge or restrict an account used in an unofficial app, and posting comments is more visible than watching. Test with a second account.

## Twitch

WoofPlay plays Twitch live channels and takes Twitch's ads out of the stream. This breaks Twitch's Terms of Service.

Signing in needs your own Twitch app: register one at [dev.twitch.tv/console](https://dev.twitch.tv/console) with the **Public** client type and paste its Client ID in the sign-in sheet.

## License

GPL-3.0, because it uses [SwiftyTube](https://github.com/686udjie/SwiftyTube) and code from [Trop](https://github.com/686udjie/Trop).
