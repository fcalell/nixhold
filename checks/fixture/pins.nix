# Pins (ARCHITECTURE "Pins"), from both declaration sites: a
# home-manager module declares one, as the operator's tooling does,
# and the host reads it lifted; the host declares another directly.
# The manifests under ./pins stand in for what `nixhold update`
# writes.
{ config, ... }:
let
  hm = config.home-manager.users.${config.nixhold.identity.username};
in
{
  nixhold.home.extraModules = [
    {
      nixhold.pins.fixture-home = {
        file = ./pins/fixture-home.json;
        latest = "https://fixture.example.invalid/home/latest";
        manifest = "https://fixture.example.invalid/home/\${version}/manifest.json";
      };
    }
  ];

  nixhold.pins.fixture-host = {
    file = ./pins/fixture-host.json;
    latest = "https://fixture.example.invalid/host/latest";
    manifest = "https://fixture.example.invalid/host/\${version}/manifest.json";
  };

  assertions = [
    {
      assertion =
        config.nixhold.pins.fixture-home.file == hm.nixhold.pins.fixture-home.file
        && config.nixhold.pins.fixture-home.latest == hm.nixhold.pins.fixture-home.latest
        && config.nixhold.pins.fixture-home.manifest == hm.nixhold.pins.fixture-home.manifest;
      message = "fixture: a pin declared in home-manager is not lifted into the host's nixhold.pins";
    }
    {
      assertion =
        hm.nixhold.pins.fixture-home.value.version == "1.2.3"
        && config.nixhold.pins.fixture-home.value.version == "1.2.3";
      message = "fixture: a pin's value is not its manifest parsed, on both sides";
    }
    {
      assertion = config.nixhold.pins.fixture-host.value.platforms."linux-x64".checksum == "00";
      message = "fixture: a host-declared pin's value does not carry the manifest's fields";
    }
  ];
}
