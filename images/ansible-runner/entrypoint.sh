#!/bin/sh
# HOME env alone isn't enough. OpenSSH's own client deliberately does not
# trust $HOME from the environment when resolving its default known_hosts/
# config paths — it calls getpwuid() on the real UID instead, precisely so a
# malicious environment can't redirect it to attacker-controlled files. An
# arbitrary UID passed via `docker run --user "$(id -u):$(id -g)"` (the
# Makefile's whoever-invoked-make pattern) either has no /etc/passwd entry at
# all, or — on Podman specifically — one Podman synthesized itself for a UID
# it recognises from its own host/VM (observed: UID 501 as "core", HOME set
# to the container's WORKDIR). Either way getpwuid() disagrees with $HOME,
# and ssh silently resolves known_hosts against the wrong directory —
# "Host key verification failed" even though the file is exactly where the
# Makefile mounted it.
#
# Not "add an entry if one is missing" — Podman's own entry already exists,
# so that check is a no-op. Replace whatever entry is there for this UID
# outright. /etc/passwd is world-writable (Dockerfile) for exactly this;
# `>` here only needs write on the file itself, not the containing
# directory, so it works regardless of directory-level permissions.
set -eu

uid="$(id -u)"
gid="$(id -g)"

{ grep -v ":${uid}:" /etc/passwd 2>/dev/null || true
  echo "ansible:x:${uid}:${gid}::${HOME}:/usr/sbin/nologin"
} > /tmp/passwd.new
cat /tmp/passwd.new > /etc/passwd
rm -f /tmp/passwd.new

exec "$@"
