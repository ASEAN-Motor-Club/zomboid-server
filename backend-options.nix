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
  };
in {
  options = backendOptions;
}
