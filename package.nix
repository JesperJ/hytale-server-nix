{ lib
, writeShellApplication
, jdk25
, bash
, coreutils
}:

# Thin runtime wrapper: puts `java` on PATH and hands off to the vendor's
# start.sh (which lives in the dataDir alongside HytaleServer.jar). The
# vendor script handles staged updates, exit-code-8 restarts, backups, and
# the AOT cache — reimplementing any of that in Nix invites drift.
writeShellApplication {
  name = "hytale-server";
  runtimeInputs = [ jdk25 bash coreutils ];
  text = ''
    # The working directory (systemd sets it) must contain the extracted
    # server.zip layout: start.sh, Server/HytaleServer.jar, Assets.zip.
    if [ ! -f start.sh ]; then
      echo "hytale-server: start.sh not found in $(pwd)" >&2
      echo "hytale-server: run 'hytale-setup' as the hytale user to install the server files" >&2
      exit 1
    fi
    exec bash start.sh "$@"
  '';

  meta = with lib; {
    description = "Runtime wrapper that invokes the vendor start.sh for a Hytale dedicated server";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "hytale-server";
  };
}
