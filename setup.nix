{ lib
, writeShellApplication
, curl
, unzip
, coreutils
, findutils
}:

# Bootstrap installer for the Hytale dedicated server.
#
# Fetches Hytale's official downloader, runs it (OAuth2 device-code auth on
# first use), and extracts server.zip into the current directory. Only needed
# for the first-ever install — subsequent updates use `hytalectl update ...`
# against the running service (server uses its own cached session credentials,
# no downloader needed).
#
# Run as the hytale user in the service's dataDir, e.g.:
#   sudo -u hytale -H bash -c 'cd /var/lib/hytale-server && hytale-setup'
writeShellApplication {
  name = "hytale-setup";
  runtimeInputs = [ curl unzip coreutils findutils ];
  text = ''
    set -euo pipefail

    # The Hytale downloader zip only ships a linux-amd64 binary. Fail early
    # on other architectures rather than exploding halfway through unzip.
    ARCH="$(uname -m)"
    if [ "$ARCH" != "x86_64" ]; then
      echo "hytale-setup: unsupported architecture: $ARCH" >&2
      echo "              The Hytale downloader only ships a linux-amd64 build." >&2
      exit 1
    fi

    DOWNLOADER_URL="https://downloader.hytale.com/hytale-downloader.zip"
    WORKDIR="$(pwd)"
    STAGING="$WORKDIR/.hytale-setup-staging"
    DOWNLOADER_BIN="$WORKDIR/.hytale-downloader"
    CREDS="$WORKDIR/.hytale-downloader-credentials.json"
    SERVICE="hytale-server.service"

    usage() {
      cat <<EOF
    hytale-setup — bootstrap a Hytale dedicated server (first-ever install).

    Usage:
      hytale-setup [--patchline <name>] [--force-auth]
      hytale-setup --help

    Options:
      -p, --patchline <name>   Patchline to download (default: release)
      --force-auth             Delete cached downloader credentials and
                               re-authenticate against the downloader.
      -h, --help               Show this help

    After install:
      - Start the service:    sudo systemctl start $SERVICE
      - Authenticate:         hytalectl auth login device
      - Watch journal:        journalctl -fu $SERVICE

    Updates are handled in-server — see \`hytalectl update --help\`.

    Files created in the current directory:
      .hytale-downloader                    The Hytale downloader binary (~9 MB)
      .hytale-downloader-credentials.json   OAuth2 tokens for the downloader
      start.sh, Server/, Assets.zip         Extracted server files

    See: https://downloader.hytale.com/hytale-downloader.zip (QUICKSTART.md)
    EOF
    }

    PATCHLINE="release"
    FORCE_AUTH=0

    while [ $# -gt 0 ]; do
      case "$1" in
        -p|--patchline) PATCHLINE="$2"; shift 2 ;;
        --force-auth)   FORCE_AUTH=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "hytale-setup: unknown argument: $1" >&2
                        usage >&2; exit 2 ;;
      esac
    done

    if [ "$FORCE_AUTH" = "1" ] && [ -f "$CREDS" ]; then
      echo "==> Removing cached downloader credentials..."
      rm -f "$CREDS"
    fi

    # 1. Fetch and extract the downloader (small, ~9 MB; refresh every time to
    #    pick up upstream fixes — its own -check-update prints a warning if
    #    outdated but doesn't self-update).
    echo "==> Downloading Hytale downloader from $DOWNLOADER_URL"
    rm -rf "$STAGING"
    mkdir -p "$STAGING"
    curl -fL --progress-bar -o "$STAGING/downloader.zip" "$DOWNLOADER_URL"
    unzip -q -o "$STAGING/downloader.zip" -d "$STAGING"
    install -m 0755 "$STAGING/hytale-downloader-linux-amd64" "$DOWNLOADER_BIN"

    # 2. Download the server archive. This runs the OAuth2 device-code flow if
    #    no credentials are cached — the tool prints a URL and code to stdout
    #    and blocks until the user completes login in a browser.
    SERVER_ZIP="$STAGING/server.zip"
    echo "==> Downloading server files (patchline: $PATCHLINE)"
    "$DOWNLOADER_BIN" \
      -credentials-path "$CREDS" \
      -patchline "$PATCHLINE" \
      -download-path "$SERVER_ZIP" \
      -skip-update-check

    # 3. Extract into the working directory. Overwrites Server/ + Assets.zip +
    #    start.sh but preserves worlds/config/mods/backups that live elsewhere.
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
    if [ ! -f "$WORKDIR/Server/auth.enc" ]; then
      echo "    Next: start the service and authenticate:"
      echo "          sudo systemctl start $SERVICE"
      echo "          hytalectl auth login device"
      echo "          journalctl -fu $SERVICE   # watch for the URL & code"
    else
      echo "    Next: sudo systemctl start $SERVICE"
      echo "          journalctl -fu $SERVICE"
    fi
  '';

  meta = with lib; {
    description = "Bootstrap installer for a Hytale dedicated server";
    license = licenses.mit;
    # The upstream downloader zip only ships hytale-downloader-linux-amd64.
    # Restrict accordingly; hytale-server and hytalectl remain multi-arch.
    platforms = [ "x86_64-linux" ];
    mainProgram = "hytale-setup";
  };
}
