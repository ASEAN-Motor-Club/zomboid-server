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
      # NOTE: use `optional`, not `optionalString`, here — these are concatenated
      # into a list, and optionalString returns a scalar string (type error).
      ++ optional (cfg.discord.enable && cfg.discord.chatChannel != "") "DiscordChatChannel=${cfg.discord.chatChannel}"
      ++ optional (cfg.discord.enable && cfg.discord.logChannel != "") "DiscordLogChannel=${cfg.discord.logChannel}"
      ++ optional (cfg.discord.enable && cfg.discord.commandChannel != "") "DiscordCommandChannel=${cfg.discord.commandChannel}"
    ) + "\n"
  );

  # Systemd unit runs with a restricted PATH; reconcileIni needs python3.
  reconcilePath = lib.makeBinPath (with pkgs; [ python3 coreutils gnused ]);

  # Flatten declarative sandboxVars ({BlockName = { key = value; };}) into
  # reconcileLua's desired format: one `BlockName.key=value` line per pinned key.
  renderedSandbox = pkgs.writeText "sandbox-overrides.txt" (
    concatStringsSep "\n" (
      mapAttrsToList (block: vars:
        concatStringsSep "\n" (
          mapAttrsToList (k: v: "${block}.${k}=${v}") vars
        )
      ) cfg.sandboxVars
    ) + "\n"
  );

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

  # Block-scoped, idempotent Lua reconcile for <servername>_SandboxVars.lua.
  # PZ generates this file at runtime (and re-merges mod sandbox sections), so we
  # can't build-time patch it. Instead we rewrite declared keys inside their
  # `BlockName = { ... }` section on every boot. Preserves everything else
  # (comments, order, other mods' keys) and asserts each key even if PZ
  # regenerates the block from a fresh default.
  reconcileLua = pkgs.writeScript "reconcile-lua" ''
    #!${pkgs.python3}/bin/python3
    import os, re, sys
    target = sys.argv[1]
    # desired: lines "BlockName.key=value" (one per pinned key)
    want = []
    for raw in open(sys.argv[2]).read().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "." not in line or "=" not in line:
            continue
        block, kv = line.split(".", 1)
        k, v = kv.split("=", 1)
        want.append((block.strip(), k.strip(), v.strip()))
    lines = []
    if os.path.exists(target):
        lines = open(target).read().splitlines()
    def block_start_re():
        return re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{')
    # Find each `Name = {` and its matching closing brace at the same indent.
    def find_block(name):
        res = []
        for i, l in enumerate(lines):
            m = block_start_re().match(l)
            if m and m.group(2) == name:
                indent = len(m.group(1))
                # find closing brace at same indent
                j = i + 1
                while j < len(lines):
                    if re.match(r'^' + r'\s' * indent + r'\},?\s*$', lines[j]):
                        break
                    j += 1
                res.append((i, j, indent))
        return res
    for block, key, val in want:
        blocks = find_block(block)
        if not blocks:
            continue  # block not present yet (mod not loaded); nothing to patch
        for (si, ei, indent) in blocks:
            key_done = False
            for j in range(si + 1, ei):
                km = re.match(r'^(\s*)' + re.escape(key) + r'\s*=\s*([^,]+),?\s*$', lines[j])
                if km:
                    lines[j] = km.group(1) + f"{key} = {val},"
                    key_done = True
                    break
            if not key_done:
                # insert after the opening brace
                lines.insert(si + 1, (" " * (indent + 4)) + f"{key} = {val},")
    with open(target, "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
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
    assertions = [{
      assertion = !cfg.updateNotifier.enable || cfg.updateNotifier.webhookFile != null;
      message = "services.zomboid-server.updateNotifier.webhookFile must be set when updateNotifier.enable = true";
    }
    {
      assertion = !cfg.statusNotifier.enable || cfg.statusNotifier.webhookFile != null;
      message = "services.zomboid-server.statusNotifier.webhookFile must be set when statusNotifier.enable = true";
    }
    {
      assertion = !cfg.changelogNotifier.enable || cfg.changelogNotifier.webhookFile != null;
      message = "services.zomboid-server.changelogNotifier.webhookFile must be set when changelogNotifier.enable = true";
    }];

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
        # Consumer-set (deployment decision). null (default) → no CPUAffinity
        # line is emitted. amc-server sets it to keep PZ off Motor Town's cores.
        CPUAffinity = cfg.cpuAffinity;
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

        # Reconcile the declarative sandbox-var overrides into the runtime
        # <servername>_SandboxVars.lua. PZ generates/merges this file itself, so
        # it's not seeded — we assert our pinned keys here every boot instead.
        SBOX="$SRV/${cfg.serverName}_SandboxVars.lua"
        if [ -f "$SBOX" ]; then
          ${reconcileLua} "$SBOX" ${renderedSandbox}
        fi

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

    # Host-side workshop-update notifier. The auto-restart mod logs "Update found
    # for: <mod>" to the PZ unit's journal (console only — players don't see it).
    # This tails that journal and forwards each detection to a Discord webhook.
    # The mod itself is untouched; this only mirrors an already-logged line.
    systemd.services.zomboid-update-notify = lib.mkIf cfg.updateNotifier.enable {
      wantedBy = ["multi-user.target"];
      after = ["network-online.target" "zomboid-server.service"];
      wants = ["network-online.target"];
      description = "Forward PZ workshop-update detections to Discord";
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "5";
      };
      path = with pkgs; [ curl coreutils gnused systemd ];
      script = ''
        set -u
        WEBHOOK="$(cat "${cfg.updateNotifier.webhookFile}")"
        # Tail the PZ unit's journal live. Match the mod's detection line and
        # forward it. curl the JSON via --data-binary so the mod title (which may
        # contain spaces, brackets, quotes) is handled safely by jq, not shell.
        journalctl -u zomboid-server -o cat -f --no-pager \
        | while IFS= read -r line; do
            case "$line" in
              *"Update found for:"*)
                title=''${line#*Update found for: }
                payload=$(${pkgs.jq}/bin/jq -nc --arg t "$title" \
                  '{content: ("[Auto-Restart] A mod updated: **\"" + $t + "\"** — the PZ server will restart to re-sync.")}')
                printf '%s' "$payload" | curl -fsS -o /dev/null \
                  -H "Content-Type: application/json" \
                  --data-binary @- "$WEBHOOK" || true
                ;;
            esac
          done
      '';
    };

    # Periodic server status -> single Discord message (edit-in-place). Runs
    # scripts/pz_status.py on a timer; the script queries A2S on the query port
    # and POST-or-PATCHes one message so the channel stays uncluttered.
    systemd.services.zomboid-status-notify = lib.mkIf cfg.statusNotifier.enable {
      description = "Refresh PZ server status message on Discord";
      serviceConfig = {
        Type = "oneshot";
      };
      path = with pkgs; [ python3 ];  # script uses stdlib only, but pin python3
      script = ''
        set -u
        WEBHOOK="$(cat "${cfg.statusNotifier.webhookFile}")"
        STATE="${dataDir}/zomboid-status-msg-id"
        exec ${pkgs.python3}/bin/python3 ${./scripts/pz_status.py} \
          --webhook-url "$WEBHOOK" \
          --state-file "$STATE" \
          --host 127.0.0.1 \
          --port ${toString cfg.port}
      '';
    };

    systemd.timers.zomboid-status-notify = lib.mkIf cfg.statusNotifier.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.statusNotifier.interval;
        Persistent = true;
        # don't stack if a tick runs long; the refresh is idempotent anyway
        Unit = "zomboid-status-notify.service";
      };
    };
    # Mod/changelog → Discord. Polls the zomboid-server GitHub repo for new
    # master commits, diffs backend-options.nix, and posts readable mod/config
    # changes. Last-seen SHA kept in the state dir so we never replay history.
    systemd.services.zomboid-changelog-notify = lib.mkIf cfg.changelogNotifier.enable {
      description = "Post zomboid-server mod/config changelog to Discord";
      serviceConfig = {
        Type = "oneshot";
      };
      path = with pkgs; [ curl coreutils ];
      script = ''
        set -u
        WEBHOOK="$(cat "${cfg.changelogNotifier.webhookFile}")"
        STATE="${dataDir}/zomboid-changelog-last"
        exec ${pkgs.python3}/bin/python3 ${./scripts/pz_changelog.py} \
          --webhook-url "$WEBHOOK" \
          --state-file "$STATE"
      '';
    };

    systemd.timers.zomboid-changelog-notify = lib.mkIf cfg.changelogNotifier.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.changelogNotifier.interval;
        Persistent = true;
        # idle so a slow poll (Steam title lookup) can't overlap itself
        Unit = "zomboid-changelog-notify.service";
      };
    };
  };
}
