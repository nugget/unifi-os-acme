#!/usr/bin/env sh
# Is the certificate actually doing its job?
#
# Liveness is not the interesting question: the renewal daemon is the
# container's main process, so if it dies the container exits and Docker
# already knows. What fails silently is the outcome. Three things can be wrong
# while the container looks perfectly fine:
#
#   1. Issuance never succeeded, so there is no certificate at all.
#   2. Renewals have been failing for weeks and expiry is closing in.
#   3. Something on the console replaced what we installed - a firmware
#      update, another tool, or a person in the UI.
#
# Each is checked directly. No credentials are needed: the console check is a
# plain TLS handshake.
set -u

fail() {
  echo "unhealthy: $*"
  exit 1
}

fingerprint() {
  openssl x509 -noout -fingerprint -sha1 2>/dev/null |
    cut -d= -f2 | tr -d ':\r\n' | tr '[:upper:]' '[:lower:]'
}

# Defaulted rather than assumed: the image sets this, but the script is also
# run by hand, and `set -u` would otherwise abort with "parameter not set"
# instead of anything a reader could act on.
LE_CONFIG_HOME="${LE_CONFIG_HOME:-/acme.sh}"
MIN_DAYS="${HEALTHCHECK_MIN_DAYS:-21}"
CHECK_CONSOLE="${HEALTHCHECK_CHECK_CONSOLE:-1}"

# Shell arithmetic resolves a non-numeric value to 0, which would turn the
# expiry test into `-checkend 0` and report healthy for any certificate that
# has not already expired. A typo here must not silently disable the check.
case "$MIN_DAYS" in
'' | *[!0-9]*) fail "HEALTHCHECK_MIN_DAYS must be a whole number of days, got '$MIN_DAYS'" ;;
esac

[ -n "${ACME_DOMAINS:-}" ] || fail "ACME_DOMAINS is not set"

# Only the first name is needed, and it names the certificate acme.sh stores.
primary="${ACME_DOMAINS%%[, ]*}"
[ -n "$primary" ] || fail "ACME_DOMAINS does not begin with a domain name: '$ACME_DOMAINS'"

# acme.sh keeps EC certificates in <domain>_ecc.
cert=""
for dir in "$LE_CONFIG_HOME/$primary" "$LE_CONFIG_HOME/${primary}_ecc"; do
  if [ -f "$dir/$primary.cer" ]; then
    cert="$dir/$primary.cer"
    break
  fi
done
[ -n "$cert" ] || fail "no certificate has been issued for $primary"

# Renewal begins 30 days before expiry and retries four times a day. Falling
# under MIN_DAYS means it has been failing for over a week, which nothing else
# would surface until the certificate actually lapsed.
if ! openssl x509 -in "$cert" -noout -checkend "$((MIN_DAYS * 86400))" >/dev/null 2>&1; then
  expiry="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)"
  fail "certificate for $primary expires $expiry, under ${MIN_DAYS}d away; renewals are failing"
fi

if [ "$CHECK_CONSOLE" != "1" ]; then
  echo "healthy: certificate for $primary is valid (console check disabled)"
  exit 0
fi

host="${DEPLOY_UNIFI_OS_HOST:-$primary}"
case "$host" in
*:*) hostport="$host" ;;
*) hostport="$host:443" ;;
esac
sni="${hostport%:*}"

want="$(fingerprint <"$cert")"
got="$(echo | openssl s_client -connect "$hostport" -servername "$sni" 2>/dev/null | fingerprint)"

[ -n "$got" ] || fail "$host did not complete a TLS handshake"
[ "$got" = "$want" ] || fail "$host is serving $got, expected $want"

echo "healthy: $host is serving the certificate for $primary"
