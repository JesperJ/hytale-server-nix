{ config, lib, pkgs, ... }:

let
  cfg = config.services.hytale-server;
  hytalePkg = pkgs.callPackage ./package.nix { };
in
{
  options.services.hytale-server = {
    enable = lib.mkEnableOption "Hytale dedicated server";

    package = lib.mkOption {
      type = lib.types.package;
      default = hytalePkg;
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The hytale-server wrapper package to use.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hytale-server";
      description = ''
        Working directory for the server. You must place `HytaleServer.jar`
        and `Assets.zip` here before starting the service. Worlds, config,
        mods, and auth tokens are stored here as well.
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

    heapSize = lib.mkOption {
      type = lib.types.str;
      default = "4G";
      example = "8G";
      description = ''
        JVM heap size (used for both `-Xms` and `-Xmx`). Rough guidance:
        4G for 1–10 players, 8–12G for 25–50, 16G+ for larger.
      '';
    };

    aotCache = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable Java 25's AOT cache (`-XX:AOTCache=HytaleServer.aot`).
        First launch trains the cache; subsequent launches use it.
      '';
    };

    extraJavaOpts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-XX:+UseZGC" ];
      description = "Extra JVM arguments.";
    };

    extraServerArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--allow-op" ];
      description = ''
        Extra arguments passed to HytaleServer.jar. Note: `--allow-op` lets
        any player run `/op self`, so avoid it on public servers.
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

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
    ];

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedUDPPorts = [ cfg.port ];
    };

    systemd.services.hytale-server = {
      description = "Hytale dedicated server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HYTALE_HEAP_SIZE = cfg.heapSize;
        HYTALE_AOT_CACHE = if cfg.aotCache then "1" else "0";
        HYTALE_JAVA_OPTS = lib.concatStringsSep " " cfg.extraJavaOpts;
        HYTALE_SERVER_ARGS = lib.concatStringsSep " " cfg.extraServerArgs;
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = "10s";

        # Hardening
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
        MemoryDenyWriteExecute = false; # JIT needs W+X
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        ReadWritePaths = [ cfg.dataDir ];
      };
    };
  };
}
