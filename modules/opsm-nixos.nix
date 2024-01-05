{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkOption types;
  inherit (config.users) users;
  cfg = config.opsm;

  secretType = types.submodule ({config, ...}: {
    options = {
      secretRef = mkOption {
        type = types.str;
        description = ''Reference to the secret in 1Password. Should be in the form "op://vault/entry/field".'';
        example = "op://vault/entry/field";
      };

      user = mkOption {
        type = types.str;
        description = "Owner of the installed file.";
        default = "0";
      };

      group = mkOption {
        type = types.str;
        description = "Group owner of the installed file.";
        default = users.${config.user}.group or "0";
      };

      mode = mkOption {
        type = types.str;
        description = "Access permissions of the installed file, in a form understood by chmod.";
        default = "0400";
      };

      sshKey = mkEnableOption "Use if the secret is an SSH private key, load it in openssh format";
    };
  });
in {
  options.opsm = {
    enable = mkEnableOption "1Password secrets management";

    tmpfs = mkEnableOption "Enable mounting /run/secrets on tmpfs if it has not been done yet.";

    secretDir = mkOption {
      type = types.str;
      default = "/run/secrets";
      description = ''
        Path to the keys downloaded with 1password.
      '';
    };

    serviceAccountTokenPath = mkOption {
      type = types.str;
      default = "/etc/opsm-token";
      description = ''
        Path to the token for the 1Password Service Account. This should be a string literal,
        not a path, so as to avoid copying the token to the world-readable Nix store.
        This file should only be readable by root:root, with mode 0400.
      '';
    };

    refreshInterval = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Interval, in seconds, at which all secrets should be re-read from 1Password.
        If null, secrets will not be refreshed except for when the backing service is restarted.

        Keep in mind the request quotas documented on 1Password's website: https://developer.1password.com/docs/service-accounts/get-started/#request-quotas
      '';
    };

    secrets = mkOption {
      type = types.attrsOf secretType;
      default = {};
      description = ''
        Attribute set of secrets to be deployed to the machine. These will be read from 1Password
        using the CLI and the service account token located in opsm.serviceAccountTokenPath.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # During activation, ensure a ramfs exists at the destination directory
    # TODO use admin group instead of keys if isDarwin
    system.activationScripts.opsm-secrets-init = lib.mkIf cfg.tmpfs {
      # This activation script is based off of agenix's mountCommand activation
      text = ''
        mkdir -p ${cfg.secretDir}
        chmod 0751 ${cfg.secretDir}
        if ! grep -q "${cfg.secretDir} tmpfs" /proc/mounts; then
          mount -t tmpfs none ${cfg.secretDir} -o nodev,nosuid,mode=0751
        fi
        chown :keys ${cfg.secretDir}
      '';
    };

    # Create a target to group all secret services
    systemd.targets.opsm-secrets = {};

    # Create services for each secret and a service that resolves when all keys are deployed
    systemd.services = lib.mapAttrs' (n: v: lib.nameValuePair "opsm-secret-${n}" {
      enable = true;

      serviceConfig.TimeoutStartSec = "5m";
      serviceConfig.Restart = if cfg.refreshInterval != null then "always" else "on-failure";
      serviceConfig.RestartSec = "1s";
      unitConfig.ConditionPathExists = cfg.serviceAccountTokenPath;

      path = with pkgs; [ _1password curl ];

      # `op` errors out without a config directory set
      environment.OP_CONFIG_DIR = "/root/.config/op";

      # We need Internet access to read from 1Password
      wants = ["network-online.target"];
      after = ["network-online.target"];

      wantedBy = ["opsm-secrets.target" "multi-user.target"];

      script = ''
        export OP_SERVICE_ACCOUNT_TOKEN=$(cat ${cfg.serviceAccountTokenPath})

        # Wait up to 60s to reach 1Password
        OP_URL=$(op whoami | grep "URL" | sed 's/.*  //')
        RETRIES=4
        while [[ $RETRIES -gt 0 ]] && ! curl -fs -o /dev/null $OP_URL; do
          RETRIES=$(($RETRIES - 1))
          echo "Waiting to reach 1Password..."
          sleep 15
        done
        if [[ $RETRIES -eq 0 ]]; then
          echo "Could not reach 1Password!"
          exit 1
        fi

        # Create file with permissions before installing secret material
        export SECRET_FILE="${cfg.secretDir}/${n}"
        if [ ! -f $SECRET_FILE ]; then
          touch $SECRET_FILE
        fi
        chown ${v.user}:${v.group} $SECRET_FILE

        op read -o $SECRET_FILE --file-mode ${v.mode} --force "${v.secretRef}${if cfg.sshKey then "?ssh-format=openssh" else ""}"

        ${if cfg.sshKey then ''
          printf "\n" >> $SECRET_FILE
        '' else ""}

        ${if cfg.refreshInterval != null then ''
          sleep ${builtins.toString cfg.refreshInterval}
        '' else ""}
      '';
    }) cfg.secrets;
  };
}
