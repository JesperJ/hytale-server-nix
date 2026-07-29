{ config, lib, pkgs, ... }:

let
  cfg = config.services.hytale-server;
  consoleFifo = "/run/hytale-server-console";
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
      default = pkgs.callPackage ./console.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./console.nix { }";
      description = "The hytalectl admin-console client package.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hytale-server";
      description = ''
        Working directory for the server. Run `hytale-setup` here (as
        `user`) to install the server files. All worlds, config, mods,
        backups, and auth tokens are stored here.
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
        console FIFO at ${consoleFifo} is created with mode `0620`, owner
        `${"${cfg.user}"}`, group `<this>` — group members can write commands
        but not read the FD.
      '';
    };

    heapSize = lib.mkOption {
      type = lib.types.str;
      default = "4G";
      example = "8G";
      description = ''
        JVM heap size (used for both `-Xms` and `-Xmx`). Written into
        `<dataDir>/jvm.options`, which the vendor `start.sh` picks up.
        Rough guidance: 4G for 1–10 players, 8–12G for 25–50, 16G+ for
        larger servers.
      '';
    };

    extraJvmOpts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-XX:+UseG1GC" ];
      description = ''
        Extra JVM arguments appended to `<dataDir>/jvm.options` (one per
        line, as the JVM `@-file` syntax expects).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      home = cfg.dataDir;
      createHome = false;
      group = cfg.group;
      description = "Hytale dedicated server";
    };

    users.groups.${cfg.group} = { };

    # Expose all three commands system-wide. `hytale-setup` for first install;
    # `hytale-server` for running the server interactively (still occasionally
    # useful for debugging); and `hytalectl` for sending admin commands to the
    # running systemd service.
    environment.systemPackages = [ cfg.package cfg.setupPackage cfg.ctlPackage ];

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
    ];

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
        ListenFIFO = consoleFifo;
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

      # Regenerate jvm.options on every start so option changes take effect
      # on `nixos-rebuild switch` + service restart (no manual edits needed).
      preStart = ''
        cat > ${cfg.dataDir}/jvm.options <<EOF
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
        WorkingDirectory = cfg.dataDir;
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = "10s";

        # Wire the socket-provided FIFO as this service's stdin, so anything
        # `hytalectl` writes to /run/hytale-server-console lands on the JVM's
        # System.in via start.sh's transparent stdin passthrough.
        #
        # BindsTo ties the service's liveness to the socket unit's: if the
        # socket is stopped (which removes the FIFO thanks to RemoveOnStop),
        # the service stops with it — otherwise we'd end up with a running
        # server whose stdin points at a gone inode, and hytalectl silently
        # failing while the service looks healthy.
        Sockets = "hytale-server.socket";
        BindsTo = "hytale-server.socket";
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
        ReadWritePaths = [ cfg.dataDir ];
      };
    };
  };
}
