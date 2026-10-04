#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${HOME}/Applications/YouTube.app"
CONTENTS_PATH="${APP_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
RESOURCES_PATH="${CONTENTS_PATH}/Resources"
TMP_DIR=$(mktemp -d /tmp/yt_build.XXXXXX)

trap 'rm -rf "${TMP_DIR}"' EXIT

echo "==> Preparing YouTube.app bundle..."
killall YouTube 2>/dev/null || true
mkdir -p "${MACOS_PATH}" "${RESOURCES_PATH}"

echo "==> Generating native Swift source..."
cat << 'SWIFT_SRC' > "${TMP_DIR}/main.swift"
import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 100, y: 100, width: 1280, height: 800)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "YouTube"
        window.center()
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self

        let config = WKWebViewConfiguration()
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.setValue(true, forKey: "fullScreenEnabled")

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.uiDelegate = self
        window.contentView?.addSubview(webView)

        if let url = URL(string: "https://www.youtube.com") {
            webView.load(URLRequest(url: url))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
SWIFT_SRC

echo "==> Compiling WebKit binary..."
swiftc "${TMP_DIR}/main.swift" -o "${MACOS_PATH}/YouTube" -framework Cocoa -framework WebKit

echo "==> Writing Info.plist metadata..."
cat << 'PLIST' > "${CONTENTS_PATH}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>YouTube</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.youtubeapp</string>
    <key>CFBundleName</key>
    <string>YouTube</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Rendering YouTube icon..."
cat << 'ICON_SWIFT' > "${TMP_DIR}/draw_icon.swift"
import Cocoa

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Red button background
let rect = NSRect(x: 112, y: 262, width: 800, height: 500)
let path = NSBezierPath(roundedRect: rect, xRadius: 160, yRadius: 160)
NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0).setFill()
path.fill()

// White play triangle
let triangle = NSBezierPath()
triangle.move(to: NSPoint(x: 432, y: 362))
triangle.line(to: NSPoint(x: 432, y: 662))
triangle.line(to: NSPoint(x: 652, y: 512))
triangle.close()
NSColor.white.setFill()
triangle.fill()

NSGraphicsContext.restoreGraphicsState()

let pngData = rep.representation(using: .png, properties: [:])!
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try! pngData.write(to: outURL)
ICON_SWIFT

swift "${TMP_DIR}/draw_icon.swift" "${TMP_DIR}/yt_source.png"

echo "==> Building Apple ICNS bundle..."
ICONSET_DIR="${TMP_DIR}/yt.iconset"
mkdir -p "${ICONSET_DIR}"

for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" "${TMP_DIR}/yt_source.png" --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "${TMP_DIR}/yt_source.png" --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_PATH}/AppIcon.icns"

echo "==> Refreshing macOS application cache..."
touch "${APP_PATH}"
killall Dock 2>/dev/null || true

echo "==> Complete! YouTube.app is installed at ~/Applications/YouTube.app"
