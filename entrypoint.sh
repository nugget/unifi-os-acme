#!/usr/bin/env sh
# Turns a pile of environment variables into a working acme.sh setup:
# register, issue if needed, deploy, then hand off to the renewal daemon.
#
# Any argument starting with '-' is passed straight through to acme.sh
# instead, so the container doubles as an acme.sh CLI:
#   docker compose run --rm acme --list
set -eu

# $HOMEARGS and the assembled acme.sh argument lists are word-split on purpose.
# shellcheck disable=SC2086

ACME="$LE_WORKING_DIR/acme.sh"
HOMEARGS="--home $LE_WORKING_DIR --config-home $LE_CONFIG_HOME"

ACME_SERVER="${ACME_SERVER:-letsencrypt}"
ACME_KEYLENGTH="${ACME_KEYLENGTH:-2048}"
ACME_NS_GATE="${ACME_NS_GATE:-1}"
ACME_RETRY_DELAY="${ACME_RETRY_DELAY:-300}"
RUN_ONCE="${RUN_ONCE:-0}"

log() { echo "[entrypoint] $*"; }

die() {
  log "ERROR: $*"
  log "Sleeping ${ACME_RETRY_DELAY}s before exiting so a restart loop stays readable."
  sleep "$ACME_RETRY_DELAY"
  exit 1
}

# Escape hatch: use this container as the acme.sh CLI.
case "${1:-}" in
-*) exec "$ACME" $HOMEARGS "$@" ;;
esac

# ---------------------------------------------------------------- validation
[ -n "${ACME_DOMAINS:-}" ] || die "ACME_DOMAINS is required (one or more names, space or comma separated)."
[ -n "${ACME_EMAIL:-}" ] || die "ACME_EMAIL is required to register an ACME account."
[ -n "${ACME_DNS_PROVIDER:-}" ] || die "ACME_DNS_PROVIDER is required, e.g. dns_cf. See https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
[ -n "${DEPLOY_UNIFI_OS_USER:-}" ] || die "DEPLOY_UNIFI_OS_USER is required."
[ -n "${DEPLOY_UNIFI_OS_PASSWORD:-}" ] || die "DEPLOY_UNIFI_OS_PASSWORD is required."

# One -d per name; the first is the certificate's primary name.
_domain_args=""
_primary=""
for _d in $(echo "$ACME_DOMAINS" | tr ',' ' '); do
  [ -n "$_primary" ] || _primary="$_d"
  _domain_args="$_domain_args -d $_d"
done

# The console defaults to the primary name, which is the common case.
DEPLOY_UNIFI_OS_HOST="${DEPLOY_UNIFI_OS_HOST:-$_primary}"
export DEPLOY_UNIFI_OS_HOST

# --------------------------------------------------------------- dns backend
if [ "$ACME_NS_GATE" = "1" ]; then
  # Gate on every authoritative nameserver, and turn off acme.sh's own weaker
  # DoH check, which this supersedes. See README: "The propagation gate".
  ALLNS_PROVIDER="$ACME_DNS_PROVIDER"
  export ALLNS_PROVIDER
  _dns_args="--dns dns_allns --dnssleep 1"
  log "DNS-01 via $ACME_DNS_PROVIDER, gated on all authoritative nameservers."
else
  _dns_args="--dns $ACME_DNS_PROVIDER"
  if [ -n "${ACME_DNSSLEEP:-}" ]; then
    _dns_args="$_dns_args --dnssleep $ACME_DNSSLEEP"
  fi
  log "DNS-01 via $ACME_DNS_PROVIDER, propagation gate disabled."
fi

# ---------------------------------------------------------------- issue once
# acme.sh --list prints one row per certificate, main domain in column 1.
_have_cert() {
  "$ACME" $HOMEARGS --list 2>/dev/null | awk -v d="$1" 'NR>1 && $1==d {found=1} END {exit !found}'
}

if _have_cert "$_primary" && [ "${ACME_FORCE_ISSUE:-0}" != "1" ]; then
  log "Certificate for $_primary already exists; skipping issuance."
else
  log "Registering ACME account with $ACME_SERVER"
  "$ACME" $HOMEARGS --register-account -m "$ACME_EMAIL" --server "$ACME_SERVER" ||
    die "Account registration failed."

  log "Issuing certificate for:$_domain_args"
  # shellcheck disable=SC2086
  "$ACME" $HOMEARGS --issue $_domain_args $_dns_args \
    --server "$ACME_SERVER" \
    --keylength "$ACME_KEYLENGTH" \
    --deploy-hook unifi_os \
    ${ACME_FORCE_ISSUE:+--force} \
    ${ACME_EXTRA_ARGS:-} || die "Issuance failed. See the log above."
fi

# ------------------------------------------------------------------- renewal
if [ "$RUN_ONCE" = "1" ]; then
  log "RUN_ONCE=1, running a renewal pass and exiting."
  "$ACME" $HOMEARGS --cron
  exit $?
fi

log "Handing off to the renewal daemon."
exec /entry.sh daemon
