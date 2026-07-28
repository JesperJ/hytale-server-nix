{ lib
, writeShellApplication
, curl
, unzip
, coreutils
, findutils
}:

# One-shot installer/updater for the Hytale dedicated server.
#
# Fetches Hytale's official downloader, runs it (which prompts for OAuth2
# device-code auth on first use), extracts the resulting server.zip into
# the current directory, and prints next steps.
#
# Run as the hytale user in the service's dataDir, e.g.:
#   sudo -u hytale -H bash -c 'cd /var/lib/hytale-server && hytale-setup'
writeShellApplication {
  name = "hytale-setup";
  runtimeInputs = [ curl unzip coreutils findutils ];
  text = ''
    set -euo pipefail

    DOWNLOADER_URL="https://downloader.hytale.com/hytale-downloader.zip"
    WORKDIR="$(pwd)"
    STAGING="$WORKDIR/.hytale-setup-staging"
    DOWNLOADER_BIN="$WORKDIR/.hytale-downloader"
    CREDS="$WORKDIR/.hytale-downloader-credentials.json"

    PATCHLINE="release"
    FORCE_AUTH=0
    UPDATE_ONLY=0

    usage() {
      cat <<EOF
    hytale-setup — install or update a Hytale dedicated server in the current directory.

    Usage: hytale-setup [options]

    Options:
      -p, --patchline <name>   Patchline to download (default: release)
      -u, --update             Skip prompts; just download and extract latest
      --force-auth             Delete cached credentials and re-authenticate
      -h, --help               Show this help

    Files created in the current directory:
      .hytale-downloader                 The Hytale downloader binary (~9 MB)
      .hytale-downloader-credentials.json OAuth2 tokens (KEEP PRIVATE)
      start.sh, Server/, Assets.zip      The extracted server files

    See: https://downloader.hytale.com/hytale-downloader.zip (QUICKSTART.md)
    EOF
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        -p|--patchline) PATCHLINE="$2"; shift 2 ;;
        -u|--update) UPDATE_ONLY=1; shift ;;
        --force-auth) FORCE_AUTH=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "hytale-setup: unknown argument: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    if [ "$FORCE_AUTH" = "1" ] && [ -f "$CREDS" ]; then
      echo "==> Removing cached credentials..."
      rm -f "$CREDS"
    fi

    # 1. Fetch and extract the downloader (small, ~9 MB; refresh every time
    #    to pick up upstream fixes — its own -check-update prints a warning
    #    if outdated but doesn't self-update).
    echo "==> Downloading Hytale downloader from $DOWNLOADER_URL"
    rm -rf "$STAGING"
    mkdir -p "$STAGING"
    curl -fL --progress-bar -o "$STAGING/downloader.zip" "$DOWNLOADER_URL"
    unzip -q -o "$STAGING/downloader.zip" -d "$STAGING"
    install -m 0755 "$STAGING/hytale-downloader-linux-amd64" "$DOWNLOADER_BIN"

    # 2. Download the server archive. This runs the OAuth2 device-code flow
    #    if no credentials are cached — the tool prints a URL and code to
    #    stdout, and blocks until the user completes login in a browser.
    SERVER_ZIP="$STAGING/server.zip"
    echo "==> Downloading server files (patchline: $PATCHLINE)"
    if [ ! -f "$CREDS" ] && [ "$UPDATE_ONLY" = "1" ]; then
      echo "hytale-setup: --update was passed but no cached credentials at $CREDS" >&2
      echo "hytale-setup: run without --update once to authenticate interactively" >&2
      exit 1
    fi
    "$DOWNLOADER_BIN" \
      -credentials-path "$CREDS" \
      -patchline "$PATCHLINE" \
      -download-path "$SERVER_ZIP" \
      -skip-update-check

    # 3. Extract into the working directory. Overwrites Server/ + Assets.zip
    #    + start.sh but preserves worlds/config/mods that live elsewhere.
    echo "==> Extracting server files into $WORKDIR"
    unzip -q -o "$SERVER_ZIP" -d "$WORKDIR"

    # 4. Clean up staging (keep credentials + downloader binary for reuse).
    rm -rf "$STAGING"

    echo ""
    echo "==> Done."
    echo "    Files installed:"
    echo "      $WORKDIR/start.sh"
    echo "      $WORKDIR/Server/HytaleServer.jar"
    echo "      $WORKDIR/Assets.zip"
    echo ""
    echo "    Next: sudo systemctl start hytale-server"
    echo "          sudo journalctl -fu hytale-server"
  '';

  meta = with lib; {
    description = "One-shot installer/updater for a Hytale dedicated server";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "hytale-setup";
  };
}
