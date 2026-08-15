1|{
2|  lib,
3|  config,
4|  ...
5|}:
6|with lib; let
7|  cfg = config;
8|  backendOptions = {
9|    enable = mkEnableOption "project zomboid server";
10|    enableLogStreaming = mkEnableOption "log streaming";
11|    logsTag = mkOption {
12|      type = types.str;
13|      default = "amc-pz";
14|    };
15|    postInstallScript = mkOption {
16|      type = types.str;
17|      default = "";
18|    };
19|    openFirewall = mkOption {
20|      type = types.bool;
21|      default = false;
22|      description = "Open the required ports for the game server";
23|    };
24|    port = mkOption {
25|      type = types.int;
26|      default = 16261;
27|      description = "Primary UDP port (a second port, port+1, is also opened for direct connections)";
28|    };
29|    user = mkOption {
30|      type = types.str;
31|      default = "steam";
32|      description = "The OS user that the process will run under";
33|    };
34|    stateDirectory = mkOption {
35|      type = types.str;
36|      default = "zomboid-server";
37|      description = "The path where the server will be installed (inside /var/lib)";
38|    };
39|    environment = mkOption {
40|      type = types.attrsOf types.str;
41|      description = "The runtime environment";
42|      default = {};
43|    };
44|    serverName = mkOption {
45|      type = types.str;
46|      default = "servertest";
47|      description = "The PZ internal server name. Selects the save set and the <name>.ini / <name>_*.lua config files.";
48|    };
49|    jvmMinHeap = mkOption {
50|      type = types.str;
51|      default = "8g";
52|      description = "JVM -Xms initial heap size (e.g. 8g)";
53|    };
54|    jvmMaxHeap = mkOption {
55|      type = types.str;
56|      default = "8g";
57|      description = "JVM -Xmx maximum heap size (e.g. 8g)";
58|    };
59|    memoryMax = mkOption {
60|      type = types.str;
61|      default = "12G";
62|      description = "systemd MemoryMax cgroup limit (heap + JVM/native overhead)";
63|    };
64|    cpuAffinity = mkOption {
65|      type = types.nullOr types.str;
66|      default = null;
67|      description = ''
68|        systemd CPUAffinity for the PZ server process (space-separated CPU ids).
69|        Left null when this is a deployment decision — the consumer (e.g. amc-server,
70|        where PZ runs co-located with the Motor Town server) should set it to keep PZ
71|        on cores the game server does NOT pin (MT uses CPUAffinity="0 1 2 3"), so a PZ
72|        restart burst can't steal the other server's physical cores.
73|      '';
74|    };
75|    adminPasswordFile = mkOption {
76|      type = types.nullOr types.path;
77|      default = null;
78|      description = "Path to a file containing the admin password. Passed via -adminpassword to bypass the interactive first-run prompt.";
79|    };
80|    betaBranch = mkOption {
81|      type = types.nullOr types.str;
82|      default = null;
83|      description = "Steam beta branch for the dedicated server (e.g. 'iwillbackupmysave' for the unstable branch)";
84|    };
85|    extraServerArgs = mkOption {
86|      type = types.listOf types.str;
87|      default = [];
88|      description = "Extra arguments appended to start-server.sh";
89|    };
90|    # --- Declarative server.ini authoring (replaces the ad-hoc live-edit trap) ---
91|    # PZ's ConfigFile parser splits on '=' and does NOT trim keys, so:
92|    #   * keys must have NO spaces around '=' (e.g. Public=true, not Public = true),
93|    #   * the whole option is silently skipped otherwise.
94|    # Every key below is re-asserted into <servername>.ini on EVERY boot (an
95|    # idempotent reconcile), so a drift or reseed can never silently drop it the
96|    # way the old single cp -n file seed could. Combined into one attrset below.
97|    settings = mkOption {
98|      type = types.attrsOf types.str;
99|      default = {
100|        Public = "true";
101|        PublicName = "★★ ASEAN Motor Club ★★ | Project Zomboid";
102|        PublicDescription = "<RGB:1,0.85,0>ASEAN Motor Club</RGB> community survival server. Apocalypse difficulty, PVE. Join us: aseanmotorclub.com";
103|        Password = "";
104|        # PingLimit: 0 = DISABLED. SEA players have unstable/bad ping; a
105|        # ping-based kick unfairly locks them out.
106|        PingLimit = "0";
107|        MaxPlayers = "32";
108|        ServerPlayerCount = "32";
109|        MaxAccountsPerUser = "2";
110|        PVP = "false";
111|        PauseEmpty = "true";
112|        GlobalChat = "true";
113|        NoFire = "true";
114|        # Arcadia RV interiors must load BEFORE the base map or entering an RV
115|        # door teleports into the void. vehicle_interior_arcadia75 attaches to
116|        # Muldraugh lots; keep it before Muldraugh in Map= (PZ loads L-to-R).
117|        Map = "vehicle_interior_arcadia75;Muldraugh, KY";
118|        # Arcadia (workshop 3773972040) requires these anti-cheat levels.
119|        AntiCheatSpeed = "4";
120|        AntiCheatNoClip = "4";
121|        # 1=Hidden 2=Friends 3=Friends+nearby 4=Everyone. AMC wants everyone's
122|        # token visible on the map (community survival server).
123|        MapRemotePlayerVisibility = "4";
124|        # Welcome message shown to every player on join. Uses <RGB:r,g,b> for
125|        # color and <LINE> for line breaks. No dynamic tokens supported.
126|        ServerWelcomeMessage = "<RGB:1,0.85,0>** ASEAN Motor Club ** | Project Zomboid</RGB><LINE><LINE><RGB:0.72,0.86,1.0>--- Welcome, Survivor! ---</RGB><LINE><LINE>> PVE Co-operative<LINE>> Infection: Saliva Only (bites)<LINE>> Based on: Apocalypse preset<LINE>> Spawn: Muldraugh, KY<LINE><LINE><RGB:1,0.85,0>Discord: aseanmotorclub.com</RGB><LINE>Happy surviving!";
127|      };
128|      description = ''
129|        Declarative `key=value` overrides for the PZ <servername>.ini — the
130|        non-secret options we pin (Public, MaxPlayers, PingLimit, Map, anti-cheat,
131|        etc.). Re-applied idempotently on every boot. Keys must be no-space around
132|        '='. `workshopItems`/`mods`/`discord` below are merged into the same file.
133|      '';
134|    };
135|    workshopItems = mkOption {
136|      type = types.listOf types.str;
137|      default = [
138|        # FIRST: Server Workshop Mod Update Checker & Auto-Restart (3659447892).
139|        # Author requires it first in load order. A deliberate ADD beyond the
140|        # collection: it polls Steam and self-restarts when a workshop item
141|        # updates, killing mid-day "some mods updated" lockouts.
142|        "3659447892"
143|        # --- AMC Zomboid Modpack (Steam collection 3776174669, 65 items) ---
144|        "2366717227" "2757712197" "2791656602" "2847184718" "2896041179"
145|        "2956146279" "3077900375" "3390487814" "3394044313" "3396446795"
146|        "3405033818" "3416873508" "3423660713" "3430224478" "3432006285"
147|        "3436537035" "3437629766" "3444384263" "3461263912" "3490188370"
148|        "3492967631" "3495594275" "3502080466" "3504700167" "3508537032"
149|        "3526968739" "3536052310" "3543612325" "3546314080" "3555791254"
150|        "3565697910" "3570250507" "3576056135" "3577903007" "3597673472"
151|        "3635591071" "3641048285" "3648051123" "3671176591" "3680577450"
152|        "3690780070" "3716522633" "3723726293" "3725497089" "3734639991"
153|        "3739256725" "3744455714" "3747396551" "3749026793" "3755993986"
154|        "3763470184" "3625933422" "3780965224" "3387539308" "3718216106"
155|        "3386644536" "3566088272" "3281755175" "3385623534" "3470852353"
156|        "3776262249" "3773972040" "3683878228" "3664207077" "3774826484"
157|      ];
158|      description = "Steam collection Workshop IDs, rendered as the WorkshopItems= line (order preserved).";
159|    };
160|    mods = mkOption {
161|      type = types.listOf types.str;
162|      default = [
163|        "ServerWorkshopModAutoRestartB42"
164|        # --- AMC Zomboid Modpack (Steam collection 3776174669) ---
165|        "SwapIt" "VehicleRepairOverhaul" "fhqMotoriousZone" "ProximityInventory"
166|        "errorMagnifier" "RainCleansBlood" "ChuckleberryFinnAlertSystem" "DEON_CVG"
167|        "LightSwitchBacklight" "Buttstroke" "MoodleFramework"
168|        "NoMoreSicknessInsideVehicle" "B42MakeSugar" "ModLoadOrderSorter_b42"
169|        "HydeCoBees" "Makefruitinjar" "UsefulBarrelsMP" "CleanUI" "B42Eggjar"
170|        "CleanHotBar" "Project_Cook" "LanternFix" "Neat_Crafting"
171|        "attach-bag-to-sheet-rope" "NeatUI_Framework" "AutomaticStoveShutoff"
172|        "Neat_Building" "Ivmakk_RestoreEngineQuality" "Waterpipes"
173|        "Ivmakk_BoilingEggs" "WeatherMoodles" "TwisTonFireFasterActions"
174|        "BetterGeneratorInfo" "VanillaFoodsExpanded" "LongTermPreservationExtended"
175|        "RealisticDash" "ItemCondition_KingEJ" "InjuredZombiesStumble"
176|        "dustinguished_bolt_cutters" "SolarFloodlight" "RealisticCookingTimes"
177|        "VHSSkillNameInTooltip" "Neat_Rocco" "ComputerModkum" "SeedSeasonIndicator"
178|        "NewMusic" "PagerMod" "FoodDrying" "CVI" "GasPumpIndicator"
179|        "PropaneExchangeCabinet" "FixedLightOnBeltAF" "AMCMusic" "AutoMechanics"
180|        "Battery Drain Multiplier" "saullevelup" "Mad_EasySetAlarm"
181|        "VanillaVehiclesAnimated" "RechargeableBatteries" "ImprovedFarmingInfoWindow"
182|        "PingItemsFriends" "ArcadiaRVInterior_B42_MP" "ArcadiaRVInterior_B42_Vanilla"
183|        "B42FRUsedCarsAnimAlpha" "FRCert_RVsOnly_B42" "JumboTreeIndoorFix"
184|      ];
185|      description = "Internal mod IDs, rendered as the Mods= line (order preserved). MUST keep the auto-restart mod first.";
186|    };
187|    discord = mkOption {
188|      type = types.submodule {
189|        options = {
190|          enable = mkEnableOption "native PZ Discord integration (DiscordEnable)";
191|          chatChannel = mkOption {
192|            type = types.str;
193|            default = "";
194|            description = "Two-way bridge channel (in-game /all ↔ Discord).";
195|          };
196|          logChannel = mkOption {
197|            type = types.str;
198|            default = "";
199|            description = "Server log events channel (join/leave/death).";
200|          };
201|          commandChannel = mkOption {
202|            type = types.str;
203|            default = "";
204|            description = "Discord-commands channel (optional).";
205|          };
206|        };
207|      };
208|      default = {};
209|      description = "PZ native Discord integration. Channels are non-secret; the bot token comes from discordTokenFile.";
210|    };
211|    discordTokenFile = mkOption {
212|      type = types.nullOr types.path;
213|      default = null;
214|      description = "Path to a file containing the Discord bot token (an agenix secret). Injected into <servername>.ini on every boot; never committed.";
215|    };
216|    # --- Declarative SandboxVars.lua overrides ---
217|    # PZ writes mod sandbox settings into <servername>_SandboxVars.lua at runtime
218|    # (it is NOT seeded by the module — the server owns it). Nix build-time
219|    # patching can't reach a runtime-generated file, so we reconcile the keys we
220|    # want to pin on every boot (same model as `settings` for the .ini): a small
221|    # block-scoped Lua rewrite, keyed by the mod block (e.g. the auto-restart
222|    # mod's WorkshopModServerUpdate) then by the option key.
223|    sandboxVars = mkOption {
224|      type = types.attrsOf (types.attrsOf types.str);
225|      default = {
226|        # Server Workshop Mod Update Checker & Auto-Restart (3659447892): after
227|        # it detects a workshop update it shuts the server down for re-sync. This
228|        # is the countdown delay from detection to shutdown. Default is 1 minute;
229|        # 5 gives players breathing room to log out before the bounce.
230|        WorkshopModServerUpdate = {
231|          RestartDelayMinutes = "5";
232|        };
233|        # ZombieLore: virus transmission mode. Community PVE server —
234|        # Saliva Only (2) means only zombie bites can infect, not scratches
235|        # or lacerations. (1=Blood+Saliva, 2=Saliva Only, 3=Everyone,
236|        # 4=None)
237|        ZombieLore = {
238|          Transmission = "2";
239|        };
240|      };
241|      description = "Declarative per-block overrides written into <servername>_SandboxVars.lua every boot (idempotent). Keyed by Lua block name, then by option key. E.g. { WorkshopModServerUpdate = { RestartDelayMinutes = \"5\"; }; }";
242|    };
243|  };
244|in {
245|  options = backendOptions;
246|}
247|