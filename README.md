# mac-youtube-app

A small native YouTube app for macOS. It opens YouTube in its own window with a
Dock icon, and you never have to launch a browser.

One command builds `YouTube.app` from source on your Mac with Apple's WebKit
(`WKWebView`), installs it in `~/Applications` and keeps it in the Dock.

- **Its own app:** separate window, Dock icon and ⌘-Tab entry, with no tabs or address bar
- **Stays signed in:** keeps its own login and cookies, separate from Safari
- **Full screen:** the green window button (⌃⌘F) and the player's full-screen button (`f`) both work
- **Pinned to the Dock:** done automatically ("Keep in Dock"), with no dragging
- **Tiny:** a ~130 KB binary on the WebKit already built into macOS. No Electron, no Chromium.
- **Native CPU:** compiled on your Mac for Apple silicon or Intel

## Install

Open Terminal (press ⌘Space, type `Terminal`, press Return) and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/bilalahamad0/mac-youtube-app/main/install.sh | bash
```

The installer doesn't need `sudo`. It:

1. Checks for macOS 11 or later and Apple's free **Command Line Tools**,
   which provide the Swift compiler.
2. Compiles `YouTube.app` for your Mac's processor and draws its icon. This
   takes 1–2 minutes the first time, longest on Intel Macs.
3. Installs it to `~/Applications/YouTube.app`.
4. Adds it to the Dock ("Keep in Dock") and opens it.

**About the Dock prompt:** macOS lets only Apple's own apps add Dock icons
while the Dock is running, so the installer has to restart the Dock. When the
Dock restarts, macOS brings minimized windows back on screen. The installer
therefore asks first (`Restart the Dock? [Y/n]`), and only when the tile is
actually being added or removed. Updates never restart the Dock. Answer `n` to
skip the Dock and pin the app yourself later. Pass `--yes` to skip the
question.

**On a new Mac without developer tools:** the first run stops and macOS asks
to install the "command line developer tools". Click **Install**, then
**Agree**. The download takes several minutes and uses about 2.5 GB of disk.
When it's done, paste the command again.

**To update or repair** the app, run the same command again. Your login is kept.

### Options

To pass options through `curl`, add `-s --` after `bash`, for example
`... | bash -s -- --no-dock`.

| Option | Effect |
| --- | --- |
| `--no-dock` | Don't add the Dock tile |
| `--yes` | Don't ask before restarting the Dock |
| `--no-launch` | Don't open the app after installing |
| `--uninstall` | Remove the app (see [Uninstall](#uninstall)) |
| `--keep-data` | With `--uninstall`: keep your login and settings |
| `--help` | Show all options |

To install somewhere else, set `YT_APP_DIR` on `bash` (not on `curl`), for
example:

```bash
curl -fsSL https://raw.githubusercontent.com/bilalahamad0/mac-youtube-app/main/install.sh | YT_APP_DIR=/Applications bash
```

Use the same `YT_APP_DIR` whenever you update or uninstall. Otherwise you get
a second copy in `~/Applications`, or the copy in your custom folder is left
behind. (`/Applications` itself is always checked when uninstalling.)

### From a clone

```bash
git clone https://github.com/bilalahamad0/mac-youtube-app.git
cd mac-youtube-app
./install.sh
```

## Using it

| Shortcut | Action |
| --- | --- |
| ⌘[ / ⌘] | Back / Forward (or swipe with two fingers) |
| ⇧⌘H | YouTube home |
| ⌘R | Reload |
| ⌘+ / ⌘- / ⌘0 | Zoom in / out / actual size |
| ⌃⌘F | Full-screen window |
| `f` | Full-screen video (YouTube's own shortcut) |
| ⇧⌘C | Copy the current page's link |
| ⇧⌘O | Open the current page in your default browser |

Links that leave YouTube, like those in video descriptions, open in your
default browser.

To play a specific video in the app, from Terminal or a script:

```bash
open -b com.local.youtubeapp "https://www.youtube.com/watch?v=VIDEO_ID"
```

(`-b` picks this app by its bundle id; `open -a YouTube` could pick a Chrome
or Safari web app with the same name.)

## Uninstall

### One command

```bash
curl -fsSL https://raw.githubusercontent.com/bilalahamad0/mac-youtube-app/main/uninstall.sh | bash
```

From a clone, run `./uninstall.sh` (same as `./install.sh --uninstall`).

This quits the app and removes the items below. Removing the Dock tile needs
a Dock restart, so it asks first, as the installer does.

- `~/Applications/YouTube.app`, plus `/Applications/YouTube.app` if it was built by this project
- its Dock tile (other Dock items are left untouched)
- its data: login cookies, cache, window position and settings, stored under
  `~/Library/WebKit`, `~/Library/HTTPStorages`, `~/Library/Cookies`,
  `~/Library/Caches`, `~/Library/Preferences`, `~/Library/Application Support`
  and `~/Library/Saved Application State`, each named `com.local.youtubeapp`

To keep your login for a later reinstall, add `--keep-data`:

```bash
curl -fsSL https://raw.githubusercontent.com/bilalahamad0/mac-youtube-app/main/uninstall.sh | bash -s -- --keep-data
```

The uninstaller only removes an app it built itself, identified by the bundle
id `com.local.youtubeapp`. A Safari web app called "YouTube" is left alone.

### By hand

1. **Quit** YouTube: press ⌘Q, or right-click its Dock icon and choose **Quit**.
2. **Remove it from the Dock:** right-click the icon, then **Options → Remove from Dock**.
3. **Delete the app:** in Finder, choose **Go → Home**, open **Applications**
   and drag **YouTube** to the Trash.
4. **Optional, to delete your login and cache:** run the following in
   Terminal. (`defaults delete` comes first so macOS doesn't write the
   settings back from its cache.)

   ```bash
   defaults delete com.local.youtubeapp 2>/dev/null
   rm -rf ~/Library/WebKit/com.local.youtubeapp \
          ~/Library/HTTPStorages/com.local.youtubeapp \
          ~/Library/HTTPStorages/com.local.youtubeapp.binarycookies \
          ~/Library/Cookies/com.local.youtubeapp.binarycookies \
          ~/Library/Caches/com.local.youtubeapp \
          ~/Library/Preferences/com.local.youtubeapp.plist \
          ~/Library/Application\ Support/com.local.youtubeapp \
          ~/Library/Saved\ Application\ State/com.local.youtubeapp.savedState
   ```

## Compatibility

| macOS | Apple silicon | Intel | How it's checked |
| --- | --- | --- | --- |
| 27 | ✅ | (no Intel release) | Supported, but GitHub only has a preview runner, so not in CI yet |
| 26 Tahoe | ✅ | ✅ | CI on every push |
| 15 Sequoia | ✅ | ✅ | CI on every push, and by hand on 15.8 (Intel) |
| 11 Big Sur – 14 Sonoma | ✅ | ✅ | Supported (built for macOS 11) but not covered by CI |

GitHub's macOS 11–13 runners are gone and its macOS 14 runner is being retired
(November 2026), so those versions aren't in CI. On them, run the installer
once and open the app to check it. On macOS 26 and later, the app
appears in the **Apps** view (which replaced Launchpad) as well as Spotlight.

## Why this approach?

Is this the best way to get YouTube without a browser on a Mac? For a setup
you can repeat on any Mac with one command, it's the best fit:

| Option | Trade-off |
| --- | --- |
| **This project** (compiled `WKWebView`) | Native, tiny, works on macOS 11+, fully scripted. Needs the free Command Line Tools (about 2.5 GB) to build. |
| Safari **File → Add to Dock** | Built in on macOS 14 Sonoma and later, but it's a manual click-through: no way to script it or roll it out to several Macs, and it isn't on Big Sur–Ventura. |
| Nativefier / Electron wrappers | Ships a whole Chromium (~150 MB+, hundreds of MB of RAM). Nativefier is no longer maintained. |
| FreeTube | Good ad-free client, but a separate app that doesn't use your Google account. |
| VLC / mpv + yt-dlp | Plays a link you already have. No browsing or search. |

## Troubleshooting

**"The Xcode Command Line Tools are needed".** Click **Install** in the dialog
that opens, and run the installer again once the tools are installed. If no
dialog appears, the tools are probably installed but broken, or Xcode was
deleted. Run `sudo xcode-select --reset` and try again. If that doesn't help,
reinstall them as shown in the next entry.

**Compiling fails after a macOS upgrade.** The Command Line Tools no longer
match macOS. Reinstall them, then run the installer again:

```bash
sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install
```

**Google says the browser "may not be secure", or a passkey prompt fails.** The
app tells Google it's Safari, which usually avoids the warning. Passkeys can't
work inside an embedded web view, so choose **Try another way** and sign in
with your password.

**It isn't in the Dock** (you used `--no-dock`, or removed the tile). Open
YouTube (⌘Space, type `YouTube`), then Control-click its Dock icon and choose
**Options → Keep in Dock**. Or, in Finder, choose **Go → Home**, open
**Applications** (or your `YT_APP_DIR` folder) and drag **YouTube** to the
Dock. If the installer said the Dock is locked or managed, which is common on
work and school Macs, ask your administrator.

**Minimized windows popped back on screen** (for example a minimized browser).
That happens whenever the Dock restarts. The installer restarts it only when
the YouTube tile is added (first install) or removed (uninstall), and asks
before doing so. To avoid it, answer `n` and use **Options → Keep in Dock**
yourself.

**"already exists and wasn't created by this installer".** Another app is
already at `~/Applications/YouTube.app`, usually one made with Safari's
**Add to Dock**. Remove it, or install elsewhere with `YT_APP_DIR`.

**The icon still looks generic.** Run `killall Dock Finder` to refresh it.

**Ads.** This is the regular YouTube website, so ads appear just as they do in
Safari. YouTube Premium removes them.

## How it works

`install.sh` contains the app's Swift source. It compiles it with `swiftc`,
writes `Info.plist`, draws the icon with AppKit and converts it to `.icns` with
`iconutil`, and ad-hoc signs the bundle. It then adds a `persistent-apps`
entry through `defaults`, the way `dockutil` does, and restarts the Dock.
Everything is built on your Mac, so there is no downloaded binary for
Gatekeeper to block.

## Disclaimer

Not affiliated with or endorsed by Google. YouTube is a trademark of Google LLC.
