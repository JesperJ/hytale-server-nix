{ lib
, writeShellApplication
, coreutils
}:

# Small client for the hytale-server console FIFO. Writes commands to the
# systemd-managed FIFO (default /run/hytale-server-console), which is wired to
# the service's stdin — the server reads them from stdin and replies via
# stdout, which lands in the journal.
#
# Usage:
#   hytalectl world list                    # single command
#   hytalectl op add SomePlayer
#   hytalectl < commands.txt                # stream from stdin
#   HYTALECTL_FIFO=/other/fifo hytalectl …  # override target
writeShellApplication {
  name = "hytalectl";
  runtimeInputs = [ coreutils ];
  text = ''
    set -euo pipefail

    FIFO="''${HYTALECTL_FIFO:-/run/hytale-server-console}"

    if [ ! -p "$FIFO" ]; then
      echo "hytalectl: FIFO $FIFO not found." >&2
      echo "           Is hytale-server.service running? Check with:" >&2
      echo "             systemctl is-active hytale-server" >&2
      exit 1
    fi

    if [ ! -w "$FIFO" ]; then
      echo "hytalectl: $FIFO is not writable by $(id -un)." >&2
      echo "           You need to be in the group that owns the FIFO." >&2
      echo "           Check: ls -l $FIFO" >&2
      exit 1
    fi

    send() {
      # Strip a leading `/` so `hytalectl /op self` and `hytalectl op self`
      # both work — the console accepts either form.
      local cmd="$1"
      cmd="''${cmd#/}"
      printf '%s\n' "$cmd" >>"$FIFO"
    }

    if [ $# -eq 0 ]; then
      # No args → forward stdin line-by-line. Blank lines are dropped.
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        send "$line"
      done
      exit 0
    fi

    send "$*"

    echo "hytalectl: command sent. Watch response with: journalctl -fu hytale-server" >&2
  '';

  meta = with lib; {
    description = "Client for sending admin commands to the hytale-server console";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "hytalectl";
  };
}
