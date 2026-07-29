{ lib
, writeShellApplication
, curl
, unzip
, coreutils
, findutils
}:

# Installer / updater for the Hytale dedicated server.
#
# Subcommands:
#   install (default)  Fetch the Hytale downloader, run its OAuth2 device-code
#                      flow (interactive on first use), and extract server.zip
#                      into the current directory.
#   update             Alias for `install --update` (non-interactive; assumes
#                      cached credentials).
#
# Server-side auth (`/auth login device`) is done via `hytalectl` against the
# running systemd service — no dance required.
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
    SERVICE="hytale-server.service"

    usage() {
      cat <<EOF
    hytale-setup — install or update a Hytale dedicated server.

    Usage:
      hytale-setup [install] [--patchline <name>] [--force-auth]
      hytale-setup update    [--patchline <name>]
      hytale-setup --help

    Subcommands:
      install (default)   Download the server files. Runs OAuth2 device-code
                          auth on first use (interactive), non-interactive
                          afterwards.
      update              Refresh server files from the latest patchline build.
                          Fails if no credentials are cached.

    Options:
      -p, --patchline <name>   Patchline to download (default: release)
      --force-auth             Delete cached downloader credentials and
                               re-authenticate against the downloader (not to
                               be confused with server-side /auth — use
                               \`hytalectl auth login device\` for that).
      -h, --help               Show this help

    Files created in the current directory:
      .hytale-downloader                    The Hytale downloader binary (~9 MB)
      .hytale-downloader-credentials.json   OAuth2 tokens for the downloader
      start.sh, Server/, Assets.zip         Extracted server files
      Server/auth.enc                       Encrypted server-side auth token
                                            (created after 'hytalectl auth login device')

    See: https://downloader.hytale.com/hytale-downloader.zip (QUICKSTART.md)
    EOF
    }

    # Parse subcommand (first positional) — default `install`.
    SUBCMD="install"
    case "''${1:-}" in
      install|update)  SUBCMD="$1"; shift ;;
      -h|--help)       usage; exit 0 ;;
      "")              ;;
      -*)              ;;  # Leave flag parsing to the loop below.
      *)               echo "hytale-setup: unknown subcommand: $1" >&2
                       usage >&2; exit 2 ;;
    esac

    PATCHLINE="release"
    FORCE_AUTH=0
    UPDATE_ONLY=0
    [ "$SUBCMD" = "update" ] && UPDATE_ONLY=1

    while [ $# -gt 0 ]; do
      case "$1" in
        -p|--patchline) PATCHLINE="$2"; shift 2 ;;
        -u|--update)    UPDATE_ONLY=1; shift ;;   # legacy — pre-subcommand form
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
    if [ ! -f "$CREDS" ] && [ "$UPDATE_ONLY" = "1" ]; then
      echo "hytale-setup: 'update' was requested but no cached credentials at $CREDS" >&2
      echo "hytale-setup: run 'hytale-setup install' once to authenticate interactively" >&2
      exit 1
    fi
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
    description = "Installer / updater for a Hytale dedicated server";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "hytale-setup";
  };
}
