{ lib
, writeShellApplication
, curl
, unzip
, coreutils
, findutils
, systemd
}:

# One-shot installer / updater / auth-helper for the Hytale dedicated server.
#
# Subcommands:
#   install (default)  Fetch the Hytale downloader, run its OAuth2 device-code
#                      flow (interactive on first use), and extract server.zip
#                      into the current directory.
#   update             Alias for `install --update` (non-interactive; assumes
#                      cached credentials).
#   auth               Wrap the one-time `/auth login device` ceremony. Aborts
#                      if the systemd service is running, then launches the
#                      vendor start.sh interactively so the user can type
#                      `/auth login device` and `/stop`.
#
# Run as the hytale user in the service's dataDir, e.g.:
#   sudo -u hytale -H bash -c 'cd /var/lib/hytale-server && hytale-setup'
writeShellApplication {
  name = "hytale-setup";
  runtimeInputs = [ curl unzip coreutils findutils systemd ];
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
    hytale-setup — install, update, or authenticate a Hytale dedicated server.

    Usage:
      hytale-setup [install] [--patchline <name>] [--force-auth]
      hytale-setup update    [--patchline <name>]
      hytale-setup auth
      hytale-setup --help

    Subcommands:
      install (default)   Download the server files. Runs OAuth2 device-code
                          auth on first use (interactive), non-interactive
                          afterwards.
      update              Refresh server files from the latest patchline build.
                          Fails if no credentials are cached.
      auth                Run the one-time in-server /auth login device flow.
                          Must be done once before players can connect.

    Options:
      -p, --patchline <name>   Patchline to download (default: release)
      --force-auth             Delete cached downloader credentials and
                               re-authenticate against the downloader (not to
                               be confused with the server-side /auth flow).
      -h, --help               Show this help

    Files created in the current directory:
      .hytale-downloader                    The Hytale downloader binary (~9 MB)
      .hytale-downloader-credentials.json   OAuth2 tokens for the downloader
      start.sh, Server/, Assets.zip         Extracted server files
      Server/auth.enc                       Encrypted server-side auth token

    See: https://downloader.hytale.com/hytale-downloader.zip (QUICKSTART.md)
    EOF
    }

    # Parse subcommand (first positional) — default `install`.
    SUBCMD="install"
    case "''${1:-}" in
      install|update|auth) SUBCMD="$1"; shift ;;
      -h|--help)           usage; exit 0 ;;
      "")                  ;;
      -*)                  ;;  # Leave flag parsing to the loop below.
      *)                   echo "hytale-setup: unknown subcommand: $1" >&2
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

    # ------- Subcommand: auth -------------------------------------------------

    if [ "$SUBCMD" = "auth" ]; then
      if [ ! -f "$WORKDIR/start.sh" ]; then
        echo "hytale-setup: $WORKDIR/start.sh not found — run 'hytale-setup install' first." >&2
        exit 1
      fi

      # The service holds the UDP port and its own copy of auth.enc; running a
      # second server instance while it's up would conflict. We can't stop it
      # ourselves (needs root), so abort with a clear message.
      if systemctl is-active --quiet "$SERVICE"; then
        echo "hytale-setup: $SERVICE is currently running." >&2
        echo "              Stop it first from an admin shell:" >&2
        echo "                sudo systemctl stop $SERVICE" >&2
        echo "              Then re-run: hytale-setup auth" >&2
        exit 1
      fi

      if ! command -v hytale-server >/dev/null 2>&1; then
        echo "hytale-setup: 'hytale-server' not found on PATH." >&2
        echo "              This subcommand needs the hytale-server wrapper, which is" >&2
        echo "              installed by the NixOS module when services.hytale-server" >&2
        echo "              is enabled." >&2
        exit 1
      fi

      cat <<'EOF'

    ==> Launching Hytale server in interactive mode for one-time auth.

        When you see the line:
          [HytaleServer] Hytale Server Booted! [Multiplayer] took ...

        Type at the prompt:
          /auth login device

        The server will print a short URL and 6–8 character code. Open the URL
        in a browser, sign in with your Hytale account, and enter the code.

        Wait for:
          [ServerAuthManager] Authentication successful! Mode: OAUTH_STORE

        Then type:
          /stop

        The server will shut down and control will return to this script.

    EOF
      read -r -p "Press Enter to launch the server..." _

      # The wrapper (hytale-server) cds into $WORKDIR/Server implicitly via
      # start.sh; we invoke it from the current dir so start.sh's SCRIPT_DIR
      # resolves correctly.
      set +e
      hytale-server
      RC=$?
      set -e

      echo ""
      if [ $RC -eq 0 ]; then
        echo "==> Server exited cleanly. Auth token cached at:"
        echo "      $WORKDIR/Server/auth.enc"
        echo ""
        echo "    Next: sudo systemctl start $SERVICE"
      else
        echo "==> Server exited with code $RC. Check output above." >&2
        exit $RC
      fi
      exit 0
    fi

    # ------- Subcommand: install / update -------------------------------------

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
      echo "    Next: authenticate the server (one-time):"
      echo "          hytale-setup auth"
      echo "          sudo systemctl start $SERVICE"
    else
      echo "    Next: sudo systemctl start $SERVICE"
      echo "          sudo journalctl -fu $SERVICE"
    fi
  '';

  meta = with lib; {
    description = "Installer / updater / auth-helper for a Hytale dedicated server";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "hytale-setup";
  };
}
