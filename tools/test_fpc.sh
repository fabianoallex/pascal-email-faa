#!/bin/sh
# Regenerates the FPCUnit mirrors from the DUnitX masters, then builds and
# runs a suite with lazbuild (the .lpi and the packages, as a Lazarus user
# builds them). Acceptance criterion: 0 errors, 0 failures and
# "0 unfreed memory blocks" (heaptrc).
#
#   sh tools/test_fpc.sh               the unit suite
#   sh tools/test_fpc.sh integration   the integration suite, against Mailpit
#                                      (sh tools/mailpit.sh up first)
#
# The Delphi side has no command-line equivalent: Delphi Community Edition
# doesn't compile outside the IDE (dcc32 prints "This version of the product
# does not support command line compiling." and exits with code 0). Run
# tests\Unit\PascalEmail.UnitTests.dproj and
# tests\Integration\PascalEmail.IntegrationSuite.dproj from the IDE.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe

case "${1:-unit}" in
  unit) DIR=tests/Unit/fpc; PRJ=PascalEmailUnitTestsFpc; ENGINES=none ;;
  integration) DIR=tests/Integration/fpc; PRJ=PascalEmailIntegrationTestsFpc; ENGINES=mailpit ;;
  *) echo "usage: sh tools/test_fpc.sh [unit|integration]"; exit 2 ;;
esac

cd "$ROOT"
python tools/gen_fpc_mirror.py
cd "$DIR"
if ! "$LAZBUILD" -B $PRJ.lpi > build.log 2>&1; then
  grep -E "Error|Fatal" build.log | head -30
  exit 1
fi
FAILED=0
for E in $ENGINES; do
  [ "$E" = none ] || echo "== integration suite on $E"
  ./$PRJ.exe --all --format=plain > run.log 2>&1 || true
  grep -E "^Number of|unfreed" run.log
  grep -B1 -A4 "Message:" run.log | head -60 || true
  grep -qE "^Number of errors: +0$" run.log && grep -qE "^Number of failures: +0$" run.log \
    && grep -qE "^0 unfreed memory blocks" run.log || FAILED=1
done
exit $FAILED
