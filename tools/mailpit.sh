#!/bin/sh
# Starts (up, the default) or removes (down) the SMTP servers the
# integration suite runs against: Mailpit in Docker, version pinned, three
# ways (SMTP port -> host, API port -> host):
#   pascalemail-it-starttls  STARTTLS required, AUTH        12587, API 18025
#   pascalemail-it-tls       TLS from the first byte, AUTH   12465, API 18026
#   pascalemail-it-plain     no TLS, no AUTH                 12525, API 18027
# The TLS ones use a certificate from a private CA made here, and accept
# recipients only in @example.com (anything else is refused with a 5xx, for
# the partial-refusal tests). AUTH: user "it-user", password "it-pass".
# All on the network pascalemail-it-net (aliases mailpit-starttls,
# mailpit-tls, mailpit-tls-other, mailpit-plain).
#
# The CA and the server certificate go to .ci/it-certs (git-ignored), made
# with openssl in a debian:bookworm container, again only when the names
# below change. The certificate names localhost, mailpit-starttls and
# mailpit-tls; 127.0.0.1 and mailpit-tls-other are left out on purpose, to
# test a wrong host name.
#
# The runners' defaults point at the host ports (tests/Integration,
# PascalEmail.IntegrationEnv), so after "sh tools/mailpit.sh" the Delphi and
# the FPC Windows runners work as they are. tools/test_integration_docker.sh
# runs the Linux one inside the network. Only these containers are touched.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="${1:-up}"
NET=pascalemail-it-net
IMG=axllent/mailpit:v1.33.1
NAMES="pascalemail-it-starttls pascalemail-it-tls pascalemail-it-plain"
SANS="DNS:mailpit-starttls,DNS:mailpit-tls,DNS:localhost"
CERTS="$ROOT/.ci/it-certs"
MOUNT="$CERTS"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$CERTS")"

down() {
  docker rm -f $NAMES >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
}

if [ "$CMD" = down ]; then
  down
  exit 0
fi
[ "$CMD" = up ] || { echo "usage: sh tools/mailpit.sh [up|down]"; exit 2; }
down

mkdir -p "$CERTS"
if [ "$(cat "$CERTS/sans" 2>/dev/null)" != "$SANS" ]; then
  echo "== certificates (.ci/it-certs)"
  MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/c" -e SANS="$SANS" debian:bookworm sh -c '
    set -e
    apt-get update -qq >/dev/null && apt-get install -y -qq openssl >/dev/null
    cd /c
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=pascal-email-it CA" \
      -keyout ca.key -out ca.pem 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr 2>/dev/null
    echo "subjectAltName=$SANS" > ext.cnf
    echo "basicConstraints=CA:FALSE" >> ext.cnf
    echo "extendedKeyUsage=serverAuth" >> ext.cnf
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 \
      -extfile ext.cnf -out server.pem 2>/dev/null
    rm -f server.csr ext.cnf ca.srl
    printf "it-user:it-pass\n" > auth
    printf "%s" "$SANS" > sans
    chmod 644 /c/*'
fi

echo "== Mailpit"
docker network create $NET >/dev/null
TLS="--smtp-tls-cert /certs/server.pem --smtp-tls-key /certs/server.key"
CHECKS="--smtp-auth-file /certs/auth --smtp-allowed-recipients @example\.com$ --smtp-disable-rdns"
MSYS_NO_PATHCONV=1 docker run -d --name pascalemail-it-starttls --network $NET \
  --network-alias mailpit-starttls -p 12587:1025 -p 18025:8025 -v "$MOUNT:/certs:ro" \
  $IMG $TLS --smtp-require-starttls $CHECKS >/dev/null
MSYS_NO_PATHCONV=1 docker run -d --name pascalemail-it-tls --network $NET \
  --network-alias mailpit-tls --network-alias mailpit-tls-other -p 12465:1025 -p 18026:8025 \
  -v "$MOUNT:/certs:ro" $IMG $TLS --smtp-require-tls $CHECKS >/dev/null
MSYS_NO_PATHCONV=1 docker run -d --name pascalemail-it-plain --network $NET \
  --network-alias mailpit-plain -p 12525:1025 -p 18027:8025 $IMG --smtp-disable-rdns >/dev/null

up() { curl -sf -m 2 "$1/api/v1/info" >/dev/null 2>&1; }
for i in $(seq 1 60); do
  if up http://127.0.0.1:18025 && up http://127.0.0.1:18026 && up http://127.0.0.1:18027; then
    echo "ready: SMTP localhost:12587 (STARTTLS), :12465 (TLS), :12525 (plain);" \
      "API http://localhost:18025, :18026, :18027 (CA: .ci/it-certs/ca.pem)"
    exit 0
  fi
  sleep 1
done
echo "Mailpit didn't answer in 60 s"
for N in $NAMES; do echo "== $N"; docker logs $N 2>&1 | tail -5; done
exit 1
