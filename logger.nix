{
  lib,
  pkgs,
  config,
  ...
}:
with lib; let
  cfg = config.services.zomboid-server-logger;
in {
  options.services.zomboid-server-logger = {
    enable = lib.mkEnableOption "Project Zomboid server log streaming";
    serverLogsPath = mkOption {
      type = types.str;
      description = "The path to the server logs directory";
    };
    tag = mkOption {
      type = types.str;
      description = "The tag for log lines";
      default = "amc-pz";
    };
  };

  config = mkIf cfg.enable {
    services.rsyslogd.extraConfig = ''
      input(type="imfile"
        File="${cfg.serverLogsPath}/*.txt"
        Tag="${cfg.tag}"
        ruleset="mt-out"
        addMetadata="on"
      )
    '';
  };
}
