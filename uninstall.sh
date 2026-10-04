#!/usr/bin/env bash
#
# Removes YouTube.app, its Dock tile and its data. Same as `install.sh --uninstall`.
#
#   curl -fsSL https://raw.githubusercontent.com/bilalahamad0/mac-youtube-app/main/uninstall.sh | bash
#
# Keep the YouTube login for a later reinstall:
#   curl -fsSL https://raw.githubusercontent.com/bilalahamad0/mac-youtube-app/main/uninstall.sh | bash -s -- --keep-data

set -euo pipefail

INSTALLER_URL="https://raw.githubusercontent.com/bilalahamad0/mac-youtube-app/main/install.sh"

main() {
    # Run from a clone: use the install.sh next to this file. Piped through
    # curl: BASH_SOURCE is empty, so fetch the installer instead.
    local self="${BASH_SOURCE[0]:-}" installer=""
    if [[ -n "$self" && -f "$self" ]]; then
        installer="$(cd "$(dirname "$self")" && pwd)/install.sh"
    fi
    if [[ -n "$installer" && -f "$installer" ]] && grep -q "mac-youtube-app" "$installer"; then
        exec /bin/bash "$installer" --uninstall "$@"
    fi
    curl -fsSL "$INSTALLER_URL" | /bin/bash -s -- --uninstall "$@"
}

main "$@"
