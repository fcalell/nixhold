# `nixhold.repositories` — the operator's git checkouts as fleet data.
#
# One declaration ("I work on this repo") produces everything a
# checkout needs on every host: a fleet-scoped env secret named after
# it, the ssh client wiring that reaches its forge with the fleet's
# outbound key (`identity`, or `identity-<type>` for a forge that
# cannot take ed25519 — declared here the moment a repository names
# it), a direnv library that exports that env inside the checkout,
# and a clone at activation if the directory is not there yet. Nothing here is per-host: a repository is declared once for the
# fleet and every host that evaluates this module carries it.
#
# The fleet repo itself is declared nowhere — `layout.repoUrl` names
# it and the CLI clones it — but its forge takes the same key, so it
# joins the forge list below: every fleet host reaches the fleet repo
# as the fleet, repositories declared or not.
#
# Both baselines import this; the wiring is home-manager, so it is the
# same on NixOS and darwin.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;

  username = config.nixhold.identity.username;
  repos = config.nixhold.repositories;
  secrets = config.nixhold.secrets;

  # The fleet's outbound key of one algorithm: `identity` is ed25519
  # (modules/home/common.nix declares it); any other algorithm is a
  # second framework key named after it, declared below the first
  # time a repository asks for it.
  keySecretName = type: if type == "ed25519" then "identity" else "identity-${type}";
  overrideTypes = lib.unique (
    lib.filter (t: t != "ed25519") (lib.mapAttrsToList (_: r: r.key) repos)
  );

  # The forge a URL reaches over ssh, or null when it does not use
  # ssh at all. Two shapes carry a host:
  #   scp-like   git@github.com:owner/repo.git
  #   ssh:// URL ssh://git@github.com:22/owner/repo.git
  # An https (or any other scheme) URL authenticates over HTTPS and
  # gets no ssh matchBlock. Deliberately no `User`: the URL already
  # carries it, and one forge host can legitimately have several
  # (AWS CodeCommit gives every operator their own).
  forgeHost =
    url:
    let
      scheme = builtins.match "([A-Za-z][A-Za-z0-9+.-]*)://(.*)" url;
      sshUrl = builtins.match "ssh://(([^@/]+)@)?([^/:]+)(:[0-9]+)?(/.*)?" url;
      scpLike = builtins.match "(([^@/:]+)@)?([^/:]+):(.*)" url;
    in
    if scheme != null then
      (if sshUrl == null then null else builtins.elemAt sshUrl 2)
    else if scpLike != null then
      builtins.elemAt scpLike 2
    else
      null;

  # Every forge reached over ssh, with the repositories reaching it
  # and the key each names. The fleet repo's forge is github.com by
  # `layout.repoUrl`'s contract (a bare slug, github.com assumed —
  # modules/layout), on the identity key.
  forges = lib.groupBy (e: e.host) (
    lib.filter (e: e.host != null) (
      lib.mapAttrsToList (name: r: {
        inherit name;
        host = forgeHost r.url;
        key = r.key;
      }) repos
    )
    ++ lib.optional (config.nixhold.layout.repoUrl != null) {
      name = "the fleet repo (layout.repoUrl)";
      host = "github.com";
      key = "ed25519";
    }
  );
  # The one key a forge's block names; the assertion below makes
  # every entry of a host agree, so the head is the answer.
  forgeSecret = entries: secrets.${keySecretName (lib.head entries).key};

  expandHome = import ../../lib/expand-home.nix;
  repositoriesPath = config.nixhold.home.repositoriesPath;

  repoSubmodule = types.submodule (
    { name, ... }:
    {
      options = {
        url = mkOption {
          type = types.str;
          description = ''
            Clone URL. An ssh URL (scp-like `git@host:owner/repo.git`
            or `ssh://git@host/owner/repo.git`) additionally wires the
            fleet's outbound key (`key`) as the `IdentityFile` for
            that forge; an https URL is cloned as-is.
          '';
          example = "git@github.com:alice/notes.git";
        };

        key = mkOption {
          type = config.nixhold.types.sshKeyType;
          default = "ed25519";
          description = ''
            Algorithm of the outbound key the forge takes. `ed25519`
            is the fleet's `identity`. `rsa` is for a forge that
            cannot take ed25519 (AWS CodeCommit): it names the
            fleet's second outbound key, the framework secret
            `identity-rsa`, declared and minted the moment a
            repository asks for it and registered on that forge
            like `identity` is on every other. Every repository on
            one forge host names the same key.
          '';
        };

        path = mkOption {
          type = types.str;
          defaultText = lib.literalMD "`<nixhold.home.repositoriesPath>/<name>`";
          description = ''
            Where the checkout lives. A leading `~` is the operator's
            home. Set it only for a repository that does not belong
            beside the others.
          '';
          example = "~/work/monorepo";
        };
      };

      config.path = lib.mkDefault "${repositoriesPath}/${name}";
    }
  );
in
{
  options.nixhold.repositories = mkOption {
    type = types.attrsOf (types.coercedTo types.str (url: { inherit url; }) repoSubmodule);
    default = { };
    description = ''
      The operator's git checkouts. A bare string is the URL
      (`{ notes = "git@github.com:alice/notes.git"; }`); the attrset
      form adds `path` and `key`. The attribute name is the repository's name
      throughout: the directory under
      `nixhold.home.repositoriesDir`, and the
      `nixhold.secrets.<name>` holding its env file — one fleet-wide
      ciphertext of KEY=value lines that direnv exports inside the
      checkout, `required = false`, so a repository declared without
      an env file is simply cloned.
    '';
    example = lib.literalExpression ''
      {
        notes = "git@github.com:alice/notes.git";
        monorepo = {
          url = "git@github.com:acme/monorepo.git";
          path = "~/work/monorepo";
        };
        legacy = {
          url = "ssh://APKAEXAMPLE@git-codecommit.eu-central-1.amazonaws.com/v1/repos/legacy";
          key = "rsa";
        };
      }
    '';
  };

  config = lib.mkMerge [
    {
      # One secret per repository, named after it, fleet-scoped: the
      # env of a repository is a property of the repository, not of
      # the machine the checkout happens to sit on.
      nixhold.secrets = lib.mapAttrs (name: r: {
        scope = lib.mkDefault "fleet";
        required = lib.mkDefault false;
        category = lib.mkDefault "repository";
        owner = lib.mkDefault "user";
        description = lib.mkDefault "env (KEY=value lines) for repository ${name} (${r.url})";
        template = lib.mkDefault ''
          # KEY=value, one per line. Exported by direnv inside the checkout.
        '';
      }) repos;

      # A repository's secret is the repository's; a service (or the
      # framework) that already owns that name would otherwise have
      # its declaration quietly merged with this one.
      assertions =
        lib.mapAttrsToList (name: _: {
          assertion = config.nixhold.secrets.${name}.category == "repository";
          message = ''
            nixhold.repositories.${name}: a secret named "${name}" is
            already declared by something else (category
            "${config.nixhold.secrets.${name}.category}"). Rename the
            repository entry, or the other declaration.
          '';
        }) repos
        # The ssh block is per forge host and names one key.
        ++ lib.mapAttrsToList (host: entries: {
          assertion = lib.length (lib.unique (map (e: e.key) entries)) == 1;
          message = ''
            nixhold.repositories: the forge ${host} is reached with
            more than one key (${
              lib.concatMapStringsSep ", " (e: "${e.name}: ${e.key}") entries
            }). The ssh block is per forge host, so every repository
            on it must name the same `key`.
          '';
        }) forges;
    }

    {
      # The fleet's second outbound key, one per algorithm a
      # repository names besides identity's ed25519. Fleet-scoped and
      # framework-owned like `identity` (modules/home/common.nix):
      # registered on its forge once, revoked with the fleet. Not
      # required: minted by `nixhold secret edit`, which prints the
      # pubkey to register.
      nixhold.secrets = lib.listToAttrs (
        map (type: {
          name = keySecretName type;
          value = {
            sshKey = true;
            sshKeyType = type;
            scope = lib.mkDefault "fleet";
            required = lib.mkDefault false;
            category = lib.mkDefault "framework";
            owner = lib.mkDefault "user";
            description = lib.mkDefault "the fleet's outbound ${type} SSH key, for forges that cannot take identity's ed25519";
          };
        }) overrideTypes
      );
    }

    {
      home-manager.users.${username} =
        hmArgs:
        let
          # Only an operator-set `path` still carries a `~`; the
          # default arrives absolute from `repositoriesPath`.
          expand = expandHome hmArgs.config.home.homeDirectory;

          direnvEnabled = hmArgs.config.programs.direnv.enable;

          # Only a provisioned secret has a decrypted path to point
          # at; a repository whose env has never been written is
          # cloned and left alone.
          envEntries = lib.mapAttrsToList (name: r: {
            dir = expand r.path;
            env = hmArgs.osConfig.age.secrets.${name}.path;
          }) (lib.filterAttrs (name: _: config.nixhold.secrets.${name}.active) repos);

          # Longest path first: a checkout nested inside another one
          # must win over its parent.
          sortedEntries = lib.sort (
            a: b: builtins.stringLength a.dir > builtins.stringLength b.dir
          ) envEntries;

          direnvLib = ''
            # Managed by nixhold — do not edit.
            #
            # direnv sources every file in this directory before it
            # evaluates the .envrc of the directory being loaded. For
            # a checkout nixhold declares, that repository's decrypted
            # env file is exported here, so the .envrc itself stays
            # empty (and the repo stays free of fleet knowledge).
            _nixhold_repo_env() {
              local repo env
              while [ "$#" -gt 1 ]; do
                repo="$1"
                env="$2"
                shift 2
                case "$PWD/" in
                  "$repo"/*)
                    dotenv_if_exists "$env"
                    return 0
                    ;;
                esac
              done
            }
            _nixhold_repo_env ${
              lib.escapeShellArgs (
                lib.concatMap (e: [
                  e.dir
                  e.env
                ]) sortedEntries
              )
            }
          '';

          cloneActivation =
            name: r:
            let
              dir = expand r.path;
              # Only an ssh URL needs the key; an https clone must not
              # be skipped waiting for one.
              needsKey = forgeHost r.url != null;
              keySecret = secrets.${keySecretName r.key};
            in
            hmArgs.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
              repo=${lib.escapeShellArg dir}
              clone=1
              ${lib.optionalString needsKey ''
                if [ ! -r "$HOME/${keySecret.homePath}" ]; then
                  clone=0
                  warnEcho "nixhold: ${name} not cloned — ~/${keySecret.homePath} is not readable yet (agenix decrypts asynchronously on darwin, and a key nobody has minted is not there at all; re-run activation once it is there)"
                fi
              ''}
              if [ ! -e "$repo" ] && [ "$clone" = 1 ]; then
                run ${pkgs.git}/bin/git clone ${lib.escapeShellArg r.url} "$repo" \
                  || warnEcho "nixhold: cloning ${name} failed — the next activation retries"
              fi

              # An .envrc is what makes direnv load at all; nixhold
              # only ever creates a missing one, never touches the
              # repository's own, and never pulls.
              if [ -d "$repo" ] && [ ! -e "$repo/.envrc" ]; then
                echo '# managed by nixhold: repository env is loaded by ~/.config/direnv/lib/nixhold.sh' > "$repo/.envrc"
                if [ -d "$repo/.git" ]; then
                  mkdir -p "$repo/.git/info"
                  if ! ${pkgs.gnugrep}/bin/grep -qxF '.envrc' "$repo/.git/info/exclude" 2>/dev/null; then
                    echo '.envrc' >> "$repo/.git/info/exclude"
                  fi
                fi
                ${lib.optionalString direnvEnabled ''
                  run ${pkgs.direnv}/bin/direnv allow "$repo" \
                    || warnEcho "nixhold: direnv allow failed for ${name}"
                ''}
              fi
            '';
        in
        {
          # One matchBlock per distinct forge host, not per
          # repository: several repositories on one forge share the
          # ssh config, and the URL — not this block — carries the
          # user. mkDefault so an operator's own block wins.
          #
          # Unconditional in the key: a forge authenticates the
          # fleet's OUTBOUND key of the algorithm it takes, a
          # framework secret every host holds and that forge has
          # registered. How the operator logs in to their own hosts
          # (`keys/login.pub`, typically a hardware token) is a
          # different key on a different journey, and does not reach
          # a forge. A block waits for its key to be provisioned:
          # naming a file that never lands would pin ssh to nothing.

          programs.ssh.settings = lib.concatMapAttrs (
            host: entries:
            let
              secret = forgeSecret entries;
            in
            lib.optionalAttrs secret.active {
              ${host} = {
                IdentityFile = lib.mkDefault "~/${secret.homePath}";
                IdentitiesOnly = lib.mkDefault true;
              };
            }
          ) forges;

          # Never enables direnv — it wires into the one the operator
          # already runs.
          xdg.configFile."direnv/lib/nixhold.sh" = lib.mkIf direnvEnabled { text = direnvLib; };

          home.activation = lib.mapAttrs' (name: r: {
            name = "nixhold-repo-${name}";
            value = cloneActivation name r;
          }) repos;
        };
    }
  ];
}
