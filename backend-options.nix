{
  lib,
  config,
  ...
}:
with lib; let
  cfg = config;
  backendOptions = {
    enable = mkEnableOption "project zomboid server";
    enableLogStreaming = mkEnableOption "log streaming";
    logsTag = mkOption {
      type = types.str;
      default = "amc-pz";
    };
    postInstallScript = mkOption {
      type = types.str;
      default = "";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the required ports for the game server";
    };
    port = mkOption {
      type = types.int;
      default = 16261;
      description = "Primary UDP port (a second port, port+1, is also opened for direct connections)";
    };
    user = mkOption {
      type = types.str;
      default = "steam";
      description = "The OS user that the process will run under";
    };
    stateDirectory = mkOption {
      type = types.str;
      default = "zomboid-server";
      description = "The path where the server will be installed (inside /var/lib)";
    };
    environment = mkOption {
      type = types.attrsOf types.str;
      description = "The runtime environment";
      default = {};
    };
    serverName = mkOption {
      type = types.str;
      default = "servertest";
      description = "The PZ internal server name. Selects the save set and the <name>.ini / <name>_*.lua config files.";
    };
    jvmMinHeap = mkOption {
      type = types.str;
      default = "8g";
      description = "JVM -Xms initial heap size (e.g. 8g)";
    };
    jvmMaxHeap = mkOption {
      type = types.str;
      default = "8g";
      description = "JVM -Xmx maximum heap size (e.g. 8g)";
    };
    memoryMax = mkOption {
      type = types.str;
      default = "12G";
      description = "systemd MemoryMax cgroup limit (heap + JVM/native overhead)";
    };
    cpuAffinity = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        systemd CPUAffinity for the PZ server process (space-separated CPU ids).
        Left null when this is a deployment decision — the consumer (e.g. amc-server,
        where PZ runs co-located with the Motor Town server) should set it to keep PZ
        on cores the game server does NOT pin (MT uses CPUAffinity="0 1 2 3"), so a PZ
        restart burst can't steal the other server's physical cores.
      '';
    };
    adminPasswordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing the admin password. Passed via -adminpassword to bypass the interactive first-run prompt.";
    };
    betaBranch = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Steam beta branch for the dedicated server (e.g. 'iwillbackupmysave' for the unstable branch)";
    };
    extraServerArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra arguments appended to start-server.sh";
    };
    # --- Declarative server.ini authoring (replaces the ad-hoc live-edit trap) ---
    # PZ's ConfigFile parser splits on '=' and does NOT trim keys, so:
    #   * keys must have NO spaces around '=' (e.g. Public=true, not Public = true),
    #   * the whole option is silently skipped otherwise.
    # Every key below is re-asserted into <servername>.ini on EVERY boot (an
    # idempotent reconcile), so a drift or reseed can never silently drop it the
    # way the old single cp -n file seed could. Combined into one attrset below.
    settings = mkOption {
      type = types.attrsOf types.str;
      default = {
        Public = "true";
        PublicName = "★★ ASEAN Motor Club ★★ | Project Zomboid";
        PublicDescription = "<RGB:1,0.85,0>ASEAN Motor Club</RGB> community survival server. Apocalypse difficulty, PVE. Join us: aseanmotorclub.com";
        Password = "";
        # PingLimit: 0 = DISABLED. SEA players have unstable/bad ping; a
        # ping-based kick unfairly locks them out.
        PingLimit = "0";
        MaxPlayers = "32";
        ServerPlayerCount = "32";
        MaxAccountsPerUser = "2";
        PVP = "false";
        PauseEmpty = "true";
        GlobalChat = "true";
        NoFire = "true";
        # Arcadia RV interiors must load BEFORE the base map or entering an RV
        # door teleports into the void. vehicle_interior_arcadia75 attaches to
        # Muldraugh lots; keep it before Muldraugh in Map= (PZ loads L-to-R).
        Map = "vehicle_interior_arcadia75;Muldraugh, KY";
        # Arcadia (workshop 3773972040) requires these anti-cheat levels.
        AntiCheatSpeed = "4";
        AntiCheatNoClip = "4";
        # 1=Hidden 2=Friends 3=Friends+nearby 4=Everyone. AMC wants everyone's
        # token visible on the map (community survival server).
        MapRemotePlayerVisibility = "4";
        # true = names only show when you mouse over a player; false = always
        # visible. AMC runs names always-on (community survival server).
        MouseOverToSeeDisplayName = "false";
        # Welcome message shown to every player on join. Uses <RGB:r,g,b> for
        # color and <LINE> for line breaks. No dynamic tokens supported.
        ServerWelcomeMessage = "<RGB:1,0.85,0>** ASEAN Motor Club ** | Project Zomboid</RGB><LINE><LINE><RGB:0.72,0.86,1.0>--- Welcome, Survivor! ---</RGB><LINE><LINE>> PVE Co-operative<LINE>> Infection: Saliva Only (bites)<LINE>> Based on: Apocalypse preset<LINE>> Spawn: Muldraugh, KY<LINE><LINE><RGB:1,0.85,0>Discord: aseanmotorclub.com</RGB><LINE>Happy surviving!";
      };
      description = ''
        Declarative `key=value` overrides for the PZ <servername>.ini — the
        non-secret options we pin (Public, MaxPlayers, PingLimit, Map, anti-cheat,
        etc.). Re-applied idempotently on every boot. Keys must be no-space around
        '='. `workshopItems`/`mods`/`discord` below are merged into the same file.
      '';
    };
    workshopItems = mkOption {
      type = types.listOf types.str;
      default = [
        # FIRST: Server Workshop Mod Update Checker & Auto-Restart (3659447892).
        # Author requires it first in load order. A deliberate ADD beyond the
        # collection: it polls Steam and self-restarts when a workshop item
        # updates, killing mid-day "some mods updated" lockouts.
        "3659447892"
        # --- AMC Zomboid Modpack (Steam collection 3776174669, 64 items) ---
        # NOTE: Item Condition Overlay (3641048285 / ItemCondition_KingEJ) removed
        # deliberately on 2026-08-16 — visual conflicts with another mod. Collection
        # edit handled by operator. This is a deliberate divergence until the
        # collection also drops it.
        "2366717227" "2757712197" "2791656602" "2847184718" "2896041179"
        "2956146279" "3077900375" "3390487814" "3394044313" "3396446795"
        "3405033818" "3416873508" "3423660713" "3430224478" "3432006285"
        "3436537035" "3437629766" "3444384263" "3461263912" "3490188370"
        "3492967631" "3495594275" "3502080466" "3504700167" "3508537032"
        "3526968739" "3536052310" "3543612325" "3546314080" "3555791254"
        "3565697910" "3570250507" "3576056135" "3577903007" "3597673472"
        "3635591071" "3648051123" "3671176591" "3680577450"
        "3690780070" "3716522633" "3723726293" "3725497089" "3734639991"
        "3739256725" "3744455714" "3747396551" "3749026793" "3755993986"
        "3763470184" "3625933422" "3780965224" "3387539308" "3718216106"
        "3386644536" "3566088272" "3281755175" "3385623534" "3470852353"
        "3776262249" "3773972040" "3683878228" "3664207077" "3774826484"
      ];
      description = "Steam collection Workshop IDs, rendered as the WorkshopItems= line (order preserved).";
    };
    mods = mkOption {
      type = types.listOf types.str;
      default = [
        "ServerWorkshopModAutoRestartB42"
        # --- AMC Zomboid Modpack (Steam collection 3776174669) ---
        "SwapIt" "VehicleRepairOverhaul" "fhqMotoriousZone" "ProximityInventory"
        "errorMagnifier" "RainCleansBlood" "ChuckleberryFinnAlertSystem" "DEON_CVG"
        "LightSwitchBacklight" "Buttstroke" "MoodleFramework"
        "NoMoreSicknessInsideVehicle" "B42MakeSugar" "ModLoadOrderSorter_b42"
        "HydeCoBees" "Makefruitinjar" "UsefulBarrelsMP" "CleanUI" "B42Eggjar"
        "CleanHotBar" "Project_Cook" "LanternFix" "Neat_Crafting"
        "attach-bag-to-sheet-rope" "NeatUI_Framework" "AutomaticStoveShutoff"
        "Neat_Building" "Ivmakk_RestoreEngineQuality" "Waterpipes"
        "Ivmakk_BoilingEggs" "WeatherMoodles" "TwisTonFireFasterActions"
        "BetterGeneratorInfo" "VanillaFoodsExpanded" "LongTermPreservationExtended"
        "RealisticDash" "InjuredZombiesStumble"
        "dustinguished_bolt_cutters" "SolarFloodlight" "RealisticCookingTimes"
        "VHSSkillNameInTooltip" "Neat_Rocco" "ComputerModkum" "SeedSeasonIndicator"
        "NewMusic" "PagerMod" "FoodDrying" "CVI" "GasPumpIndicator"
        "PropaneExchangeCabinet" "FixedLightOnBeltAF" "AMCMusic" "AutoMechanics"
        "Battery Drain Multiplier" "saullevelup" "Mad_EasySetAlarm"
        "VanillaVehiclesAnimated" "RechargeableBatteries" "ImprovedFarmingInfoWindow"
        "PingItemsFriends" "ArcadiaRVInterior_B42_MP" "ArcadiaRVInterior_B42_Vanilla"
        "B42FRUsedCarsAnimAlpha" "FRCert_RVsOnly_B42" "JumboTreeIndoorFix"
      ];
      description = "Internal mod IDs, rendered as the Mods= line (order preserved). MUST keep the auto-restart mod first.";
    };
    discord = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "native PZ Discord integration (DiscordEnable)";
          chatChannel = mkOption {
            type = types.str;
            default = "";
            description = "Two-way bridge channel (in-game /all ↔ Discord).";
          };
          logChannel = mkOption {
            type = types.str;
            default = "";
            description = "Server log events channel (join/leave/death).";
          };
          commandChannel = mkOption {
            type = types.str;
            default = "";
            description = "Discord-commands channel (optional).";
          };
        };
      };
      default = {};
      description = "PZ native Discord integration. Channels are non-secret; the bot token comes from discordTokenFile.";
    };
    discordTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing the Discord bot token (an agenix secret). Injected into <servername>.ini on every boot; never committed.";
    };
    # --- Declarative SandboxVars.lua overrides ---
    # PZ writes mod sandbox settings into <servername>_SandboxVars.lua at runtime
    # (it is NOT seeded by the module — the server owns it). Nix build-time
    # patching can't reach a runtime-generated file, so we reconcile the keys we
    # want to pin on every boot (same model as `settings` for the .ini): a small
    # block-scoped Lua rewrite, keyed by the mod block (e.g. the auto-restart
    # mod's WorkshopModServerUpdate) then by the option key.
    # --- Workshop-update Discord notifier ---
    # The auto-restart mod (ServerWorkshopModAutoRestartB42) prints the exact
    # updated mod to the server journal (`[WorkshopModServerUpdate] Update found
    # for: <title>`), but only to the console — players never see it. This option
    # points at a host-side systemd service that tails the PZ unit's journal and
    # forwards each "Update found for:" line to a Discord webhook, so the channel
    # sees WHICH mod updated before the auto-restart bounce. Purely host-side; the
    # mod itself is untouched (its author forbids edits without permission).
    #
    # The in-game countdown timer is left exactly as the mod ships it. This only
    # mirrors the already-logged detection line to Discord.
    updateNotifier = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Discord webhook notifier for workshop updates";
          webhookFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to a file containing the Discord webhook URL (an agenix secret). Never committed.";
          };
        };
      };
      default = {};
      description = "Forward the auto-restart mod's 'Update found for:' journal line to a Discord webhook. Requires the webhook URL as an agenix secret.";
    };
    sandboxVars = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      default = {
        # Server Workshop Mod Update Checker & Auto-Restart (3659447892): after
        # it detects a workshop update it shuts the server down for re-sync. This
        # is the countdown delay from detection to shutdown. Default is 1 minute;
        # 5 gives players breathing room to log out before the bounce.
        WorkshopModServerUpdate = {
          RestartDelayMinutes = "5";
        };
        # ZombieLore: virus transmission mode. Community PVE server —
        # Saliva Only (2) means only zombie bites can infect, not scratches
        # or lacerations. (1=Blood+Saliva, 2=Saliva Only, 3=Everyone,
        # 4=None)
        ZombieLore = {
          Transmission = "2";
        };
        # SandboxVars: electricity grid shutdown timeline. ElecShut is the
        # preset (3 = 14 days - 2 months); ElecShutModifier is the exact day
        # offset and overrides the preset range (30 days after start date).
        # MultiHitZombies: melee weapons strike multiple zombies per swing.
        # true = multi-hit enabled (community survival server wants it).
        # Top-level keys inside the SandboxVars = { ... } block.
        SandboxVars = {
          ElecShut = "3";
          ElecShutModifier = "30";
          MultiHitZombies = "true";
        };
      };
      description = "Declarative per-block overrides written into <servername>_SandboxVars.lua every boot (idempotent). Keyed by Lua block name, then by option key. E.g. { WorkshopModServerUpdate = { RestartDelayMinutes = \"5\"; }; }";
    };
  };
in {
  options = backendOptions;
}
