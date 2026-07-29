{ config, lib, pkgs, ... }:

let
  cfg = config.services.hytale-server;
  # StateDirectory hardcodes the on-disk location at /var/lib/<name>. For
  # servers that need to live on a different filesystem (larger disk, etc.),
  # bind-mount an existing directory over /var/lib/hytale-server before the
  # service starts.
  stateDirName = "hytale-server";
  dataDir = "/var/lib/${stateDirName}";
in
{
  options.services.hytale-server = {
    enable = lib.mkEnableOption "Hytale dedicated server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The hytale-server runtime wrapper package.";
    };

    setupPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./setup.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./setup.nix { }";
      description = "The hytale-setup bootstrap installer package.";
    };

    ctlPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./console.nix { inherit (cfg) fifoPath; };
      defaultText = lib.literalExpression ''
        pkgs.callPackage ./console.nix { inherit (cfg) fifoPath; }
      '';
      description = ''
        The hytalectl admin-console client package. Defaults to a build of
        `console.nix` with `fifoPath` set to `cfg.fifoPath`, so the client
        knows where to write.
      '';
    };

    fifoPath = lib.mkOption {
      type = lib.types.path;
      default = "/run/hytale-server-console";
      description = ''
        Path to the console FIFO. Both the systemd socket unit and the
        `hytalectl` client default to this path — they stay in sync
        because the module passes this value into both.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "hytale";
      description = "User account under which the server runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "hytale";
      description = "Group under which the server runs.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5520;
      description = "UDP port the server listens on. Hytale does not use TCP.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to open the configured UDP port in the firewall. Off by
        default — set to `true` if players need to reach the server
        directly. A game server that isn't reachable does nothing, so
        this is usually what you want; it's opt-in to match NixOS
        convention (explicit exposure).
      '';
    };

    consoleGroup = lib.mkOption {
      type = lib.types.str;
      default = "wheel";
      description = ''
        Group allowed to send commands to the server via `hytalectl`. The
        console FIFO at `${cfg.fifoPath}` is created with mode `0620`, owner
        `${cfg.user}`, group `<this>` — group members can write commands
        but not read the FD.
      '';
    };

    heapSize = lib.mkOption {
      # JVM syntax: digits followed by a single unit suffix (k/K, m/M, g/G).
      # Rejects "4 GB", "large", or plain "4096" at eval time rather than
      # letting the JVM fail with a cryptic "Invalid initial heap size" at
      # service start.
      type = lib.types.strMatching "[0-9]+[kKmMgG]";
      default = "4G";
      example = "8G";
      description = ''
        JVM heap size (used for both `-Xms` and `-Xmx`). Digits followed by
        a `k`/`m`/`g` suffix (KB/MB/GB). Written into
        `${dataDir}/jvm.options`, which the vendor `start.sh` picks up.
        Rough guidance: 4G for 1–10 players, 8–12G for 25–50, 16G+ for
        larger servers.
      '';
    };

    extraJvmOpts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-XX:+UseG1GC" ];
      description = ''
        Extra JVM arguments appended to `${dataDir}/jvm.options` (one per
        line, as the JVM `@-file` syntax expects).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      home = dataDir;
      createHome = false;   # StateDirectory creates it with the right perms
      group = cfg.group;
      description = "Hytale dedicated server";
    };

    users.groups.${cfg.group} = { };

    # Expose all three commands system-wide. `hytale-setup` for first install
    # (x86_64-only — Hytale's downloader binary is amd64); `hytale-server` for
    # running the server interactively (still occasionally useful for
    # debugging); `hytalectl` for sending admin commands to the running
    # systemd service.
    environment.systemPackages = [ cfg.package cfg.ctlPackage ]
      ++ lib.optional (pkgs.stdenv.hostPlatform.system == "x86_64-linux") cfg.setupPackage;

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedUDPPorts = [ cfg.port ];
    };

    # Console FIFO — systemd creates it on socket-unit start, wires it to the
    # service's stdin via `StandardInput=socket`. `hytalectl` writes to it.
    # Mode 0620 = owner rw, group w only (reading a FIFO the server owns has
    # no useful semantics, but writing does).
    systemd.sockets.hytale-server = {
      description = "Hytale dedicated server console FIFO";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenFIFO = cfg.fifoPath;
        SocketMode = "0620";
        SocketUser = cfg.user;
        SocketGroup = cfg.consoleGroup;
        RemoveOnStop = true;
      };
    };

    systemd.services.hytale-server = {
      description = "Hytale dedicated server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # bindsTo ties the service's liveness to the socket unit's: if the
      # socket is stopped (which removes the FIFO via RemoveOnStop), the
      # service stops with it — otherwise we'd end up with a running server
      # whose stdin points at a gone inode, and hytalectl silently failing
      # while the service looks healthy. BindsTo is a [Unit] directive, so
      # it lives here at the top level (or under unitConfig), NOT under
      # serviceConfig — systemd silently ignores unknown keys per section.
      bindsTo = [ "hytale-server.socket" ];

      # Regenerate jvm.options on every start so option changes take effect
      # on `nixos-rebuild switch` + service restart (no manual edits needed).
      # $STATE_DIRECTORY is set by systemd from StateDirectory=hytale-server.
      preStart = ''
        cat > "$STATE_DIRECTORY/jvm.options" <<EOF
        # Managed by services.hytale-server — edits will be overwritten.
        -Xms${cfg.heapSize}
        -Xmx${cfg.heapSize}
        ${lib.concatStringsSep "\n" cfg.extraJvmOpts}
        EOF
      '';

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;

        # StateDirectory creates /var/lib/hytale-server owned by User:Group,
        # exposes it as $STATE_DIRECTORY, and (crucially under ProtectSystem=
        # strict) grants write access without needing an explicit
        # ReadWritePaths entry.
        StateDirectory = stateDirName;
        StateDirectoryMode = "0750";
        WorkingDirectory = dataDir;
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = "10s";

        # Wire the socket-provided FIFO as this service's stdin, so anything
        # `hytalectl` writes to /run/hytale-server-console lands on the JVM's
        # System.in via start.sh's transparent stdin passthrough.
        Sockets = "hytale-server.socket";
        StandardInput = "socket";
        StandardOutput = "journal";
        StandardError = "journal";

        # Hardening. MemoryDenyWriteExecute is disabled — the JIT needs W+X.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        # ReadWritePaths not needed — StateDirectory grants write access.
      };
    };
  };
}
