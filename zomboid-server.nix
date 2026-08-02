{
  lib,
  pkgs,
  config,
  ...
}:
with lib; let
  cfg = config.services.zomboid-server;

  # Paths
  dataDir = "/var/lib/${cfg.stateDirectory}";
  zomboidDir = "${dataDir}/Zomboid";

  # Game Settings
  gameAppId = "380870"; # Project Zomboid Dedicated Server (Steam App ID)

  betaFlag = optionalString (cfg.betaBranch != null) "-beta ${cfg.betaBranch}";

  serverUpdateScript = pkgs.writeScriptBin "zomboid-update" ''
    set -xeu

    ${pkgs.steamcmd}/bin/steamcmd \
      +force_install_dir $STATE_DIRECTORY \
      +login anonymous \
      +app_update ${gameAppId} ${betaFlag} validate \
      +quit
  '';

  # Graceful shutdown: tell the server to save, then quit. PZ reads commands
  # from /run/zomboid-server/server.fifo (its stdin via socket activation).
  # The devs discourage SIGTERM (it does not flush saves), so KillSignal is set
  # to SIGCONT (a no-op) and the quit command exits the JVM cleanly.
  stopScript = pkgs.writeShellScript "zomboid-stop" ''
    echo save > /run/zomboid-server/server.fifo 2>/dev/null || true
    sleep 15
    echo quit > /run/zomboid-server/server.fifo 2>/dev/null || true
  '';
in {
  imports = [
    ./logger.nix
  ];

  options.services.zomboid-server = mkOption {
    type = types.submodule (import ./backend-options.nix);
  };

  config = mkIf cfg.enable {
    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedUDPPorts = [cfg.port (cfg.port + 1)];
    };

    nixpkgs.config.allowUnfreePredicate = lib.mkDefault (pkg:
      builtins.elem (lib.getName pkg) [
        "steam"
        "steamcmd"
        "steam-original"
        "steam-unwrapped"
        "steam-run"
        "motortown-server"
        "steamworks-sdk-redist"
      ]);

    programs.steam = {
      enable = lib.mkDefault true;
      extraCompatPackages = with pkgs; [
        proton-ge-bin
      ];
      protontricks.enable = lib.mkDefault true;
    };

    users.groups.modders = {
      members = [cfg.user "amc"];
      gid = 987;
    };

    systemd.sockets.zomboid-server = {
      description = "Command Input FIFO for Zomboid Server";
      wantedBy = ["sockets.target"];
      socketConfig = {
        ListenFIFO = "/run/zomboid-server/server.fifo";
        SocketUser = cfg.user;
        SocketGroup = "modders";
        SocketMode = "0660";
        DirectoryMode = "0770";
        RemoveOnStop = "true";
      };
    };

    systemd.services.zomboid-server = {
      wantedBy = ["multi-user.target"];
      after = ["network.target" "zomboid-server.socket"];
      requires = ["zomboid-server.socket"];
      description = "Project Zomboid Dedicated Server";
      environment = cfg.environment;
      restartIfChanged = false;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = "modders";
        Restart = "on-failure";
        RestartSec = "10";
        KillSignal = "SIGCONT";
        TimeoutStopSec = "60";
        ExecStop = stopScript;
        StateDirectory = cfg.stateDirectory;
        StateDirectoryMode = "770";
        WorkingDirectory = dataDir;
        StandardInput = "socket";
        StandardOutput = "journal";
        MemoryMax = cfg.memoryMax;
      };

      # NOTE: the steamcmd update + setup run inside ExecStart (not ExecStartPre),
      # so they are NOT bounded by TimeoutStartSec. The first boot downloads ~3 GB
      # and would be killed by the default 90s start timeout if placed in preStart.
      script = ''
        ${lib.getExe serverUpdateScript}

        # steam_appid.txt must contain the GAME app id (108600), not the
        # dedicated server's (380870). A wrong value triggers
        # "Assertion Failed: Illegal termination of worker thread".
        # (Run after the update: steamcmd would otherwise overwrite it.)
        echo 108600 > $STATE_DIRECTORY/steam_appid.txt

        # Patch JVM heap in the freshly downloaded start-server.sh so memory is
        # config-driven. steamcmd re-fetches the script every boot, so re-apply.
        if [ -f "$STATE_DIRECTORY/start-server.sh" ]; then
          sed -i -E 's/-Xms[0-9]+[gGmM]/-Xms${cfg.jvmMinHeap}/g; s/-Xmx[0-9]+[gGmM]/-Xmx${cfg.jvmMaxHeap}/g' "$STATE_DIRECTORY/start-server.sh"
        fi

        # Seed config templates (no-clobber: first boot only). This preserves
        # live reloadoptions edits and world saves across restarts.
        SRV="$STATE_DIRECTORY/Zomboid/Server"
        mkdir -p "$SRV"
        cp -n --no-preserve=mode,ownership ${./Configs}/server.ini "$SRV/${cfg.serverName}.ini" 2>/dev/null || true
        cp -n --no-preserve=mode,ownership ${./Configs}/server_spawnregions.lua "$SRV/${cfg.serverName}_spawnregions.lua" 2>/dev/null || true

        exec ${pkgs.steam-run}/bin/steam-run "$STATE_DIRECTORY/start-server.sh" \
          -cachedir "$STATE_DIRECTORY/Zomboid" \
          -servername "${cfg.serverName}" \
          -port ${toString cfg.port} \
          -udpport ${toString cfg.port} \
          -statistic 0 ${optionalString (cfg.adminPasswordFile != null) ''-adminpassword "$(cat ${cfg.adminPasswordFile})"''} ${lib.escapeShellArgs cfg.extraServerArgs}
      '';
    };

    users.users.${cfg.user} = lib.mkDefault {
      isNormalUser = true;
      packages = [
        pkgs.steamcmd
      ];
    };

    services.zomboid-server-logger = {
      enable = cfg.enableLogStreaming;
      serverLogsPath = "${zomboidDir}/Logs";
      tag = cfg.logsTag;
    };
  };
}
