#!/bin/sh
# Builds and runs the integration suite on Linux FPC 3.2.2 inside Docker,
# with heaptrc, against the Mailpit servers of tools/mailpit.sh (started
# here and removed at the end). Acceptance criterion: 0 errors, 0 failures,
# 0 unfreed blocks.
#
# The runner joins Mailpit's network and reaches the servers by name; the
# TLS tests use the private CA in .ci/it-certs, through OpenSSL 3 (Debian
# 12's libssl3, loaded by pascal-common-faa without libssl-dev).
#
# FPC_IMAGE: any image with FPC 3.2.2 and libssl3 (default: fpc322-bookworm;
# tools/ci-test.sh builds one when it is missing). KEEP_MAILPIT=1 leaves the
# servers running.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-fpc322-bookworm}"
cd "$ROOT"
[ -f external/pascal-common-faa/src/PascalCommon.Http.pas ] \
  || { echo "external/pascal-common-faa is empty: git submodule update --init"; exit 1; }
COMMON="$(cd external/pascal-common-faa && pwd -P)"
MOUNT="$ROOT"
if command -v cygpath >/dev/null 2>&1; then
  MOUNT="$(cygpath -w "$ROOT")"
  COMMON="$(cygpath -w "$COMMON")"
fi
python tools/gen_fpc_mirror.py --check

[ "${KEEP_MAILPIT:-}" = 1 ] || trap 'sh "$ROOT/tools/mailpit.sh" down' EXIT
sh tools/mailpit.sh up

MSYS_NO_PATHCONV=1 docker run --rm --network pascalemail-it-net -v "$MOUNT:/src:ro" \
  -v "$COMMON:/common:ro" \
  -e EMAIL_IT_STARTTLS_HOST=mailpit-starttls -e EMAIL_IT_STARTTLS_PORT=1025 \
  -e EMAIL_IT_STARTTLS_API=http://mailpit-starttls:8025 \
  -e EMAIL_IT_TLS_HOST=mailpit-tls -e EMAIL_IT_TLS_PORT=1025 \
  -e EMAIL_IT_TLS_API=http://mailpit-tls:8025 \
  -e EMAIL_IT_TLS_WRONG_HOST=mailpit-tls-other \
  -e EMAIL_IT_PLAIN_HOST=mailpit-plain -e EMAIL_IT_PLAIN_PORT=1025 \
  -e EMAIL_IT_PLAIN_API=http://mailpit-plain:8025 \
  -e EMAIL_IT_CA_FILE=/t/.ci/it-certs/ca.pem \
  "$IMAGE" sh -c '
  set -e
  mkdir -p /t/u /t/.ci && cp -r /src/src /src/adapters /src/tests /t/ && cp -r /src/.ci/it-certs /t/.ci/
  C=/common/src
  cd /t/tests/Integration/fpc
  fpc -v0 -Mdelphi -Fu/t/src -Fi/t/src -Fu/t/adapters/smtp -Fu$C -Fi$C -Fu/t/tests/Integration -Fu/t/tests/Unit -FU/t/u -gh -gl \
    -o/t/runner PascalEmailIntegrationTestsFpc.lpr > /t/build.log 2>&1 \
    || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  cd /t
  HEAPTRC="log=/t/heap.txt" ./runner --all --format=plain > /t/run.log 2>&1 || true
  grep -E "^Number of" /t/run.log
  grep "unfreed" /t/heap.txt
  grep -B1 -A4 "Message:" /t/run.log | head -80 || true
  grep -qE "^Number of errors: +0$" /t/run.log && grep -qE "^Number of failures: +0$" /t/run.log \
    && grep -qE "^0 unfreed memory blocks" /t/heap.txt'
