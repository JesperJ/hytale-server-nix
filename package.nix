{ lib
, writeShellApplication
, jdk25
, coreutils
}:

writeShellApplication {
  name = "hytale-server";
  runtimeInputs = [ jdk25 coreutils ];
  text = ''
    # Wrapper that runs HytaleServer.jar from the current working directory.
    # Expects HytaleServer.jar and Assets.zip to be present in cwd.
    #
    # Environment variables:
    #   HYTALE_HEAP_SIZE   JVM max heap (e.g. "4G"). Default: 4G.
    #   HYTALE_JAVA_OPTS   Extra JVM args, space-separated. Default: "".
    #   HYTALE_SERVER_ARGS Extra server args passed after --. Default: "".
    #   HYTALE_AOT_CACHE   If set to "1", enable Java 25 AOT cache at HytaleServer.aot.

    heap="''${HYTALE_HEAP_SIZE:-4G}"
    aot_flag=""
    if [ "''${HYTALE_AOT_CACHE:-0}" = "1" ]; then
      aot_flag="-XX:AOTCache=HytaleServer.aot"
    fi

    if [ ! -f HytaleServer.jar ]; then
      echo "hytale-server: HytaleServer.jar not found in $(pwd)" >&2
      echo "hytale-server: place HytaleServer.jar and Assets.zip in the working directory" >&2
      exit 1
    fi
    if [ ! -f Assets.zip ]; then
      echo "hytale-server: Assets.zip not found in $(pwd)" >&2
      exit 1
    fi

    # shellcheck disable=SC2086
    exec java \
      -Xms"$heap" -Xmx"$heap" \
      $aot_flag \
      ''${HYTALE_JAVA_OPTS:-} \
      -jar HytaleServer.jar \
      --assets Assets.zip \
      ''${HYTALE_SERVER_ARGS:-}
  '';

  meta = with lib; {
    description = "Wrapper for running a Hytale dedicated server (HytaleServer.jar)";
    longDescription = ''
      This package is a small shell wrapper that launches HytaleServer.jar
      with Java 25. The jar itself is not included and must be provided by
      the user in the working directory; it is proprietary Hypixel Studios
      software governed by the Hytale EULA. The wrapper itself is MIT.
    '';
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "hytale-server";
  };
}
