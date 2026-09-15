# `nixhold.checks` — what the fleet asserts about its own services,
# option namespace (ARCHITECTURE "Provisioning": Checks are units
# too).
#
# One declaration is one system-scope unit, `nixhold-check-<name>`,
# rendered by lib/provisioning.nix like every other provisioning unit:
# it runs the script after the units it names, retries on failure
# every 30 s while the evidence is not there yet, and stays inactive
# once it passes. It has no done marker, because a check is re-run by
# every deploy.
#
# The evidence a check reads (a socket's group, a row in a database,
# what a daemon logged at start) is on the host, so the check runs
# there and its state is what `nixhold deploy` prints after activation
# and what `nixhold status <host>`'s live line shows. The framework
# renders the unit and reads its state; the script is the fleet's own.
#
# Both baselines import this, with the platform half beside it
# (./nixos.nix, ./darwin.nix), so `nixhold.checks` exists on every
# host.
{
  lib,
  pkgs,
  ...
}:
{
  options.nixhold.checks = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, config, ... }:
        {
          options = {
            script = lib.mkOption {
              type = lib.types.either lib.types.path lib.types.lines;
              description = ''
                The check. Exit 0 is a pass; any other exit is a
                failure, and the unit runs it again every 30 s for an
                hour before it stays `failed`, so a check whose
                evidence lands late passes on a later attempt.

                A path value or a package is run as it is; a string
                is the shell source of the check, even when it is a
                single store path, so a script may start with one.
              '';
              example = lib.literalExpression ''
                "test \"$(stat -c %G /run/navidrome/socket)\" = caddy"
              '';
            };

            after = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                The units the check is ordered after and pulls in. A
                check that reads what a service produced names that
                service's unit; a check that needs the network names
                the unit that provides it. Nothing is implied: what a
                check is not ordered after, its retry waits for.
              '';
              example = [ "navidrome.service" ];
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "root";
              description = ''
                The uid the check runs as. `root` reads what root can
                read; a check whose evidence belongs to a service's
                own uid names that user instead.
              '';
            };

            program = lib.mkOption {
              internal = true;
              type = lib.types.str;
              description = ''
                What the unit execs: `script` itself when it is a
                path, and otherwise the script written to the store.
                Rendered here so both platform halves run the same
                program.
              '';
            };
          };

          # Not `types.path.check`: it admits any string that starts
          # with `/`, so shell source whose first token is a store
          # path would reach systemd verbatim, and systemd runs no
          # shell.
          config.program =
            if builtins.isPath config.script || lib.isDerivation config.script then
              "${config.script}"
            else
              "${pkgs.writeShellScript "nixhold-check-${name}" config.script}";
        }
      )
    );
    description = ''
      The fleet's assertions about its services, one system unit each.
      Every deploy re-runs them and reports their state, and
      `nixhold status <host>` reads the same units.
    '';
    example = lib.literalExpression ''
      {
        navidrome-socket = {
          after = [ "navidrome.service" ];
          script = "test \"$(stat -c %G /run/navidrome/socket)\" = caddy";
        };
      }
    '';
  };
}
