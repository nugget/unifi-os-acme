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

LE_CONFIG_HOME="${LE_CONFIG_HOME:-/acme.sh}"
ACME="$LE_WORKING_DIR/acme.sh"

# shellcheck source=lib/certpath.sh
. /usr/local/lib/certpath.sh
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
# Let's Encrypt rejects reserved example domains with a 400 that reads like a
# CA problem rather than a copied placeholder. Say so plainly instead.
case "$ACME_EMAIL" in
*@example.com | *@example.org | *@example.net | *@example.edu)
  die "ACME_EMAIL is still the placeholder ($ACME_EMAIL). Certificate authorities reject example.* addresses; use a real one."
  ;;
esac
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
# Look for the certificate file itself rather than parsing `acme.sh --list`:
# the file is the thing that matters. select_cert is shared with the
# healthcheck, so the two cannot disagree about which certificate is live.
_have_cert() {
  select_cert "$1"
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
    ${ACME_FORCE_ISSUE:+--force} \
    ${ACME_EXTRA_ARGS:-} || die "Issuance failed. See the log above."
fi

# Install it, every time, whether or not we just issued.
#
# This is not belt and braces, it is the only thing that installs anything.
# acme.sh accepts --deploy-hook on --issue and silently ignores it: the flag is
# read only by the deploy command, and the post-issue deploy inside renew()
# fires on Le_DeployHook, which lives in the domain conf and is written only by
# an actual deploy. So `--issue --deploy-hook x` issues a certificate, installs
# nothing, and leaves renewals with nothing to run either.
#
# Running the deploy explicitly installs the certificate now AND records
# Le_DeployHook, which is what makes future renewals deploy on their own.
#
# It is also the reconciliation step: on a restart with a certificate already
# in hand, this is what notices that the console is serving something else. The
# hook compares fingerprints and no-ops when the console is current.
select_cert "$_primary" || die "No certificate to install for $_primary."
_ecc="$CERT_ECC_FLAG"
log "Installing the certificate on the console (${CERT_FILE})."
# shellcheck disable=SC2086
if ! "$ACME" $HOMEARGS --deploy -d "$_primary" $_ecc --deploy-hook unifi_os; then
  # Deliberately not fatal: renewals should keep running even if the console is
  # unreachable right now. The healthcheck reports this state.
  log "ERROR: could not install the certificate on the console (see above)."
  log "The renewal daemon will still start; the healthcheck will report unhealthy."
fi

# ------------------------------------------------------------------- renewal
if [ "$RUN_ONCE" = "1" ]; then
  log "RUN_ONCE=1, running a renewal pass and exiting."
  "$ACME" $HOMEARGS --cron
  exit $?
fi

log "Handing off to the renewal daemon."
exec /entry.sh daemon
