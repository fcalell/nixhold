# `nixhold.repositories` — the operator's git checkouts as fleet data.
#
# One declaration ("I work on this repo") produces everything a
# checkout needs on every host: a fleet-scoped env secret named after
# it, the ssh client wiring that reaches its forge with the host's
# `identity` key, a direnv library that exports that env inside the
# checkout, and a clone at activation if the directory is not there
# yet. Nothing here is per-host: a repository is declared once for the
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
  identitySecret = config.nixhold.secrets.identity;

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

  # The fleet repo's forge is github.com by `layout.repoUrl`'s
  # contract (a bare slug, github.com assumed — modules/layout).
  forgeHosts = lib.unique (
    lib.filter (h: h != null) (lib.mapAttrsToList (_: r: forgeHost r.url) repos)
    ++ lib.optional (config.nixhold.layout.repoUrl != null) "github.com"
  );

  # `~/.ssh/identity`, as ssh and the activation script spell it.
  identityFile = "~/${identitySecret.homePath}";

  repositoriesDir = config.nixhold.home.repositoriesDir;

  repoSubmodule = types.submodule (
    { name, ... }:
    {
      options = {
        url = mkOption {
          type = types.str;
          description = ''
            Clone URL. An ssh URL (scp-like `git@host:owner/repo.git`
            or `ssh://git@host/owner/repo.git`) additionally wires the
            host's `identity` key as the `IdentityFile` for that
            forge; an https URL is cloned as-is.
          '';
          example = "git@github.com:alice/notes.git";
        };

        path = mkOption {
          type = types.str;
          defaultText = lib.literalMD "`<nixhold.home.repositoriesDir>/<name>`";
          description = ''
            Where the checkout lives. A leading `~` is the operator's
            home. Set it only for a repository that does not belong
            beside the others.
          '';
          example = "~/work/monorepo";
        };
      };

      config.path = lib.mkDefault "${repositoriesDir}/${name}";
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
      form adds `path`. The attribute name is the repository's name
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
      assertions = lib.mapAttrsToList (name: _: {
        assertion = config.nixhold.secrets.${name}.category == "repository";
        message = ''
          nixhold.repositories.${name}: a secret named "${name}" is
          already declared by something else (category
          "${config.nixhold.secrets.${name}.category}"). Rename the
          repository entry, or the other declaration.
        '';
      }) repos;
    }

    {
      home-manager.users.${username} =
        hmArgs:
        let
          home = hmArgs.config.home.homeDirectory;
          expand =
            p:
            if p == "~" then
              home
            else if lib.hasPrefix "~/" p then
              home + lib.removePrefix "~" p
            else
              p;

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
            in
            hmArgs.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
              repo=${lib.escapeShellArg dir}
              clone=1
              ${lib.optionalString needsKey ''
                if [ ! -r "$HOME/${identitySecret.homePath}" ]; then
                  clone=0
                  warnEcho "nixhold: ${name} not cloned — ${identityFile} is not readable yet (agenix decrypts asynchronously on darwin; re-run activation once it is there)"
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
          # fleet's OUTBOUND key, the `identity` secret every host
          # holds and every forge has registered. How the operator
          # logs in to their own hosts (`keys/login.pub`, typically a
          # hardware token) is a different key on a different
          # journey, and does not reach github.

          programs.ssh.settings = lib.optionalAttrs identitySecret.active (
            lib.genAttrs forgeHosts (_: {
              IdentityFile = lib.mkDefault identityFile;
              IdentitiesOnly = lib.mkDefault true;
            })
          );

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
