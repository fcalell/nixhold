# The fleet installer ISO's own module, per ARCHITECTURE "Fleet
# installer ISO". Not part of either baseline bundle — the only
# consumer is `mkFleet`, which pairs it with nixpkgs'
# `installation-cd-minimal` and exposes the result as
# `packages.<arch>.installerIso`.
#
# The image is THIN by contract: CLI + tool belt, the operator's
# login pubkeys on root, and at most two ciphertexts — the fleet's
# `identity` ssh key always (the clone credential), the wrapped
# operator identity only when the fleet commits one. No repo
# contents, no plaintext secrets, no host keys, no build closures —
# so it goes stale only when the repo location, the login keys, the
# operator identity, or the fleet's identity key change.
#
# "Thin" is a property of how the ciphertexts are baked, not just of
# what is named here: `mkFleet` hands over paths *inside the fleet
# checkout*, and a path coerced straight into `environment.etc`
# carries its whole store path — the entire checkout, every host's
# ciphertexts — into the squashfs. `builtins.path` re-adds
# each file as a store path of its own, by content, so the closure
# holds the baked files and nothing around them.
#
# The CLI finds them through the environment (see `NIXHOLD_*`
# below): `$NIXHOLD_IDENTITY_FILE` is the wrapped operator identity
# every verb unwraps, `$NIXHOLD_CLONE_KEY_FILE` the fleet's own
# `identity` ssh key `nh_repo_git` clones and pushes the fleet repo
# with — the forge already authenticates it, so no deploy key of its
# own is minted, registered or revoked.
#
# The operator unlocks the fleet from this image by whichever route
# they hold. A FIDO2 token is the first-class one — the plugin and
# libfido2's udev rules are on the image, and the private half never
# leaves the token — and a passphrase-wrapped identity is the other;
# a fleet may commit both, and must have at least one (asserted
# below), or the booted image reaches nothing.
#
# Nothing baked here is unencrypted-secret: stick + operator route
# equals repo + operator route, the same boundary as principle 16.
{
  repoUrl,
  operatorAuthorizedKeys,
  ageIdentityWrapped,
  ageRecipients,
  cloneKey,
  diskoPackage,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # `<owner>/<repo>` → `<repo>`, matching `programs.nixhold.fleetDir`:
  # the clone the operator makes on the target lands at the same
  # relative place the installed system will look for it.
  repoBasename = lib.last (lib.splitString "/" repoUrl);

  # One ciphertext → one store path, holding that file and nothing
  # else. `mode` (rather than the default symlink) copies the byte
  # content into the image's /etc, so the running system never follows
  # a link back into a store path it did not need. `mkFleet` only
  # emits `installerIso` once the files it names here exist, so there
  # is no existence check to make.
  bake = name: path: {
    source = builtins.path {
      inherit path;
      inherit name;
    };
    mode = "0400";
  };

  # A token-only fleet commits no wrapped identity: there is nothing
  # to bake and nothing to point `$NIXHOLD_IDENTITY_FILE` at, and the
  # CLI resolves the route itself when the variable is unset.
  hasWrappedIdentity = ageIdentityWrapped != null;

  keysEtc = {
    "nixhold/keys/identity.age" = bake "nixhold-identity.age" cloneKey;
  }
  // lib.optionalAttrs hasWrappedIdentity {
    "nixhold/keys/operator.age" = bake "nixhold-operator.age" ageIdentityWrapped;
  };

  # A `age1fido2-hmac1…` line in the fleet's recipients file means a
  # hardware token can decrypt what the image carries.
  hasTokenRecipient = lib.any (lib.hasPrefix "age1fido2-hmac1") ageRecipients;
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

    Your token (or your passphrase) unlocks the operator identity,
    which decrypts the fleet's own SSH key, which clones the fleet.
    Nothing else is needed.
  '';

  # The installer-environment marker. `host install` refuses local
  # mode without it, so a fleet machine can't be reformatted by a
  # mistyped verb.
  environment.etc = keysEtc // {
    "nixhold-installer".text = "${repoUrl}\n";
  };

  # THIN by contract, asserted instead of merely stated: every file
  # this image bakes under /etc/nixhold/keys must be a store path of
  # its own. A path taken straight out of the fleet checkout is a
  # store *sub*path, and carrying one here puts the whole checkout —
  # every host and every ciphertext — into the squashfs. The check
  # is on the merged config, so it also holds for entries a fleet
  # adds itself.
  assertions =
    lib.mapAttrsToList (name: entry: {
      assertion = builtins.dirOf (toString entry.source) == builtins.storeDir;
      message = "nixhold installer ISO: /etc/${name} is baked from ${toString entry.source}, which lives inside another store path — all of it would land in the image. Re-add the file by content with `builtins.path`.";
    }) (lib.filterAttrs (name: _: lib.hasPrefix "nixhold/keys/" name) config.environment.etc)
    ++ [
      # The image's whole job is to reach the fleet repo, and the only
      # thing standing between it and the clone key is the operator's
      # own age route. Neither route committed means an image that
      # boots, prompts, and can decrypt nothing.
      {
        assertion = hasTokenRecipient || hasWrappedIdentity;
        message = "nixhold installer ISO: the fleet commits no operator route — `nixhold.layout.ageRecipient` has no `age1fido2-hmac1…` (hardware token) line and `nixhold.layout.ageIdentityWrapped` is null (no committed passphrase-wrapped identity at `keys/operator.age`). The booted image could not decrypt the fleet's own SSH key, so it could not clone. Enroll a token or commit a wrapped identity.";
      }
    ];

  # `environment.variables` (not `sessionVariables`) — these have to
  # reach the autologin root console shell, which reads /etc/profile.
  # The CLI's own resolution honours a pre-set value, so an operator
  # who exports something else still wins.
  environment.variables = {
    NIXHOLD_REPO_URL = repoUrl;
    NIXHOLD_CLONE_KEY_FILE = "/etc/nixhold/keys/identity.age";
    NIXHOLD_FLEET_DEFAULT = "/root/${repoBasename}";
  }
  # Only when there is a file to point at. Exporting the path of a
  # ciphertext the image does not carry would make every verb fail on
  # a missing identity instead of falling through to the token.
  // lib.optionalAttrs hasWrappedIdentity {
    NIXHOLD_IDENTITY_FILE = "/etc/nixhold/keys/operator.age";
  };

  # The clone is the first thing `host install` does, on a machine
  # with no known_hosts and no operator at the keyboard to confirm a
  # fingerprint. github.com's published host keys ship with the image,
  # so the clone key meets a host it already trusts. Same value the
  # baselines pin on every installed machine.
  programs.ssh.knownHosts = import ./github-known-hosts.nix;

  # A FIDO2 token is a route the image must be able to *use*, not
  # just name: age dispatches `age1fido2-hmac1…` recipients to the
  # plugin binary by name, and the plugin talks to the token through
  # libfido2 — which needs its udev rules for the hidraw node to be
  # reachable by the (root) console session at all.
  services.udev.packages = [ pkgs.libfido2 ];

  # Tool belt, no `gh`: the fleet's own ssh key is the git-host
  # credential, so the ISO never authenticates against an API.
  environment.systemPackages = [
    (import ../cli { inherit pkgs; })
    diskoPackage
    pkgs.git
    pkgs.gum
    pkgs.age
    pkgs.age-plugin-fido2-hmac
    pkgs.libfido2
    pkgs.jq
    pkgs.nixos-facter
  ];

  # The CLI shells out to `nix eval`/`nix build` for every phase.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
