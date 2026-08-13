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

  # --- Declarative server.ini rendering ---
  # Assemble the full override-only <servername>.ini content from the module's
  # declarative options (settings + workshopItems + mods + discord). DiscordToken
  # is intentionally NOT here; it's injected at boot from the agenix secret.
  #
  # PZ's ConfigFile.read() splits on '=' WITHOUT trimming the key, so every key
  # must be no-space (crudini emits exactly that). PZ auto-generates every key we
  # don't pin, so this is "override-only" — but it is re-applied EVERY boot, so no
  # single `cp -n` stale-file trap can silently drop a key again.
  renderedIni = pkgs.writeText "server.ini" (
    concatStringsSep "\n" (
      (mapAttrsToList (k: v: "${k}=${v}") cfg.settings)
      ++ [
        "WorkshopItems=${concatStringsSep ";" cfg.workshopItems}"
        "Mods=${concatStringsSep ";" cfg.mods}"
      ]
      ++ optional cfg.discord.enable "DiscordEnable=true"
      ++ optionalString (cfg.discord.enable && cfg.discord.chatChannel != "") "DiscordChatChannel=${cfg.discord.chatChannel}"
      ++ optionalString (cfg.discord.enable && cfg.discord.logChannel != "") "DiscordLogChannel=${cfg.discord.logChannel}"
      ++ optionalString (cfg.discord.enable && cfg.discord.commandChannel != "") "DiscordCommandChannel=${cfg.discord.commandChannel}"
    ) + "\n"
  );

  # Systemd unit runs with a restricted PATH; reconcileIni needs python3.
  reconcilePath = lib.makeBinPath (with pkgs; [ python3 coreutils gnused ]);

  # Idempotent, no-space INI reconcile. PZ's ConfigFile.read() splits on '=' and
  # does NOT trim the key, so `Key = value` (crudini's default spacing) becomes
  # key "Key " which never matches and is silently dropped. This script rewrites
  # ONLY the keys present in the desired override file, preserving PZ's own
  # runtime-generated keys (and their positions), and emits no-space `key=value`.
  reconcileIni = pkgs.writeScript "reconcile-ini" ''
    #!${pkgs.python3}/bin/python3
    import os, sys
    target, desired = sys.argv[1], sys.argv[2]
    lines = []
    if os.path.exists(target):
        lines = open(target).read().splitlines()
    want = {}
    for raw in open(desired).read().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        want[k] = v
    pos = {}
    for i, l in enumerate(lines):
        s = l.strip()
        if "=" in s:
            pos[s.split("=", 1)[0]] = i
    for k, v in want.items():
        kv = f"{k}={v}"
        if k in pos:
            lines[pos[k]] = kv
        else:
            lines.append(kv)
            pos[k] = len(lines) - 1
    seen = set()
    out = []
    for l in lines:
        s = l.strip()
        if "=" in s:
            k = s.split("=", 1)[0]
            if k in want and k in seen:
                continue
            if k in want:
                seen.add(k)
        out.append(l)
    open(target, "w").write("\n".join(out) + ("\n" if out else ""))
  '';

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
        # Restart=always (not on-failure): the "Server Workshop Mod Update
        # Checker & Auto-Restart" (3659447892) shuts the server down cleanly to
        # re-sync updated workshop items. A clean quit exits 0 (success), which
        # on-failure would NOT restart — but we WANT it to bounce so the mod
        # loop absorbs mid-day workshop updates. always covers both clean-exit
        # restarts AND crash restarts. (systemctl stop still stops normally.)
        Restart = "always";
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

        # Reconcile the declarative server config onto the live <servername>.ini
        # EVERY boot (idempotent). Unlike the old single `cp -n` seed — where a
        # stale file silently kept old values and the whole config could be wiped
        # by deleting it — this re-asserts every declaratively-declared key each
        # boot, so nothing can drift or be dropped. PZ's runtime-generated keys
        # (config it writes back) are preserved by reconcileIni.
        SRV="$STATE_DIRECTORY/Zomboid/Server"
        SERVER_INI="$STATE_DIRECTORY/Zomboid/Server/${cfg.serverName}.ini"
        mkdir -p "$SRV"
        export PATH="${reconcilePath}:$PATH"
        ${reconcileIni} "$SERVER_INI" ${renderedIni}

        # Discord bot token is a SECRET from agenix, never rendered into the nix
        # store seed. Inject it on every boot so a reconcile can't empty it.
        # (Write to a temp desired-file; avoid process substitution in the shell.)
        if [ -n "${cfg.discordTokenFile}" ] && [ -f "${cfg.discordTokenFile}" ]; then
          token_seed="$(mktemp)"
          ( umask 077; echo "DiscordToken=$(cat ${cfg.discordTokenFile})" > "$token_seed" )
          ${reconcileIni} "$SERVER_INI" "$token_seed"
          rm -f "$token_seed"
        fi

        cp -n --no-preserve=mode,ownership ${./Configs}/server_spawnregions.lua "$SRV/${cfg.serverName}_spawnregions.lua" 2>/dev/null || true

        # PZ binds TWO UDP sockets: -port (Steam query, defaultPort=cfg.port)
        # and -udpport (RakNet). They MUST differ; passing the same value makes
        # RakNet try to bind the same port twice and abort startup with
        # "Connection Startup Failed. Code: 5" (RakPeer.Startup returns
        # RAKNET_SOCKET_BIND_FAILED). The RakNet port is cfg.port + 1, which is
        # also the second port the firewall opens (cfg.port and cfg.port + 1).
        exec ${pkgs.steam-run}/bin/steam-run "$STATE_DIRECTORY/start-server.sh" \
          -cachedir="$STATE_DIRECTORY/Zomboid" \
          -servername "${cfg.serverName}" \
          -port ${toString cfg.port} \
          -udpport ${toString (cfg.port + 1)} \
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
