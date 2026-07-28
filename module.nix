{ config, lib, pkgs, ... }:

let
  cfg = config.services.hytale-server;
  hytalePkg = pkgs.callPackage ./package.nix { };
  hytaleSetup = pkgs.callPackage ./setup.nix { };
  hytalectlPkg = pkgs.callPackage ./console.nix { };
  consoleFifo = "/run/hytale-server-console";
in
{
  options.services.hytale-server = {
    enable = lib.mkEnableOption "Hytale dedicated server";

    package = lib.mkOption {
      type = lib.types.package;
      default = hytalePkg;
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The hytale-server runtime wrapper package.";
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
      default = true;
      description = "Whether to open the configured UDP port in the firewall.";
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

    # Expose all three commands system-wide. `hytale-setup` for first install
    # and updates; `hytale-server` for running the server interactively; and
    # `hytalectl` for sending admin commands to the running systemd service.
    environment.systemPackages = [ cfg.package hytaleSetup hytalectlPkg ];

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
        ReadWritePaths = [ cfg.dataDir ];
      };
    };
  };
}
