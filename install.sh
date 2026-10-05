#!/usr/bin/env bash
#
# mac-youtube-app: builds a native WebKit YouTube.app for macOS, installs it
# into ~/Applications and keeps it in the Dock.
#
#   Install / update:
#     curl -fsSL https://raw.githubusercontent.com/bilalahamad0/mac-youtube-app/main/install.sh | bash
#   Uninstall:
#     curl -fsSL https://raw.githubusercontent.com/bilalahamad0/mac-youtube-app/main/install.sh | bash -s -- --uninstall
#
# Run with --help for all options. Requires macOS 11 (Big Sur) or later and the
# Xcode Command Line Tools (the installer offers to install them).

set -euo pipefail

VERSION="2.2.0"
APP_NAME="YouTube"
# Kept stable across versions: WebKit stores the YouTube login under this id.
BUNDLE_ID="com.local.youtubeapp"
MIN_MACOS_MAJOR=11

APP_DIR="${YT_APP_DIR:-${HOME}/Applications}"
APP_PATH="${APP_DIR}/${APP_NAME}.app"
# Test hook: point Dock edits at a scratch plist instead of the real Dock.
DOCK_DOMAIN="${YT_DOCK_DOMAIN:-com.apple.dock}"

PLISTBUDDY="/usr/libexec/PlistBuddy"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

LOCK_DIR="${TMPDIR:-/tmp}/mac-youtube-app.$(id -u).lock"

ACTION="install"
MANAGE_DOCK=1
ASSUME_YES=0
DOCK_RESTART_OK="yes"
LAUNCH_AFTER_INSTALL=1
KEEP_DATA=0
TMP_DIR=""
SWIFTC_LOG=""

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
else
    BOLD=""; RED=""; YELLOW=""; GREEN=""; RESET=""
fi

step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
warn() { printf '%sWarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
mac-youtube-app installer ${VERSION}

Usage: install.sh [options]

Builds ${APP_NAME}.app from source, installs it to ${APP_DIR}
and pins it to the Dock. Re-run any time to update or repair it.

Options:
  --uninstall   Remove ${APP_NAME}.app, its Dock tile and its data (login, cache)
  --keep-data   With --uninstall: keep the YouTube login and settings
  --no-dock     Don't add (or, with --uninstall, remove) the Dock tile
  -y, --yes     Don't ask before restarting the Dock (it restarts only when
                the tile is added or removed; minimized windows reappear)
  --no-launch   Don't open the app after installing
  --version     Print the installer version
  -h, --help    Show this help

Environment:
  YT_APP_DIR    Install location (default: ~/Applications)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall) ACTION="uninstall" ;;
            --keep-data) KEEP_DATA=1 ;;
            --no-dock)   MANAGE_DOCK=0 ;;
            -y|--yes)    ASSUME_YES=1 ;;
            --no-launch) LAUNCH_AFTER_INSTALL=0 ;;
            --version)   echo "$VERSION"; exit 0 ;;
            -h|--help)   usage; exit 0 ;;
            *)           die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

check_platform() {
    [[ "$(uname -s)" == "Darwin" ]] || die "This installer only runs on macOS."
    [[ "$(id -u)" -ne 0 ]] || die "Don't run this with sudo; it installs for the current user only."

    local version major
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    # Big Sur reports 10.16 when SYSTEM_VERSION_COMPAT=1 is set.
    if [[ "$version" == 10.16* ]]; then major=11; fi
    if [[ "$major" -lt "$MIN_MACOS_MAJOR" ]]; then
        die "macOS ${MIN_MACOS_MAJOR} (Big Sur) or later is required; this Mac runs macOS ${version}."
    fi
}

check_toolchain() {
    local clt="/Library/Developer/CommandLineTools" dev_dir="" out=""
    # `xcode-select -p` fails quietly when no tools are installed, whereas
    # running xcrun then would pop up the install dialog on its own.
    if dev_dir="$(xcode-select -p 2>/dev/null)" && [[ -d "$dev_dir" ]]; then
        out="$(xcrun swiftc --version 2>&1)" && return 0
    fi

    # The selected Xcode was deleted or its license isn't accepted, but the
    # Command Line Tools are there: build with those instead.
    if [[ "$dev_dir" != "$clt" && -x "${clt}/usr/bin/swiftc" ]]; then
        export DEVELOPER_DIR="$clt"
        if xcrun swiftc --version >/dev/null 2>&1; then
            warn "The selected Xcode isn't usable; building with the Command Line Tools instead."
            return 0
        fi
        unset DEVELOPER_DIR
    fi

    if [[ "$out" == *icense* ]]; then
        die "Accept the Xcode license first:  sudo xcodebuild -license accept"
    fi
    if [[ -n "$dev_dir" && -d "$dev_dir" ]]; then
        die "The developer tools at ${dev_dir} can't run swiftc. Reset or reinstall them, then re-run:
       sudo xcode-select --reset
       sudo rm -rf ${clt} && xcode-select --install   (if resetting didn't help)"
    fi

    warn "The Xcode Command Line Tools are needed to compile ${APP_NAME}.app."
    xcode-select --install >/dev/null 2>&1 || true
    die "Click Install in the dialog that opened. When the tools have finished installing
       (several minutes), run this installer again. If you deleted Xcode, also run
       sudo xcode-select --reset"
}

# Prints the bundle id, or nothing if Info.plist is missing or unreadable.
# (PlistBuddy prints its own errors to stdout, so only keep output on success.)
bundle_id_of() {
    local id
    if id="$("$PLISTBUDDY" -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null)"; then
        printf '%s' "$id"
    fi
}

# True for bundles this installer created, including broken earlier builds:
# an unreadable Info.plist next to our executable, or the empty folders an
# older installer left behind when compiling failed. Never true for another
# app such as a Safari web app.
is_our_bundle() {
    local bundle="$1" id
    [[ -d "$bundle" ]] || return 1
    id="$(bundle_id_of "$bundle")"
    if [[ "$id" == "$BUNDLE_ID" ]]; then return 0; fi
    [[ -z "$id" ]] || return 1
    if [[ -x "${bundle}/Contents/MacOS/${APP_NAME}" ]]; then return 0; fi
    [[ -z "$(find "$bundle" ! -type d -print 2>/dev/null | head -n 1)" ]]
}

check_existing_app() {
    [[ -e "$APP_PATH" ]] || return 0
    is_our_bundle "$APP_PATH" && return 0
    local id
    id="$(bundle_id_of "$APP_PATH")"
    die "${APP_PATH} already exists and wasn't created by this installer
       (bundle id: ${id:-none}). If it's a Safari web app, remove or rename it
       first, or install elsewhere with YT_APP_DIR=/path/to/dir."
}

# Resolves APP_DIR to its real path (symlinks, "..", trailing slashes,
# relative paths), which is the form the Dock stores. Needs the dir to exist.
canonicalize_app_dir() {
    local dir
    dir="$(CDPATH='' cd -P -- "$APP_DIR" >/dev/null 2>&1 && pwd -P)" \
        || die "Can't use the install folder ${APP_DIR}"
    APP_DIR="$dir"
    APP_PATH="${APP_DIR}/${APP_NAME}.app"
}

# One run at a time: two concurrent runs would both pin the app.
acquire_lock() {
    local pid
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            die "Another run of this installer is already in progress (pid ${pid})."
        fi
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || die "Another run of this installer is already in progress."
    fi
    echo "$$" > "${LOCK_DIR}/pid"
}

host_arch() {
    # Build for Apple silicon even when Terminal runs under Rosetta.
    if [[ "$(sysctl -in hw.optional.arm64 2>/dev/null)" == "1" ]]; then
        echo "arm64"
    else
        echo "x86_64"
    fi
}

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

write_app_source() {
    cat > "$1" <<'SWIFT_SRC'
import Cocoa
import WebKit

let homeURL = URL(string: "https://www.youtube.com/")!
let frameAutosaveName = "YouTubeMainWindow"

// Hosts that stay inside the app. Everything else opens in the default browser.
let internalHostSuffixes = [
    "youtube.com", "youtu.be", "youtube-nocookie.com", "youtubekids.com",
    "google.com", "googleusercontent.com", "googlevideo.com", "gstatic.com",
    "googleapis.com", "ggpht.com",
]

func isInternalHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    for suffix in internalHostSuffixes where host == suffix || host.hasSuffix("." + suffix) {
        return true
    }
    // Regional Google domains used during sign-in, e.g. accounts.google.co.uk.
    return host.range(of: "(^|\\.)google\\.(com?\\.)?[a-z]{2,3}$", options: .regularExpression) != nil
}

func isWebURL(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased() ?? ""
    return scheme == "http" || scheme == "https"
}

func isYouTubeURL(_ url: URL?) -> Bool {
    guard let host = url?.host?.lowercased() else { return false }
    return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
}

// YouTube wraps outbound links as https://www.youtube.com/redirect?q=<target>.
func outboundTarget(of url: URL) -> URL? {
    guard isYouTubeURL(url), url.path == "/redirect",
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          let raw = items.first(where: { $0.name == "q" })?.value,
          let target = URL(string: raw), isWebURL(target) else { return nil }
    return target
}

// WKWebView's default user agent lacks Safari's "Version/x Safari/y" tokens,
// so YouTube treats it as a legacy web view and Google sign-in may refuse it.
// Advertise the installed Safari version instead.
func safariUserAgentSuffix() -> String {
    var version = "17.0"
    if let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist"),
       let installed = info["CFBundleShortVersionString"] as? String, !installed.isEmpty {
        version = installed
    }
    return "Version/\(version) Safari/605.1.15"
}

// HTML5 fullscreen (the player's fullscreen button and the "f" key). The public
// property exists from macOS 12.3; older systems only have the private one.
func enableElementFullscreen(_ preferences: WKPreferences) {
    if preferences.responds(to: NSSelectorFromString("setElementFullscreenEnabled:")) {
        preferences.setValue(true, forKey: "elementFullscreenEnabled")
    } else if preferences.responds(to: NSSelectorFromString("_setFullScreenEnabled:")) {
        preferences.setValue(true, forKey: "fullScreenEnabled")
    }
}

final class AppWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Forward key equivalents (such as ⌘R for reload, ⌘[ / ⌘] for navigation)
        // to the main menu before WebKit consumes them.
        if let mainMenu = NSApp.mainMenu, mainMenu.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let hasReload = menu.items.contains {
            $0.action == #selector(AppDelegate.reloadPage(_:)) ||
            $0.action == #selector(AppDelegate.reloadPageFromOrigin(_:)) ||
            $0.title.contains("Reload")
        }
        if !hasReload {
            if menu.numberOfItems > 0 {
                menu.addItem(NSMenuItem.separator())
            }
            let reloadItem = NSMenuItem(title: "Reload Page", action: #selector(AppDelegate.reloadPage(_:)), keyEquivalent: "r")
            reloadItem.keyEquivalentModifierMask = [.command]
            menu.addItem(reloadItem)
        }
        return menu
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSToolbarDelegate {
    static let toolbarIdentifier = NSToolbar.Identifier("MainWindowToolbar")
    static let reloadItemIdentifier = NSToolbarItem.Identifier("reload")
    static let backItemIdentifier = NSToolbarItem.Identifier("back")
    static let forwardItemIdentifier = NSToolbarItem.Identifier("forward")

    var window: NSWindow!
    var webView: AppWebView!
    var titleObservation: NSKeyValueObservation?
    var pendingURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // We provide our own "Enter Full Screen" item in the View menu.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        webView.load(URLRequest(url: pendingURL ?? homeURL))
        pendingURL = nil
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // `open -a YouTube "https://youtu.be/..."` plays that video in the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: isWebURL) else { return }
        guard isInternalHost(url.host) else {
            NSWorkspace.shared.open(url)
            return
        }
        if webView == nil {
            pendingURL = url
        } else {
            webView.load(URLRequest(url: url))
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: AppDelegate.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case AppDelegate.backItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Back"
            item.paletteLabel = "Back"
            item.toolTip = "Back (⌘[)"
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
            }
            item.isBordered = true
            item.action = #selector(goBack(_:))
            item.target = self
            return item
        case AppDelegate.forwardItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Forward"
            item.paletteLabel = "Forward"
            item.toolTip = "Forward (⌘])"
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward")
            }
            item.isBordered = true
            item.action = #selector(goForward(_:))
            item.target = self
            return item
        case AppDelegate.reloadItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Reload"
            item.paletteLabel = "Reload"
            item.toolTip = "Reload Page (⌘R)"
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            }
            item.isBordered = true
            item.action = #selector(reloadPage(_:))
            item.target = self
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            AppDelegate.backItemIdentifier,
            AppDelegate.forwardItemIdentifier,
            AppDelegate.reloadItemIdentifier,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            AppDelegate.backItemIdentifier,
            AppDelegate.forwardItemIdentifier,
            AppDelegate.reloadItemIdentifier,
            .flexibleSpace,
            .space,
        ]
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case AppDelegate.backItemIdentifier:
            return webView?.canGoBack ?? false
        case AppDelegate.forwardItemIdentifier:
            return webView?.canGoForward ?? false
        case AppDelegate.reloadItemIdentifier:
            return true
        default:
            return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(goBack(_:)) {
            return webView?.canGoBack ?? false
        }
        if menuItem.action == #selector(goForward(_:)) {
            return webView?.canGoForward ?? false
        }
        return true
    }

    func makeWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = safariUserAgentSuffix()
        enableElementFullscreen(config.preferences)

        webView = AppWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "YouTube"
        window.minSize = NSSize(width: 480, height: 320)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = webView
        let toolbar = makeToolbar()
        window.toolbar = toolbar
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }
        if !window.setFrameUsingName(frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(frameAutosaveName)

        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            let title = webView.title ?? ""
            self?.window.title = title.isEmpty ? "YouTube" : title
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

        if ["about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        if !isWebURL(url) {
            // mailto:, itms-apps:, and so on.
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        if isMainFrame, let target = outboundTarget(of: url) {
            NSWorkspace.shared.open(target)
            decisionHandler(.cancel)
            return
        }
        // Leaving YouTube/Google from one of its pages (a clicked link, or a
        // redirect started on YouTube) opens the browser. A sign-in redirect
        // from Google to a company's SSO page stays here, and so does
        // everything on that SSO page, so the sign-in can finish.
        if isMainFrame, !isInternalHost(url.host), isInternalHost(webView.url?.host),
           navigationAction.navigationType == .linkActivated || isYouTubeURL(webView.url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url != nil {
            webView.reload()
        } else {
            webView.load(URLRequest(url: homeURL))
        }
    }

    // MARK: UI

    // target="_blank" links and window.open().
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, isWebURL(url) else { return nil }
        if let target = outboundTarget(of: url) {
            NSWorkspace.shared.open(target)
        } else if isInternalHost(url.host) {
            webView.load(navigationAction.request)
        } else {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: Menu actions

    @objc func goHome(_ sender: Any?) { webView.load(URLRequest(url: homeURL)) }
    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }
    @objc func reloadPage(_ sender: Any?) {
        if webView.url != nil {
            webView.reload()
        } else {
            webView.load(URLRequest(url: pendingURL ?? homeURL))
        }
    }
    @objc func reloadPageFromOrigin(_ sender: Any?) {
        if webView.url != nil {
            webView.reloadFromOrigin()
        } else {
            webView.load(URLRequest(url: pendingURL ?? homeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
    }
    @objc func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    @objc func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }

    @objc func actualSize(_ sender: Any?) {
        webView.pageZoom = 1.0
        webView.magnification = 1.0   // undo trackpad pinch / smart zoom too
    }

    @objc func copyPageLink(_ sender: Any?) {
        guard let url = webView.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func openInBrowser(_ sender: Any?) {
        guard let url = webView.url else { return }
        NSWorkspace.shared.open(url)
    }

    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            mainMenu.addItem(item)
            return menu
        }

        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
        }

        let app = submenu("YouTube")
        add(app, "About YouTube", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        app.addItem(NSMenuItem.separator())
        add(app, "Hide YouTube", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        app.addItem(NSMenuItem.separator())
        add(app, "Quit YouTube", #selector(NSApplication.terminate(_:)), "q")

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(NSMenuItem.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(NSMenuItem.separator())
        add(edit, "Copy Page Link", #selector(copyPageLink(_:)), "c", [.command, .shift], target: self)

        let view = submenu("View")
        add(view, "Reload Page", #selector(reloadPage(_:)), "r", target: self)
        add(view, "Reload from Origin", #selector(reloadPageFromOrigin(_:)), "r", [.command, .shift], target: self)
        view.addItem(NSMenuItem.separator())
        add(view, "Actual Size", #selector(actualSize(_:)), "0", target: self)
        add(view, "Zoom In", #selector(zoomIn(_:)), "+", target: self)
        // ⌘= also zooms in, as in Safari (no Shift needed on US keyboards).
        let zoomInAlias = NSMenuItem(title: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        zoomInAlias.target = self
        zoomInAlias.isHidden = true
        zoomInAlias.allowsKeyEquivalentWhenHidden = true
        view.addItem(zoomInAlias)
        add(view, "Zoom Out", #selector(zoomOut(_:)), "-", target: self)
        view.addItem(NSMenuItem.separator())
        // Sent to the key window, which also retitles it "Exit Full Screen".
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let history = submenu("History")
        add(history, "Back", #selector(goBack(_:)), "[", target: self)
        add(history, "Forward", #selector(goForward(_:)), "]", target: self)
        add(history, "Home", #selector(goHome(_:)), "h", [.command, .shift], target: self)
        history.addItem(NSMenuItem.separator())
        add(history, "Open in Default Browser", #selector(openInBrowser(_:)), "o", [.command, .shift], target: self)

        let windowMenu = submenu("Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        add(windowMenu, "Close", #selector(NSWindow.performClose(_:)), "w")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
SWIFT_SRC
}

write_icon_source() {
    cat > "$1" <<'SWIFT_SRC'
import Cocoa

// Draws a 1024x1024 macOS-style icon: the red YouTube play button on a white
// rounded-square plate laid out on Apple's icon grid (824pt plate, 100pt margin).
let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Could not create bitmap context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                         xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.28)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor.white.setFill()
plate.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: NSColor(calibratedWhite: 1.0, alpha: 1),
           ending: NSColor(calibratedWhite: 0.92, alpha: 1))?.draw(in: plate, angle: -90)

NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0).setFill()
NSBezierPath(roundedRect: NSRect(x: 222, y: 308, width: 580, height: 408),
             xRadius: 112, yRadius: 112).fill()

let triangle = NSBezierPath()
triangle.move(to: NSPoint(x: 450, y: 400))
triangle.line(to: NSPoint(x: 450, y: 624))
triangle.line(to: NSPoint(x: 644, y: 512))
triangle.close()
NSColor.white.setFill()
triangle.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    fatalError("Could not write icon: \(error)")
}
SWIFT_SRC
}

write_info_plist() {
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS_MAJOR}.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Built locally by mac-youtube-app. YouTube is a trademark of Google LLC.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# Returns non-zero on failure, leaving the compiler output in SWIFTC_LOG.
# Swift 5 language mode is pinned: in Swift 6 mode some WebKit delegate
# methods no longer match their protocols and silently stop being called.
compile_swift() {
    local src="$1" out="$2"
    shift 2
    local cache_dir="${TMP_DIR}/clang-module-cache"
    mkdir -p "$cache_dir"
    xcrun swiftc -O -swift-version 5 -module-cache-path "$cache_dir" "$@" "$src" -o "$out" >"$SWIFTC_LOG" 2>&1
}

compile_failed() {
    sed 's/^/    /' "$SWIFTC_LOG" | tail -n 25 >&2
    if grep -qi "license" "$SWIFTC_LOG"; then
        die "Accept the Xcode license first:  sudo xcodebuild -license accept"
    fi
    die "Compiling ${APP_NAME}.app failed. If you recently upgraded macOS, reinstall the
       Command Line Tools:  sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
}

build_icon() {
    local resources="$1"
    local tool="${TMP_DIR}/make_icon" png="${TMP_DIR}/icon_1024.png"
    local iconset="${TMP_DIR}/AppIcon.iconset" size

    write_icon_source "${TMP_DIR}/icon.swift"
    compile_swift "${TMP_DIR}/icon.swift" "$tool" -framework Cocoa || return 1
    "$tool" "$png" >/dev/null 2>&1 || return 1

    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$png" --out "${iconset}/icon_${size}x${size}.png" >/dev/null 2>&1 || return 1
        sips -z "$((size * 2))" "$((size * 2))" "$png" \
            --out "${iconset}/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || return 1
    done
    iconutil -c icns "$iconset" -o "${resources}/AppIcon.icns" >/dev/null 2>&1
}

build_bundle() {
    local bundle="$1" arch
    arch="$(host_arch)"
    mkdir -p "${bundle}/Contents/MacOS" "${bundle}/Contents/Resources"

    step "Compiling ${APP_NAME}.app for ${arch} (1-2 minutes the first time)..."
    write_app_source "${TMP_DIR}/main.swift"
    compile_swift "${TMP_DIR}/main.swift" "${bundle}/Contents/MacOS/${APP_NAME}" \
        -target "${arch}-apple-macos${MIN_MACOS_MAJOR}.0" -framework Cocoa -framework WebKit \
        || compile_failed

    write_info_plist "${bundle}/Contents/Info.plist"
    plutil -lint "${bundle}/Contents/Info.plist" >/dev/null || die "Generated Info.plist is invalid."
    printf 'APPL????' > "${bundle}/Contents/PkgInfo"

    step "Drawing the app icon..."
    if ! build_icon "${bundle}/Contents/Resources"; then
        warn "Couldn't build the icon; ${APP_NAME}.app will use the generic app icon."
    fi

    # Ad-hoc sign the whole bundle (last change to it) so Info.plist and the
    # icon are sealed together with the binary; the linker's own signature
    # covers only the executable. Locally built apps carry no quarantine flag,
    # so Gatekeeper doesn't block them.
    codesign --force --sign - "$bundle" >/dev/null 2>&1 \
        || warn "Ad-hoc code signing failed; the app should still run."
}

# ---------------------------------------------------------------------------
# Install / remove the bundle
# ---------------------------------------------------------------------------

app_pids() {
    # The path goes through ENVIRON (awk -v would interpret backslashes), and
    # a UTF-8 locale stops ps from escaping non-ASCII characters in paths.
    local exe="$1/Contents/MacOS/${APP_NAME}"
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -u "$(id -u)" -f "^${exe}" 2>/dev/null || true
        return 0
    fi
    LC_ALL=en_US.UTF-8 ps -axo pid=,command= 2>/dev/null \
        | EXE="$exe" awk '{
            pid = $1
            sub(/^ *[0-9]+ +/, "")
            if (index($0, ENVIRON["EXE"]) == 1) print pid
        }' || true
}

quit_app() {
    local bundle="$1" pids i
    pids="$(app_pids "$bundle")"
    [[ -n "$pids" ]] || return 0
    step "Quitting the running ${APP_NAME}.app..."
    # shellcheck disable=SC2086 # one pid per word
    kill -TERM $pids 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pids="$(app_pids "$bundle")"
        [[ -n "$pids" ]] || return 0
        sleep 0.5
    done
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
}

install_bundle() {
    local built="$1"
    step "Installing to ${APP_PATH}..."
    mkdir -p "$APP_DIR"
    quit_app "$APP_PATH"
    rm -rf "$APP_PATH"
    mv "$built" "$APP_PATH"
    touch "$APP_PATH"
    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 || true
    fi
    # Spotlight feeds Launchpad and, from macOS 26, the Apps view.
    mdimport "$APP_PATH" >/dev/null 2>&1 || true
}

remove_bundle() {
    local bundle="$1"
    quit_app "$bundle"
    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -u "$bundle" >/dev/null 2>&1 || true
    fi
    if ! rm -rf "$bundle" 2>/dev/null; then
        warn "Couldn't remove ${bundle}. Remove it with:  sudo rm -rf '${bundle}'"
        return 1
    fi
    step "Removed ${bundle}"
}

purge_app_data() {
    local lib="${HOME}/Library" path
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    for path in \
        "${lib}/WebKit/${BUNDLE_ID}" \
        "${lib}/Caches/${BUNDLE_ID}" \
        "${lib}/HTTPStorages/${BUNDLE_ID}" \
        "${lib}/HTTPStorages/${BUNDLE_ID}.binarycookies" \
        "${lib}/Cookies/${BUNDLE_ID}.binarycookies" \
        "${lib}/Preferences/${BUNDLE_ID}.plist" \
        "${lib}/Saved Application State/${BUNDLE_ID}.savedState" \
        "${lib}/Application Support/${BUNDLE_ID}"; do
        if [[ -e "$path" ]]; then
            rm -rf "$path" 2>/dev/null || true
        fi
    done
    step "Removed ${APP_NAME}.app data (login, cookies, cache, settings)"
}

# ---------------------------------------------------------------------------
# Dock
# ---------------------------------------------------------------------------

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Turns a Dock _CFURLString back into a path. We write plain paths
# (_CFURLStringType 0); the Dock rewrites them as file:// URLs (type 15).
file_url_to_path() {
    local s="$1"
    case "$s" in
        file://*)
            s="${s#file://}"
            s="${s#localhost}"
            s="${s%/}"
            printf '%b' "${s//\%/\\x}"
            ;;
        *)
            printf '%s' "${s%/}"
            ;;
    esac
}

dock_export() {
    defaults export "$DOCK_DOMAIN" "$1" >/dev/null 2>&1 \
        && "$PLISTBUDDY" -c "Print :persistent-apps" "$1" >/dev/null 2>&1
}

# Prints the persistent-apps indexes of tiles for this app, highest first.
# Mode "path" matches tiles pointing at APP_PATH; mode "any" also matches any
# tile carrying our bundle id (e.g. an older copy in /Applications). Tiles of
# other apps at the same path (a Safari web app) never match.
dock_tile_indexes() {
    local plist="$1" mode="$2" i=0 url id path same matches=""
    while "$PLISTBUDDY" -c "Print :persistent-apps:${i}" "$plist" >/dev/null 2>&1; do
        url="$("$PLISTBUDDY" -c "Print :persistent-apps:${i}:tile-data:file-data:_CFURLString" "$plist" 2>/dev/null)" || url=""
        id="$("$PLISTBUDDY" -c "Print :persistent-apps:${i}:tile-data:bundle-identifier" "$plist" 2>/dev/null)" || id=""
        same=0
        if [[ -n "$url" ]]; then
            path="$(file_url_to_path "$url")"
            # -ef (same file) also covers case and Unicode-normalization
            # differences between the Dock's copy of the path and ours.
            if [[ "$path" == "$APP_PATH" || "$path" -ef "$APP_PATH" ]]; then
                same=1
            fi
        fi
        if [[ "$same" -eq 1 && ( -z "$id" || "$id" == "$BUNDLE_ID" ) ]] \
            || [[ "$mode" == "any" && "$id" == "$BUNDLE_ID" ]]; then
            matches="${i} ${matches}"
        fi
        i=$((i + 1))
    done
    printf '%s' "$matches"
}

restart_dock() {
    if [[ "$DOCK_DOMAIN" == "com.apple.dock" ]]; then
        killall Dock >/dev/null 2>&1 || true
    fi
}

dock_is_locked() {
    [[ "$(defaults read "$DOCK_DOMAIN" contents-immutable 2>/dev/null || true)" == "1" ]]
}

# True when pinning would change the Dock, and so restart it.
dock_needs_pin() {
    local plist="${TMP_DIR}/dock.plist"
    ! dock_is_locked && dock_export "$plist" && [[ -z "$(dock_tile_indexes "$plist" path)" ]]
}

# True when there's a tile of ours to remove.
dock_has_tile() {
    local plist="${TMP_DIR}/dock.plist"
    dock_export "$plist" && [[ -n "$(dock_tile_indexes "$plist" any)" ]]
}

# Only Apple-signed apps such as Safari may add Dock tiles while the Dock is
# running; everyone else edits its preferences and restarts it, and macOS
# then brings every minimized window back on screen. So ask first, while
# there's a terminal to ask in (curl | bash still has /dev/tty). Runs with
# --yes, without a terminal (CI, cron) or with no Dock running go ahead.
confirm_dock_restart() {
    local what="$1" answer=""
    DOCK_RESTART_OK="yes"
    if [[ "$ASSUME_YES" -eq 1 || "$DOCK_DOMAIN" != "com.apple.dock" ]]; then return 0; fi
    pgrep -x -u "$(id -u)" Dock >/dev/null 2>&1 || return 0
    ( exec </dev/tty ) 2>/dev/null || return 0

    step "The Dock has to restart to ${what}. macOS brings minimized windows back on screen when it does."
    printf '    Restart the Dock? [Y/n] '
    read -r answer </dev/tty || answer=""
    case "$answer" in
        [nN]*) DOCK_RESTART_OK="no" ;;
    esac
}

pin_to_dock() {
    local plist="${TMP_DIR}/dock.plist"

    if dock_is_locked; then
        warn "The Dock is locked (contents-immutable), so ${APP_NAME}.app wasn't pinned.
         On a work or school Mac, ask your administrator."
        return 0
    fi
    if ! dock_export "$plist"; then
        warn "Couldn't read the Dock's app list, so ${APP_NAME}.app wasn't pinned. Open it, then
         Control-click its Dock icon and choose Options > Keep in Dock."
        return 0
    fi
    if [[ -n "$(dock_tile_indexes "$plist" path)" ]]; then
        step "${APP_NAME}.app is already in the Dock"
        return 0
    fi

    step "Adding ${APP_NAME}.app to the Dock..."
    # Same shape as the Dock's own default.plist and dockutil: a plain path
    # with _CFURLStringType 0. `defaults` goes through cfprefsd, which the Dock
    # reads from, unlike editing com.apple.dock.plist on disk.
    defaults write "$DOCK_DOMAIN" persistent-apps -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$(xml_escape "$APP_PATH")</string><key>_CFURLStringType</key><integer>0</integer></dict><key>file-label</key><string>${APP_NAME}</string><key>bundle-identifier</key><string>${BUNDLE_ID}</string></dict><key>tile-type</key><string>file-tile</string></dict>"
    restart_dock
    if [[ -e "/Library/Managed Preferences/${USER:-$(id -un)}/com.apple.dock.plist" ]]; then
        warn "This Mac's Dock is managed by your organization and may remove the tile."
    fi
}

unpin_from_dock() {
    local plist="${TMP_DIR}/dock.plist" apps="${TMP_DIR}/dock-apps.plist" indexes idx
    if ! dock_export "$plist"; then
        warn "Couldn't read the Dock's app list; remove the ${APP_NAME} tile by hand if it's still there."
        return 0
    fi
    indexes="$(dock_tile_indexes "$plist" any)"
    [[ -n "$indexes" ]] || return 0

    for idx in $indexes; do
        "$PLISTBUDDY" -c "Delete :persistent-apps:${idx}" "$plist"
    done
    # Import only persistent-apps. `defaults import` merges top-level keys, so
    # anything else the Dock saved since the export (recent apps, settings)
    # is left alone.
    plutil -extract persistent-apps xml1 -o - "$plist" \
        | sed -e 's#^<plist version="1.0">$#&<dict><key>persistent-apps</key>#' \
              -e 's#^</plist>$#</dict>&#' > "$apps"
    if ! plutil -lint "$apps" >/dev/null 2>&1; then
        warn "Couldn't update the Dock; remove the ${APP_NAME} tile by hand."
        return 0
    fi
    defaults import "$DOCK_DOMAIN" "$apps"
    restart_dock
    step "Removed ${APP_NAME}.app from the Dock"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

install_app() {
    step "Installing ${APP_NAME}.app ${VERSION} for macOS $(sw_vers -productVersion)"
    check_toolchain
    mkdir -p "$APP_DIR" || die "Can't create the install folder ${APP_DIR}"
    canonicalize_app_dir
    check_existing_app

    local other="/Applications/${APP_NAME}.app"
    if [[ "$APP_PATH" != "$other" ]] && is_our_bundle "$other"; then
        warn "An older copy is also installed at ${other}. To update that one instead, run
         the installer with YT_APP_DIR=/Applications; --uninstall removes both."
    fi

    # Ask now rather than after the build, while the user is still watching.
    if [[ "$MANAGE_DOCK" -eq 1 ]] && dock_needs_pin; then
        confirm_dock_restart "add ${APP_NAME} to it"
    fi

    local built="${TMP_DIR}/${APP_NAME}.app"
    build_bundle "$built"
    install_bundle "$built"

    if [[ "$MANAGE_DOCK" -eq 1 ]]; then
        if [[ "$DOCK_RESTART_OK" == "no" ]]; then
            step "Left the Dock alone. To keep ${APP_NAME} in it: open the app, Control-click its
    Dock icon and choose Options > Keep in Dock."
        else
            pin_to_dock
        fi
    fi
    if [[ "$LAUNCH_AFTER_INSTALL" -eq 1 ]]; then
        open "$APP_PATH" >/dev/null 2>&1 || true
    fi

    printf '%s==> Installed %s%s\n' "$GREEN" "$APP_PATH" "$RESET"
    echo "    Update: re-run this installer. Remove: run it again with --uninstall."
}

uninstall_app() {
    step "Uninstalling ${APP_NAME}.app"
    if [[ -d "$APP_DIR" ]]; then
        canonicalize_app_dir
    fi
    if [[ "$MANAGE_DOCK" -eq 1 ]] && dock_has_tile; then
        confirm_dock_restart "remove the ${APP_NAME} tile"
    fi

    local bundle found=0
    for bundle in "$APP_PATH" "/Applications/${APP_NAME}.app"; do
        if is_our_bundle "$bundle"; then
            if [[ "$bundle" != "$APP_PATH" && ! -O "$bundle" ]]; then
                warn "Left ${bundle} alone: it belongs to another user. Remove it with:  sudo rm -rf '${bundle}'"
                continue
            fi
            if remove_bundle "$bundle"; then
                found=1
            fi
        elif [[ "$bundle" == "$APP_PATH" && -e "$bundle" ]]; then
            warn "Left ${bundle} alone: it wasn't created by this installer."
        fi
    done
    if [[ "$found" -eq 0 ]]; then
        step "No ${APP_NAME}.app from this installer was found; cleaning up leftovers"
    fi

    if [[ "$MANAGE_DOCK" -eq 1 ]]; then
        if [[ "$DOCK_RESTART_OK" == "no" ]]; then
            step "Left the Dock alone. Drag the ${APP_NAME} tile out of the Dock to remove it."
        else
            unpin_from_dock
        fi
    fi
    if [[ "$KEEP_DATA" -eq 1 ]]; then
        step "Kept ${APP_NAME}.app data (--keep-data)"
    else
        purge_app_data
    fi
    printf '%s==> %s.app is uninstalled%s\n' "$GREEN" "$APP_NAME" "$RESET"
}

main() {
    parse_args "$@"
    check_platform
    acquire_lock
    trap 'rm -rf "$TMP_DIR" "$LOCK_DIR"' EXIT
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yt_build.XXXXXX")"

    SWIFTC_LOG="${TMP_DIR}/swiftc.log"

    if [[ "$ACTION" == "uninstall" ]]; then
        uninstall_app
    else
        install_app
    fi
}

# Everything runs from here, so a partially downloaded script does nothing.
main "$@"
