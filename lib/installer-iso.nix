# The fleet installer ISO's own module, per ROADMAP "Fleet
# installer ISO". Not part of either baseline bundle — the only
# consumer is `mkFleet`, which pairs it with nixpkgs'
# `installation-cd-minimal` and exposes the result as
# `packages.<arch>.installerIso`.
#
# The image is THIN by contract: CLI + tool belt, the operator's
# login pubkeys on root, and exactly two ciphertexts. No repo
# contents, no plaintext secrets, no host keys, no build closures —
# so it goes stale only when the repo location, the login keys, the
# operator identity, or the deploy key change.
#
# Nothing baked here is unencrypted-secret: stick + passphrase
# equals repo + passphrase, the same boundary as principle 16.
{
  repoUrl,
  operatorAuthorizedKeys,
  ageIdentityWrapped,
  repoDeployKey,
  diskoPackage,
}:
{ lib, pkgs, ... }:
let
  # `<owner>/<repo>` → `<repo>`, matching `programs.nixhold.fleetDir`:
  # the clone the operator makes on the target lands at the same
  # relative place the installed system will look for it.
  repoBasename = lib.last (lib.splitString "/" repoUrl);

  # Both ciphertexts are baked by path, which means they must exist
  # when the image is built. This is build-input checking of two
  # declared layout artifacts, not filesystem discovery — the same
  # exception principle 14 already grants the committed pubkeys under
  # `layout.keysDir`. Nothing is enumerated; both paths are values
  # computed by `mkFleet`.
  bake =
    what: hint: path:
    if builtins.pathExists path then
      path
    else
      throw "nixhold installer ISO: no ${what} at ${toString path} — ${hint}";

  keysEtc = {
    "nixhold/keys/operator.age".source =
      bake "wrapped operator identity" "run `nixhold init` and commit `layout.ageIdentityWrapped`"
        ageIdentityWrapped;

    "nixhold/keys/repo.key.age".source =
      bake "repo deploy key escrow" "run `nixhold iso`, which generates and escrows it before building"
        repoDeployKey;
  };
in
{
  networking.hostName = "nixhold-installer";

  # `root@nixhold-installer.local` — the address the operator reaches
  # a freshly-booted target on without knowing its DHCP lease.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  # The passive `--remote` path needs zero typing on the target: the
  # operator's own login keys authorize ROOT here (an installer has no
  # operator account, and every install phase is root work anyway).
  # Password login stays closed — the installation-device profile
  # leaves root's password empty.
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };
  users.users.root.openssh.authorizedKeys.keys = operatorAuthorizedKeys;

  # `installation-device.nix` autologins the unprivileged `nixos`
  # user; the ISO's whole flow is root work, so take the console.
  services.getty.autologinUser = lib.mkForce "root";

  # agetty expands the escapes when it prints the prompt, so `\4`
  # picks up the DHCP lease even though the image is static. The
  # address is resolved per prompt: a lease acquired after boot shows
  # up on the next one.
  services.getty.helpLine = lib.mkForce ''

    nixhold installer — fleet ${repoUrl}

      this machine:  \4   (also root@nixhold-installer.local)

      run:  nixhold host install

    The passphrase unwraps the operator identity, which decrypts the
    repo deploy key, which clones the fleet. Nothing else is needed.
  '';

  # The installer-environment marker. `host install` refuses local
  # mode without it, so a fleet machine can't be reformatted by a
  # mistyped verb.
  environment.etc = keysEtc // {
    "nixhold-installer".text = "${repoUrl}\n";
  };

  # `environment.variables` (not `sessionVariables`) — these have to
  # reach the autologin root console shell, which reads /etc/profile.
  # The CLI's own resolution honours a pre-set value, so an operator
  # who exports something else still wins.
  environment.variables = {
    NIXHOLD_REPO_URL = repoUrl;
    NIXHOLD_IDENTITY_FILE = "/etc/nixhold/keys/operator.age";
    NIXHOLD_FLEET_DEFAULT = "/root/${repoBasename}";
  };

  # Tool belt, no `gh`: the deploy key is the git-host credential, so
  # the ISO never authenticates against an API.
  environment.systemPackages = [
    (import ../cli { inherit pkgs; })
    diskoPackage
    pkgs.git
    pkgs.gum
    pkgs.age
    pkgs.jq
    pkgs.nixos-facter
  ];

  # The CLI shells out to `nix eval`/`nix build` for every phase.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
