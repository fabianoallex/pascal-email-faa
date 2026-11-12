#!/bin/sh
# Everything CI runs (.github/workflows/ci.yml), also runnable locally with
# Docker, on Linux FPC 3.2.2: the test kit check, the unit suite (core, mock,
# file sender, SMTP against a scripted server), then the integration suite
# (SMTP against Mailpit v1.33.1 in Docker: STARTTLS, implicit TLS and plain,
# with a private CA). Delphi Community Edition can't build headless, so the
# Delphi side is still validated in the IDE (see CLAUDE.md, "Tests").
#
# FPC image: built here from Debian bookworm's fpc package (3.2.2) and tagged
# pascalemail-fpc322, unless FPC_IMAGE names an existing one.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "${FPC_IMAGE:-}" ]; then
  FPC_IMAGE=pascalemail-fpc322
  docker build -q -t "$FPC_IMAGE" - <<'DOCKERFILE' >/dev/null
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends fpc libssl3 ca-certificates && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi
export FPC_IMAGE

echo "== test kit"
python tools/gen_fpc_mirror.py --check
echo "== unit suite"
sh tools/test_fpc_docker.sh
echo "== integration suite (Mailpit)"
sh tools/test_integration_docker.sh
