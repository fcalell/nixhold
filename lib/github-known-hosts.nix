# github.com's published SSH host keys, as `programs.ssh.knownHosts`
# entries.
#
# One value, three consumers: both baselines (so every fleet machine's
# `git fetch`/`push` over SSH meets a host it already trusts, instead
# of accepting whatever answers on the first clone) and the installer
# ISO, whose very first act — cloning the fleet over the deploy key —
# happens on a machine with no known_hosts and nobody at the keyboard
# to compare a fingerprint.
#
# Three entries because github serves three key types and which one a
# client negotiates depends on its HostKeyAlgorithms; pinning only the
# ed25519 one turns an RSA-preferring client back into
# trust-on-first-use. Published at
# https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# — if github rotates one, this file is the single place to update.
{
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
}
