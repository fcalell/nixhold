# Fixture coverage for the operator-facing half of the secrets
# redesign: framework-declared secrets (`identity`, `env`), fleet
# scope, and everything one `nixhold.repositories` entry produces
# (env secret, forge ssh matchBlock, direnv library).
#
# Imported by fixture-server and fixture-mac, so the same
# expectations are checked on both platforms — the wiring is
# home-manager and the delivery of `env` is a platform half, and a
# drift between them would otherwise only show up on a real Mac.
{ config, lib, ... }:
let
  hm = config.home-manager.users.${config.nixhold.identity.username};
  secrets = config.nixhold.secrets;
  direnvLib = hm.xdg.configFile."direnv/lib/nixhold.sh".text or "";
  sshBlocks = hm.programs.ssh.settings;

  fleet = config.nixhold.fleet;
  # `settings` also carries HM's own `"*"` block and the forge blocks;
  # only fleet peers take the login posture.
  peerBlocks = lib.filterAttrs (name: _: lib.hasAttr name fleet.hosts) sshBlocks;
  # Read independently of the modules under test, exactly as
  # ./known-hosts-assertions.nix does.
  lines =
    f: lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (lib.splitString "\n" (builtins.readFile f));
  committedRecipients = lines ./keys/operator.pub;
  committedLoginKeys = lines ./keys/login.pub;
  committedFleetPub = lib.removeSuffix "\n" (builtins.readFile ./keys/fleet.pub);
in
{
  # Five repositories, chosen for what they distinguish:
  #   notes/scratch  two repos on ONE forge host → one matchBlock
  #   infra          ssh:// form on another forge → its own block
  #   docs           https + explicit path → no matchBlock at all
  #   legacy         key = "rsa" → declares identity-rsa; its forge
  #                  block waits for that key to be provisioned
  # Only `notes` has a committed ciphertext, so the direnv library
  # must carry exactly one entry.
  nixhold.repositories = {
    notes = "git@github.com:fixture/notes.git";
    scratch = "git@github.com:fixture/scratch.git";
    infra = "ssh://git@git.fixture.invalid/fixture/infra.git";
    docs = {
      url = "https://example.invalid/fixture/docs.git";
      path = "~/work/docs";
    };
    legacy = {
      url = "ssh://APKAFIXTURE@git-codecommit.fixture.invalid/v1/repos/legacy";
      key = "rsa";
    };
  };

  # direnv is never enabled by the framework; the library is emitted
  # only for an operator who already runs it. git likewise — it is
  # what gates the identity-key signing defaults.
  nixhold.home.extraModules = [
    {
      programs.direnv.enable = true;
      programs.git.enable = true;
    }
  ];

  assertions = [
    # --- framework-declared secrets ---
    {
      assertion = secrets.identity.sshKey && secrets.identity.category == "framework";
      message = "fixture: the framework must declare `identity` as a framework-category sshKey secret";
    }
    {
      assertion = secrets.identity.scope == "fleet";
      message = "fixture: identity is fleet-scoped — one key for every host";
    }
    {
      assertion = lib.hasSuffix "/secrets/identity.age" (toString secrets.identity.sourceFile);
      message = "fixture: identity's ciphertext is ${toString secrets.identity.sourceFile}, not secrets/identity.age";
    }
    {
      assertion = secrets.identity.homePath == ".ssh/identity";
      message = "fixture: the identity secret must land at ~/.ssh/identity";
    }
    {
      assertion =
        secrets.identity.sshKeyType == "ed25519" && lib.hasInfix "-t ed25519" secrets.identity.generator;
      message = "fixture: identity is minted as ed25519";
    }

    # --- the second outbound key, declared by `key = "rsa"` ---
    {
      assertion =
        secrets ? identity-rsa
        && secrets.identity-rsa.sshKey
        && secrets.identity-rsa.sshKeyType == "rsa"
        && secrets.identity-rsa.scope == "fleet"
        && secrets.identity-rsa.category == "framework"
        && !secrets.identity-rsa.required
        && secrets.identity-rsa.homePath == ".ssh/identity-rsa";
      message = "fixture: a repository with key = \"rsa\" must declare the fleet-scoped framework sshKey secret identity-rsa at ~/.ssh/identity-rsa";
    }
    {
      assertion = lib.hasInfix "-t rsa -b 4096" secrets.identity-rsa.generator;
      message = "fixture: identity-rsa's generator must mint rsa-4096, got: ${secrets.identity-rsa.generator}";
    }
    {
      # No ciphertext is committed for it, so it is inactive and the
      # forge that needs it gets no block yet: naming a file that
      # never lands would pin ssh to nothing.
      assertion = !secrets.identity-rsa.active && !(sshBlocks ? "git-codecommit.fixture.invalid");
      message = "fixture: an unprovisioned identity-rsa must not produce a forge block (got ${builtins.toJSON (lib.attrNames sshBlocks)})";
    }
    {
      assertion = hm.home.activation ? nixhold-repo-legacy;
      message = "fixture: no clone activation step was emitted for the legacy repository";
    }
    {
      assertion = secrets.env.scope == "fleet" && secrets.env.category == "framework";
      message = "fixture: `env` must be a fleet-scoped framework secret";
    }
    {
      assertion = lib.hasSuffix "/secrets/env.age" (toString secrets.env.sourceFile);
      message = "fixture: fleet scope must resolve to secrets/<name>.age, got ${toString secrets.env.sourceFile}";
    }
    {
      # The committed secrets/env.age makes it active, so the shell
      # init must actually source the decrypted path.
      assertion = lib.hasInfix config.age.secrets.env.path config.environment.extraInit;
      message = "fixture: the global env secret is active but no shell init sources it";
    }

    # --- repository secrets ---
    {
      assertion = secrets.notes.scope == "fleet" && secrets.notes.category == "repository";
      message = "fixture: a repository's env secret is fleet-scoped and category = repository";
    }
    {
      assertion = secrets.notes.active && !secrets.docs.active;
      message = "fixture: only the repository with a committed ciphertext (notes) may be active";
    }

    # --- forge ssh matchBlocks ---
    {
      assertion = sshBlocks ? "github.com" && sshBlocks ? "git.fixture.invalid";
      message = "fixture: one ssh matchBlock per forge host is missing (got ${builtins.toJSON (lib.attrNames sshBlocks)})";
    }
    {
      assertion = !(sshBlocks ? "example.invalid");
      message = "fixture: an https repository URL must not produce an ssh matchBlock";
    }
    {
      assertion =
        sshBlocks."github.com".data.IdentityFile or null == "~/.ssh/identity"
        && sshBlocks."github.com".data.IdentitiesOnly or null == true
        # The URL carries the forge user; the block must not.
        && !(sshBlocks."github.com".data ? User);
      message = "fixture: the github.com matchBlock does not pin the identity key (or wrongly sets User)";
    }

    # --- direnv library ---
    {
      assertion =
        lib.hasInfix "${hm.home.homeDirectory}/projects/notes" direnvLib
        && lib.hasInfix config.age.secrets.notes.path direnvLib;
      message = "fixture: the direnv library does not export the notes repository env";
    }
    {
      assertion = !(lib.hasInfix "work/docs" direnvLib);
      message = "fixture: a repository with no provisioned env must not appear in the direnv library";
    }
    {
      assertion = hm.home.activation ? nixhold-repo-notes;
      message = "fixture: no clone activation step was emitted for the notes repository";
    }

    # --- operator login keys: one file, verbatim ---
    {
      # `keys/login.pub` is the only login mechanism: every line of
      # it, and nothing else, is authorized on every host.
      assertion = fleet.derived.operatorAuthorizedKeys == committedLoginKeys;
      message = "fixture: derived.operatorAuthorizedKeys must be exactly the lines of keys/login.pub, got ${builtins.toJSON fleet.derived.operatorAuthorizedKeys}";
    }
    {
      # Both postures in one file: the token halves the fleet does not
      # hold, and the fleet's own key for a fleet that carries no
      # token.
      assertion =
        builtins.length committedLoginKeys == 3
        && builtins.length (lib.filter (lib.hasPrefix "sk-ssh-ed25519@") committedLoginKeys) == 2;
      message = "fixture: keys/login.pub must carry the two token pubkeys plus the fleet identity's, got ${builtins.toJSON committedLoginKeys}";
    }
    {
      assertion = peerBlocks != { };
      message = "fixture: no fleet-peer ssh matchBlock was emitted — the IdentityFile check below is vacuous";
    }
    {
      # A fleet peer gets the fleet's own key NAMED (it is what a
      # no-token fleet authorizes) but never `IdentitiesOnly` — the
      # operator's token keys have no file to name and are offered by
      # the agent, so excluding them is how a token fleet locks itself
      # out. Forge blocks keep both (asserted above): a forge
      # authenticates the outbound key alone.
      assertion = lib.all (
        b: b.data.IdentityFile or null == "~/.ssh/identity" && !(b.data ? IdentitiesOnly)
      ) (lib.attrValues peerBlocks);
      message = "fixture: fleet-peer ssh blocks must name the identity key and set no IdentitiesOnly (got ${builtins.toJSON (lib.attrNames peerBlocks)})";
    }

    # --- recipients: operator routes + the one fleet key ---
    {
      # keys/operator.pub is a LIST — a token line and the wrapped
      # identity's line — and every line must be a recipient of
      # every secret.
      assertion =
        builtins.length committedRecipients == 2
        && lib.all (r: lib.elem r secrets.identity.recipients) committedRecipients;
      message = "fixture: every line of keys/operator.pub must be an operator recipient, got ${builtins.toJSON secrets.identity.recipients}";
    }
    {
      assertion = lib.any (lib.hasPrefix "age1fido2-hmac1") secrets.identity.recipients;
      message = "fixture: the hardware-token recipient line was dropped from the recipient set";
    }
    {
      # The whole recipient set, exactly: the operator's routes plus
      # the ONE fleet key. No host pubkey, nothing per-host — which is
      # what makes host add/remove rekey nothing.
      assertion = secrets.identity.recipients == committedRecipients ++ [ committedFleetPub ];
      message = "fixture: recipients must be the operator lines plus keys/fleet.pub and nothing else, got ${builtins.toJSON secrets.identity.recipients}";
    }
    {
      # Every secret on this host takes that same set, whatever its
      # scope or category.
      assertion = lib.all (s: s.recipients == secrets.identity.recipients) (lib.attrValues secrets);
      message = "fixture: a secret's recipient set differs from the fleet's — no recipient set may vary per secret";
    }
    {
      # The one decryption identity every host holds, both platforms.
      assertion = config.age.identityPaths == [ "/etc/nixhold/fleet.key" ];
      message = "fixture: age.identityPaths must be the fleet key, got ${builtins.toJSON config.age.identityPaths}";
    }
    {
      # Both routes committed here, so the wrapped identity resolves
      # to the file beside the fixture rather than to null.
      assertion = lib.hasSuffix "/keys/operator.age" (toString config.nixhold.layout.ageIdentityWrapped);
      message = "fixture: layout.ageIdentityWrapped did not default to the committed keys/operator.age, got ${toString config.nixhold.layout.ageIdentityWrapped}";
    }

    # --- git signing off the identity key, opt-in ---
    {
      assertion =
        hm.programs.git.signing.format == "ssh" && hm.programs.git.signing.key == "~/.ssh/identity.pub";
      message = "fixture: git commit signing is not wired to the identity key";
    }
    {
      # signByDefault would gate every commit on a `.pub` that only a
      # deploy writes, so the framework names the key and stops there.
      assertion = hm.programs.git.signing.signByDefault != true;
      message = "fixture: git signing is on by default; it must be opt-in";
    }
  ];
}
