#!/usr/bin/env bash
# Integration tests. Everything runs in containers on a throwaway network:
# no real DNS, no real CA, no real console.
set -euo pipefail

cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-unifi-os-acme:test}"
NET=unifi-os-acme-test
PASS=0
FAIL=0

cleanup() {
  docker rm -f mockdns1 mockdns2 mockunifi >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ok()   { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }

echo "==> building $IMAGE"
docker build -q -t "$IMAGE" . >/dev/null
cleanup
docker network create "$NET" >/dev/null

# ---------------------------------------------------------------------------
# Image metadata. Without an explicit LABEL block these are inherited from the
# base image and the result claims to be acme.sh, pointing registries at the
# wrong project. Easy to regress, invisible unless asserted.
# ---------------------------------------------------------------------------
echo "==> image metadata"
# Go templates render a missing key as an empty string on some engines and as
# the literal "<no value>" on others, which would quietly satisfy a bare -n
# test. Normalise so the assertions mean the same thing everywhere.
label() {
  v=$(docker image inspect "$IMAGE" --format "{{index .Config.Labels \"$1\"}}")
  [ "$v" = "<no value>" ] && v=""
  printf '%s' "$v"
}
check "$(label org.opencontainers.image.title)" "unifi-os-acme" "declares its own title"
check "$(label org.opencontainers.image.source)" "https://github.com/nugget/unifi-os-acme" "points at this repository"
check "$(label org.opencontainers.image.licenses)" "GPL-3.0-only" "declares its license"
# Assert the shape of the base reference rather than merely its presence: the
# point of recording the base is that it is pinned, so check for a real digest.
if echo "$(label org.opencontainers.image.base.name)" | grep -q "^docker.io/neilpang/acme.sh:"; then
  ok "records the base image it was built from"
else
  bad "records the base image it was built from"
fi
if echo "$(label org.opencontainers.image.base.digest)" | grep -qE "^sha256:[0-9a-f]{64}$"; then
  ok "records the base image digest, not just its tag"
else
  bad "records the base image digest, not just its tag"
fi

# ---------------------------------------------------------------------------
# The propagation gate.
#
# Two authoritative nameservers for the same zone. dns1 publishes the challenge
# record immediately; dns2 is told when to catch up. That is the real-world
# failure this tool exists to fix: a check that follows a recursive resolver
# can see dns1's copy and call it done while dns2 still has nothing, and the CA
# then queries dns2 and fails.
# ---------------------------------------------------------------------------
TXT_NAME=_acme-challenge.unifi.example.test
TXT_VALUE=test-challenge-value-12345
ZONE=example.test

start_dns() { # name, publish_after|never
  local name="$1" mode="$2"
  local -a env=(-e "ZONE=$ZONE" -e "NS_NAMES=mockdns1 mockdns2"
                -e "TXT_NAME=$TXT_NAME" -e "TXT_VALUE=$TXT_VALUE")
  if [ "$mode" = never ]; then env+=(-e NEVER=1); else env+=(-e "PUBLISH_AFTER=$mode"); fi
  docker run -d --name "$name" --network "$NET" --network-alias "$name" \
    -v "$PWD/test/mock_dns.py:/mock.py:ro" "${env[@]}" \
    python:3.12-alpine python /mock.py >/dev/null
}

gate() { # extra env..., prints log, returns gate exit code
  docker run --rm --network "$NET" \
    -v "$PWD/dnsapi:/hook:ro" -v "$PWD/test/gate_harness.sh:/harness.sh:ro" \
    -e "TXT_NAME=$TXT_NAME" -e "TXT_VALUE=$TXT_VALUE" \
    "$@" --entrypoint sh "$IMAGE" /harness.sh
}

echo "==> propagation gate"
start_dns mockdns1 0
start_dns mockdns2 0
sleep 2

out=$(gate -e ALLNS_SERVERS="mockdns1 mockdns2" -e ALLNS_TIMEOUT=15 || true)
check "$(echo "$out" | tail -1)" "rc=0" "passes when every nameserver has the record"

docker rm -f mockdns2 >/dev/null
start_dns mockdns2 never
sleep 2
out=$(gate -e ALLNS_SERVERS="mockdns1 mockdns2" -e ALLNS_TIMEOUT=8 -e ALLNS_INTERVAL=2 || true)
check "$(echo "$out" | tail -1)" "rc=1" "fails when one nameserver never catches up"
if echo "$out" | grep -q "Still missing the record: mockdns2"; then
  ok "names the lagging nameserver"
else
  bad "names the lagging nameserver"
fi
if echo "$out" | grep -E "Still missing|Still waiting" | grep -q "mockdns1"; then
  bad "does not blame the nameserver that is fine"
else
  ok "does not blame the nameserver that is fine"
fi

docker rm -f mockdns2 >/dev/null
start_dns mockdns2 12
sleep 2
out=$(gate -e ALLNS_SERVERS="mockdns1 mockdns2" -e ALLNS_TIMEOUT=60 -e ALLNS_INTERVAL=3 || true)
check "$(echo "$out" | tail -1)" "rc=0" "waits out a slow nameserver and then proceeds"

echo "==> nameserver discovery"
out=$(gate -e ALLNS_RESOLVER=mockdns1 -e ALLNS_TIMEOUT=15 || true)
check "$(echo "$out" | tail -1)" "rc=0" "discovers the zone's nameservers by walking up from the challenge name"

echo "==> misconfiguration"
out=$(gate -e ALLNS_SERVERS=mockdns1 -e ALLNS_PROVIDER_OVERRIDE=dns_allns -e ALLNS_TIMEOUT=5 || true)
check "$(echo "$out" | grep -c 'cannot be dns_allns')" "1" "refuses to delegate to itself"

# ---------------------------------------------------------------------------
# The deploy hook, against a stand-in for unifi-core that enforces the session
# cookie and CSRF header and swaps its TLS certificate on activation.
# ---------------------------------------------------------------------------
echo "==> deploy hook"
CERTS=$(mktemp -d)
ACME=$(mktemp -d)
trap 'cleanup; rm -rf "$CERTS" "$ACME"' EXIT

docker run --rm -v "$CERTS:/out" --entrypoint sh "$IMAGE" -c '
  cd /out
  openssl req -x509 -newkey rsa:2048 -nodes -keyout console.key -out console.crt -days 30 -subj "/CN=unifi.local" 2>/dev/null
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 30 -subj "/CN=Test CA" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=mockunifi" 2>/dev/null
  printf "subjectAltName=DNS:mockunifi\n" > ext
  openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out leaf.crt -days 30 -sha256 -extfile ext 2>/dev/null
  cat leaf.crt ca.crt > fullchain.crt
  chmod -R a+rw /out'

LEAF_FP=$(openssl x509 -in "$CERTS/leaf.crt" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':' | tr 'A-Z' 'a-z')

mkdir -p "$ACME/mockunifi"
cp "$CERTS/leaf.crt" "$ACME/mockunifi/mockunifi.cer"
cp "$CERTS/leaf.key" "$ACME/mockunifi/mockunifi.key"
cp "$CERTS/fullchain.crt" "$ACME/mockunifi/fullchain.cer"
cp "$CERTS/ca.crt" "$ACME/mockunifi/ca.cer"
echo "Le_Domain='mockunifi'" > "$ACME/mockunifi/mockunifi.conf"
touch "$ACME/account.conf"

docker run -d --name mockunifi --network "$NET" --network-alias mockunifi \
  -v "$CERTS:/certs" -v "$PWD/test/mock_unifi.py:/mock.py:ro" \
  python:3.12-alpine python /mock.py >/dev/null
sleep 3

deploy() {
  docker run --rm --network "$NET" -v "$ACME:/acme.sh" \
    -e DEPLOY_UNIFI_OS_HOST=mockunifi -e DEPLOY_UNIFI_OS_USER=acme \
    -e DEPLOY_UNIFI_OS_PASSWORD="${1:-s3cret}" \
    "$IMAGE" --deploy -d mockunifi --deploy-hook unifi_os 2>&1
}

out=$(deploy || true)
if echo "$out" | grep -q "is serving $LEAF_FP"; then
  ok "installs the certificate and confirms the console is serving it"
else
  bad "installs the certificate and confirms the console is serving it"
fi

state=$(docker exec mockunifi cat /certs/state.json 2>/dev/null || echo '{}')
check "$(echo "$state" | python3 -c 'import json,sys; print(json.load(sys.stdin)["certs"][-1]["chain_len"])')" "2" \
  "uploads the full chain, not a bare leaf"
if echo "$state" | grep -q "uploaded-by-hand"; then
  ok "leaves hand-uploaded certificates alone"
else
  bad "leaves hand-uploaded certificates alone"
fi
if echo "$state" | grep -q "acme.sh-20260101000000"; then
  bad "prunes its own superseded certificates"
else
  ok "prunes its own superseded certificates"
fi

out=$(deploy || true)
if echo "$out" | grep -q "already active"; then
  ok "is idempotent on a second run"
else
  bad "is idempotent on a second run"
fi

out=$(deploy wrong-password || true)
if echo "$out" | grep -q "Local Access Only"; then
  ok "explains an authentication failure"
else
  bad "explains an authentication failure"
fi

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
