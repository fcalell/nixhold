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
# "Thin" is a property of how the ciphertexts are baked, not just of
# what is named here: `mkFleet` hands over paths *inside the fleet
# checkout*, and a path coerced straight into `environment.etc`
# carries its whole store path — the entire checkout (hosts,
# ciphertexts, escrows) — into the squashfs. `builtins.path` re-adds
# each file as a store path of its own, by content, so the closure
# holds the two files and nothing around them.
#
# The CLI finds both through the environment (see `NIXHOLD_*` below):
# `$NIXHOLD_IDENTITY_FILE` is the wrapped operator identity every
# verb unwraps, `$NIXHOLD_REPO_KEY_FILE` the deploy key
# `nh_repo_git` clones and pushes the fleet repo with.
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
  # emits `installerIso` once both files exist, so there is no
  # existence check to make here.
  bake = name: path: {
    source = builtins.path {
      inherit path;
      inherit name;
    };
    mode = "0400";
  };

  keysEtc = {
    "nixhold/keys/operator.age" = bake "nixhold-operator.age" ageIdentityWrapped;
    "nixhold/keys/repo.key.age" = bake "nixhold-repo.key.age" repoDeployKey;
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

  # THIN by contract, asserted instead of merely stated: every file
  # this image bakes under /etc/nixhold/keys must be a store path of
  # its own. A path taken straight out of the fleet checkout is a
  # store *sub*path, and carrying one here puts the whole checkout —
  # every host, ciphertext and escrow — into the squashfs. The check
  # is on the merged config, so it also holds for entries a fleet
  # adds itself.
  assertions = lib.mapAttrsToList (name: entry: {
    assertion = builtins.dirOf (toString entry.source) == builtins.storeDir;
    message = "nixhold installer ISO: /etc/${name} is baked from ${toString entry.source}, which lives inside another store path — all of it would land in the image. Re-add the file by content with `builtins.path`.";
  }) (lib.filterAttrs (name: _: lib.hasPrefix "nixhold/keys/" name) config.environment.etc);

  # `environment.variables` (not `sessionVariables`) — these have to
  # reach the autologin root console shell, which reads /etc/profile.
  # The CLI's own resolution honours a pre-set value, so an operator
  # who exports something else still wins.
  environment.variables = {
    NIXHOLD_REPO_URL = repoUrl;
    NIXHOLD_IDENTITY_FILE = "/etc/nixhold/keys/operator.age";
    NIXHOLD_REPO_KEY_FILE = "/etc/nixhold/keys/repo.key.age";
    NIXHOLD_FLEET_DEFAULT = "/root/${repoBasename}";
  };

  # The clone is the first thing `host install` does, on a machine
  # with no known_hosts and no operator at the keyboard to confirm a
  # fingerprint. github.com's published host keys ship with the image,
  # so the deploy key meets a host it already trusts.
  programs.ssh.knownHosts = {
    "github.com-ed25519" = {
      hostNames = [ "github.com" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };
    "github.com-ecdsa" = {
      hostNames = [ "github.com" ];
      publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
    };
    "github.com-rsa" = {
      hostNames = [ "github.com" ];
      publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=";
    };
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
