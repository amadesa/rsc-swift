# rsc-swift

A native iOS/iPadOS RuneScape Classic client, built around the
[2003scape/rsc-c](https://github.com/2003scape/rsc-c) game client with a
Swift/Metal platform layer and a touch-first UI. It defaults to the
[RSC Preservation](https://rsc.vet) world (`game.openrsc.com:43596`).

Runs on iOS/iPadOS 12.2 and later. A separate legacy build runs on 32-bit
devices stuck on iOS 10, such as the iPad 4 and iPhone 5 (see
[Legacy build](#legacy-build-ios-10-32-bit)). An Apple Watch app (watchOS 7
and later) plays the same game on the wrist, through
[rsc-relay](relay/README.md) (see [Apple Watch](#apple-watch)).

## Features

- The full rsc-c client: protocol, world, software renderer and the touch
  controls from its Android/web builds. Tap = left click, hold = right click,
  horizontal drag = rotate camera, vertical drag or pinch = zoom.
- Metal display at any screen size and orientation, kept clear of the notch
  and rounded corners, with a Core Graphics fallback for devices without
  Metal.
- Native keyboard for chat and text boxes: hold-to-delete, paste, and a bar
  above the keyboard showing what you're typing. Hardware keyboards work
  too (arrows rotate the camera).
- Login screen with **Login**, **Register**, **Worlds**, **Options** and
  **Accounts** buttons, stacked, or in a grid where they don't fit (iPad).
  Register opens the selected world's sign-up page in Safari.
- **Accounts:** logins the server accepted are saved in the keychain, to
  log in again with a tap. Each can be shared with the Apple Watch or kept
  off it.
- World list with **Add world** (import an rscplus world `.ini` from Files
  or a URL, or enter a host and port by hand) and **Remove**.
- Camera defaults to manual on touch screens until you pick a mode in game.
- Combat style is remembered per character and world.
- Hits, prayer and fatigue bars along the bottom of the screen.
- **Alerts:** a vibration or notification for low hits, fatigue, standing in
  the same spot, being about to be logged out, death, a full inventory,
  level ups and messages. Each can be turned on or off in Settings > RSC >
  Alerts.
- **Stay connected in the background** (on by default, also under
  Additional options > Game): the game keeps its connection while you use
  another app.

## Installing

All from [amadesa.github.io/rsc-swift](https://amadesa.github.io/rsc-swift/):

- **AltStore or SideStore** (iOS 12.2 and later, with the Apple Watch
  app): add the source `https://amadesa.github.io/rsc-swift/apps.json`.
  Updates then show up in the app.
- **Jailbroken devices** (Cydia, Sileo or Zebra): add the repo
  `https://amadesa.github.io/rsc-swift/repo/`. It has RSC for iOS 12.2 and
  later (rootful and rootless) and for iOS 10 on 32-bit devices such as
  the iPad 4. iPhone and iPad only: a jailbreak can't install the watch
  app.
- **Sideloading** the IPAs from the
  [releases](https://github.com/amadesa/rsc-swift/releases), e.g. with
  [Sideloadly](https://sideloadly.io).

The source, the repo and the page are built by
`scripts/make-distribution.py` from a release's IPAs, into the `gh-pages`
branch.

## Building

Requires Xcode 16 or later.

1. Clone the repo and open `rsc-swift.xcodeproj`.
2. To run on a device, copy `Config/Signing.local.xcconfig.example` to
   `Config/Signing.local.xcconfig` and fill in your Apple developer team ID
   and a bundle identifier prefix. That file is ignored by git, so your
   signing details stay out of the repo. The simulator needs no signing.
3. Run the `rsc-swift` scheme. It includes the Apple Watch app, which the
   `rsc-watch` scheme builds on its own (for example for the watch
   simulator).

From the command line:

```
xcodebuild -project rsc-swift.xcodeproj -scheme rsc-swift \
  -destination 'generic/platform=iOS Simulator' build
```

Set your team in `Signing.local.xcconfig` rather than in Xcode's
Signing & Capabilities tab, which would write it into the project file.

## Legacy build (iOS 10, 32-bit)

Xcode 16 can't build for 32-bit (armv7) devices or target iOS 10, so
`scripts/build-legacy.sh` builds those with the command-line tools from
Xcode 13.4.1 instead:

1. Download Xcode 13.4.1 from
   [developer.apple.com/download/all](https://developer.apple.com/download/all)
   (any Apple ID) and unpack it, e.g. to `/Applications/Xcode_13.4.1.app`.
   It doesn't open on current macOS, but its build tools still work, and
   your default Xcode isn't affected.
2. Run `XCODE13=/Applications/Xcode_13.4.1.app scripts/build-legacy.sh`.
   The unsigned `.ipa` is written to `build/legacy/`.
3. Install it with [Sideloadly](https://sideloadly.io), which supports old
   iOS versions (AltStore and SideStore need iOS 12.2 or later).

Xcode 13 can't open this project's file format, so the script spells out
the build: it compiles the C core and Swift app for armv7, bundles the Swift
runtime (iOS 10 has none built in), and uses plain icon and launch image
files instead of the asset catalog and storyboard, since Xcode 13's
Interface Builder tools don't run on current macOS. On devices without
Metal the app shows frames with Core Graphics (`FrameDisplay.swift`). The
Swift code is kept compatible with Swift 5.6 and iOS 10.

## Apple Watch

The watch app runs the same rsc-c client as the iPhone, full screen, with
its own controls:

- **Tap** to walk and click, **hold** for the right-click menu (shown as a
  list), and **drag** to rotate the camera.
- **Turn the Digital Crown** to bring out the inventory, map, stats, magic,
  friends and options icons. An open tab covers the screen, with a header to
  go to the previous or next tab or close it; the crown also steps through
  the tabs.
- Hits, prayer and fatigue in the bottom left, and the combat style in the
  bottom right (tap to change it).
- Saved accounts as large buttons that log in with a tap, since there's no
  way to type a password on the game's login screen.
- The same alerts as the iPhone, as taps on the wrist.
- It keeps running with the wrist down for up to an hour at a time.

How the tabs open can be changed in game, under Options on the watch or
Additional options > Game on the iPhone: **Tab panels** full screen, beside
the icons, or off (placed as on the iPhone), and the **keyboard button** on
or off.

### Setting it up

watchOS doesn't let apps open the game's TCP connection, so the watch plays
through [rsc-relay](relay/README.md), a small program that runs on a
computer at home (or a server) and passes the game's traffic on over HTTPS.

1. Run `rsc-relay` and `rsc-relay pair` on that computer (see
   [relay/README.md](relay/README.md)).
2. On the iPhone, open **Accounts > Relay**, tap the relay and type the
   pairing code.
3. Log in on the iPhone, which saves the account.
4. Open RSC on the watch with the iPhone nearby. It receives the iPhone's
   relay, accounts, worlds, options and alert settings; tap an account to
   play.

Away from home the watch reaches the relay over any address it lists
(home network, public IP, Tailscale or a Tailscale Funnel URL), and as a
last resort through the iPhone.

## Project layout

```
Config/                       shared build settings, signing template, Info.plist
rsc-swift/
  Core/                       rsc-c sources (upstream 2ce1b5a) with iOS patches
    mudclient-ios.c           iOS platform layer: input queue, touch gestures,
                              frame handoff, sound/keyboard/URL/world callbacks
    rsc-bridge.h              C API used from Swift
    relay-transport.c         lets packet-stream.c use the relay like a socket
  Resources/cache/            game data (.jag/.mem) from rsc-c
  AppDelegate.swift           UIKit app entry point (makes the window before iOS 13)
  SceneDelegate.swift         makes the window on iOS 13+ (scene life cycle)
  GameClient.swift            starts the game thread, routes callbacks
  GameViewController.swift    layout, game resolution, hardware keys, alerts
  GameView.swift              touches, keyboard proxy text fields
  FrameDisplay.swift          Metal display, or Core Graphics without Metal
  FrameRenderer.swift         uploads frames to a Metal texture
  FrameShaders.metal
  GameAudio.swift             8kHz sound effects via AVAudioEngine
  RelayTransport.swift        game connection over HTTPS through rsc-relay
  Settings.bundle             Settings app page for the relay
  AddWorldController.swift    "Add world" sheet
  WorldConfig.swift           world .ini parsing
  AppDirectories.swift        where files go (a folder of its own on a jailbreak install)
  AccountStore.swift          saved logins, in the keychain
  AccountsController.swift    "Accounts" screen
  GameStatus.swift            hits, prayer etc. from the game, for alerts and the watch
  GameAlert(s).swift          alerts: haptics in the app, notifications in the background
  PhoneWatchSync.swift        sends the watch its settings and accounts
  RelayController.swift       Accounts > Relay: pairing with rsc-relay
  RelayPairing.swift          the pairing request
  RelayRoute.swift            picks the relay address that answers first
  RelayCheck.swift            explains why a relay connection failed
Watch/
  RSCWatchApp.swift           Apple Watch app entry point
  WatchGame.swift             runs the client on the watch, through the relay
  GameScreenView.swift        the game, stats overlay, crown and touches
  AccountScreen.swift         the watch's login screen
  WatchSync.swift             receives what the iPhone sends
  KeepAlive.swift             keeps the game running with the wrist down
scripts/rsc-c-ios.patch       every change made to the upstream rsc-c files
scripts/build-legacy.sh       32-bit iOS 10 build using Xcode 13's tools
scripts/make-distribution.py  AltStore/SideStore source and Cydia repo for a release
relay/                        HTTPS-to-TCP relay so Apple Watch can connect (see relay/README.md)
```

## How it works

- The C client runs its own blocking loop (`mudclient_run`) on a dedicated
  thread. Swift posts touches and keys into a locked queue that
  `mudclient_poll_events` drains on the game thread.
- Each `surface_draw` copies the finished software-rendered frame into a
  shared buffer, and the display shows the newest one: `FrameRenderer`
  uploads it to Metal, or without Metal it becomes a CGImage on a layer.
- The client always loads at 512x346 like desktop rsc-c, then switches to
  the screen size; the login backdrop is pre-rendered while loading.
- Phones render at about one game pixel per point; iPads scale so the short
  side is about 400 game pixels.
- The Apple Watch app connects through [rsc-relay](relay/README.md) over
  HTTPS, since watchOS doesn't allow apps to open raw TCP connections; the
  iPhone can use it too (Settings > RSC > Relay). `relay-transport.c` makes
  the relay look like a non-blocking socket to the game, and
  `RelayTransport.swift` makes the HTTPS requests. The apps pin the relay's
  key, so every address it's reached at is equally safe.
- The watch builds the same C core with the screen size of the watch, and
  its UI changes are behind `mudclient_ios_is_watch_ui()`.
- Options and worlds are stored in Application Support as `options.ini` and
  `worlds.cfg`, in the desktop rsc-c format. `worlds.cfg` lines are
  `name host port rsa_exp rsa_mod [register_url|-] [2001]`, the last for a
  world on the May 2001 game (2001Scape).
- 2001Scape's worlds run the May 2001 game (protocol 38), from the same C
  core: `retro-data.c` reads its data, `retro-packets.c` its packets, and
  `game-switch.c` swaps the game data when the selected world's game
  changes. The 2001 data isn't shipped; `RetroData.swift` fetches it from
  rsc.vet's 2001 web client (about 600 KB) the first time, into Application
  Support/2001, checking each file's SHA-256.
- The app target compiles the C code with `IOS`, `RENDER_SW`, `-fwrapv` and
  gnu99. Define `REVISION_177` to use the 177 protocol instead of 203; OpenRSC
  accepts both.

## Updating rsc-c

Copy the new upstream `src/` over `rsc-swift/Core` (skipping the SDL, GL,
Wii and 3DS platform files and `lib/rsa/rsa-openssl.c`), then reapply
`scripts/rsc-c-ios.patch`.

## Credits

- [2003scape/rsc-c](https://github.com/2003scape/rsc-c): the game client
  this app is built on, including its game data files and touch UI.
  Copyright 2003Scape Team, AGPLv3.
- [Open-RSC](https://github.com/Open-RSC): the server software behind
  RSC Preservation and the [rsc.vet](https://rsc.vet) site.
- App icon: the [2003scape](https://github.com/2003scape) organisation
  avatar's R and S stones, with a C stone added.
- Libraries bundled with rsc-c: [ini](https://github.com/rxi/ini) (MIT),
  [ISAAC](https://burtleburtle.net/bob/rand/isaacafa.html),
  [micro-bunzip](https://landley.net/code/) and
  [tiny-bignum-c](https://github.com/kokke/tiny-bignum-c).

## Disclaimer

This is an unofficial fan project. It is not affiliated with or endorsed by
Jagex Ltd. RuneScape is a trademark of Jagex Ltd, and the RuneScape Classic
game data remains the property of Jagex.

## License

GNU Affero General Public License v3.0, the same as rsc-c. See
[`LICENSE`](LICENSE).
