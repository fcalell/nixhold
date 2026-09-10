# Fixture coverage for `programs.claude-code-native.profiles`: one
# persona with every field set, so the wrapper is rendered (and
# shellchecked, since fixture-mac's system builds it) and the prompt
# composition is read back. Imported by fixture-mac.
{ config, lib, ... }:
let
  hm = config.home-manager.users.${config.nixhold.identity.username};
  wrappers = lib.filter (p: lib.hasPrefix "claude-" p.name) hm.home.packages;
in
{
  nixhold.home.extraModules = [
    {
      programs.claude-code-native = {
        enable = true;
        profiles.fixture = {
          prompt = [
            ./claude/role.md
            ./claude/replies.md
          ];
          tools = [
            "Read"
            "Bash"
          ];
          memory = ./claude/memory;
          mcp.board = {
            type = "http";
            url = "http://127.0.0.1:1/mcp";
          };
          model = "haiku";
          effort = "low";
        };
      };
    }
  ];

  assertions = [
    {
      assertion = map (p: p.name) wrappers == [ "claude-fixture" ];
      message = "fixture-mac: one profile must render exactly one `claude-<name>` wrapper, got ${
        toString (map (p: p.name) wrappers)
      }";
    }
  ];
}
