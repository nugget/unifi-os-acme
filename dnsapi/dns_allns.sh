#!/usr/bin/env sh
# shellcheck disable=SC2034
dns_allns_info='Propagation gate in front of any acme.sh DNS provider
Site: github.com/nugget/unifi-os-acme
Docs: github.com/nugget/unifi-os-acme#the-propagation-gate
Options:
 ALLNS_PROVIDER The real acme.sh DNS provider to delegate to, e.g. dns_cf
 ALLNS_SERVERS Space or comma separated nameservers. Default: discovered from the zone
 ALLNS_TIMEOUT Seconds to wait for full propagation. Default: 1800
 ALLNS_INTERVAL Seconds between polls. Default: 20
 ALLNS_RESOLVER Resolver used for zone and NS discovery. Default: system resolver
Issues: github.com/nugget/unifi-os-acme/issues
'

# A wrapper DNS provider. It adds the challenge TXT using whichever real
# provider you name in ALLNS_PROVIDER, then blocks until *every* authoritative
# nameserver for the zone returns the record, asked directly.
#
# Why: acme.sh's built-in propagation check queries a recursive resolver, which
# follows whichever authoritative server it happens to pick. On providers that
# publish to their nameservers at different times, that check goes green as soon
# as ONE nameserver has the record. The CA then queries the authoritative set
# itself, may land on one that is still lagging, and validation fails. The
# symptom is intermittent, seemingly random renewal failures. Waiting longer
# narrows the race; asking every nameserver directly removes it.
#
# Use with --dnssleep 1 so acme.sh skips its own weaker check.
#
# Failing the add aborts issuance before the CA is asked to validate, so a slow
# zone costs a retry instead of a failed validation against the rate limit.

_ALLNS_DEFAULT_TIMEOUT=1800
_ALLNS_DEFAULT_INTERVAL=20

# Load the provider named in ALLNS_PROVIDER.
_allns_load_provider() {
  # Env wins; otherwise fall back to what a previous run saved, so renewals
  # keep working if the environment is ever lost.
  ALLNS_PROVIDER="${ALLNS_PROVIDER:-$(_readaccountconf_mutable ALLNS_PROVIDER)}"

  if [ -z "$ALLNS_PROVIDER" ]; then
    _err "ALLNS_PROVIDER is not set. Name the real DNS provider to delegate to,"
    _err "for example ALLNS_PROVIDER=dns_cf or ALLNS_PROVIDER=dns_linode_v4."
    return 1
  fi
  case "$ALLNS_PROVIDER" in
  dns_allns)
    _err "ALLNS_PROVIDER cannot be dns_allns."
    return 1
    ;;
  dns_*) ;;
  *)
    _err "ALLNS_PROVIDER must name an acme.sh DNS provider, e.g. dns_cf."
    return 1
    ;;
  esac

  _saveaccountconf_mutable ALLNS_PROVIDER "$ALLNS_PROVIDER"

  if _exists "${ALLNS_PROVIDER}_add"; then
    return 0
  fi
  for _alp_dir in "$_SCRIPT_HOME/dnsapi" "$LE_WORKING_DIR/dnsapi" "$LE_CONFIG_HOME/dnsapi"; do
    if [ -f "$_alp_dir/$ALLNS_PROVIDER.sh" ]; then
      _debug "Loading provider $_alp_dir/$ALLNS_PROVIDER.sh"
      # shellcheck source=/dev/null
      . "$_alp_dir/$ALLNS_PROVIDER.sh"
      return 0
    fi
  done
  _err "Could not find the DNS provider '$ALLNS_PROVIDER'."
  return 1
}

_allns_dig() {
  if [ -n "$ALLNS_RESOLVER" ]; then
    dig +short +time=5 +tries=2 "$@" "@$ALLNS_RESOLVER" 2>/dev/null
  else
    dig +short +time=5 +tries=2 "$@" 2>/dev/null
  fi
}

# Walk up from the challenge name to the closest enclosing zone that has NS
# records. A delegated subzone wins over its parent, which is what we want.
_allns_find_zone() {
  _afz_name="$1"
  _afz_candidate="$_afz_name"

  while [ -n "$_afz_candidate" ]; do
    # Stop before querying a bare TLD.
    case "$_afz_candidate" in
    *.*) ;;
    *) break ;;
    esac
    if [ -n "$(_allns_dig NS "$_afz_candidate")" ]; then
      printf '%s' "$_afz_candidate"
      return 0
    fi
    _afz_next="${_afz_candidate#*.}"
    [ "$_afz_next" = "$_afz_candidate" ] && break
    _afz_candidate="$_afz_next"
  done
  return 1
}

# The nameservers to poll: explicit list if given, otherwise the zone's NS set.
_allns_servers_for() {
  _asf_name="$1"

  if [ -n "$ALLNS_SERVERS" ]; then
    printf '%s' "$ALLNS_SERVERS" | tr ',' ' '
    return 0
  fi

  _asf_zone="$(_allns_find_zone "$_asf_name")"
  if [ -z "$_asf_zone" ]; then
    _err "Could not find the zone for $_asf_name."
    _err "Set ALLNS_SERVERS to list the authoritative nameservers explicitly."
    return 1
  fi
  _debug "Zone for $_asf_name" "$_asf_zone"

  _asf_ns="$(_allns_dig NS "$_asf_zone" | sed 's/\.$//' | grep -v '^$' | tr '\n' ' ')"
  if [ -z "$_asf_ns" ]; then
    _err "Zone $_asf_zone returned no NS records."
    _err "Set ALLNS_SERVERS to list the authoritative nameservers explicitly."
    return 1
  fi
  printf '%s' "$_asf_ns"
}

# Is $2 present as a TXT value for name $1, according to nameserver $3?
_allns_has_txt() {
  _aht_name="$1"
  _aht_txt="$2"
  _aht_ns="$3"

  _aht_out="$(dig +short +time=5 +tries=2 TXT "$_aht_name" "@$_aht_ns" 2>/dev/null)"
  _debug2 "$_aht_ns answered" "$_aht_out"
  # A name can hold several TXT records at once - a wildcard and its base name
  # are validated together - so match on presence, not on the whole answer.
  printf '%s\n' "$_aht_out" | grep -qF "\"$_aht_txt\""
}

# Block until every authoritative nameserver serves the challenge record.
_allns_wait() {
  _aw_name="$1"
  _aw_txt="$2"

  if ! _exists dig; then
    _err "dns_allns requires 'dig' (Alpine: apk add bind-tools, Debian: dnsutils)."
    return 1
  fi

  ALLNS_SERVERS="${ALLNS_SERVERS:-$(_readaccountconf_mutable ALLNS_SERVERS)}"
  ALLNS_RESOLVER="${ALLNS_RESOLVER:-$(_readaccountconf_mutable ALLNS_RESOLVER)}"
  _saveaccountconf_mutable ALLNS_SERVERS "$ALLNS_SERVERS"
  _saveaccountconf_mutable ALLNS_RESOLVER "$ALLNS_RESOLVER"

  _aw_servers="$(_allns_servers_for "$_aw_name")" || return 1
  _aw_timeout="${ALLNS_TIMEOUT:-$_ALLNS_DEFAULT_TIMEOUT}"
  _aw_interval="${ALLNS_INTERVAL:-$_ALLNS_DEFAULT_INTERVAL}"

  _info "Waiting for $_aw_name on every authoritative nameserver:$(printf ' %s' $_aw_servers)"
  _aw_deadline="$(_math "$(_time)" + "$_aw_timeout")"

  while :; do
    _aw_missing=""
    for _aw_ns in $_aw_servers; do
      if ! _allns_has_txt "$_aw_name" "$_aw_txt" "$_aw_ns"; then
        _aw_missing="$_aw_missing $_aw_ns"
      fi
    done

    if [ -z "$_aw_missing" ]; then
      _info "All nameservers are serving the challenge record."
      return 0
    fi

    if [ "$(_time)" -ge "$_aw_deadline" ]; then
      _err "Timed out after ${_aw_timeout}s. Still missing the record:$_aw_missing"
      _err "Raise ALLNS_TIMEOUT if this provider is consistently slower than that."
      return 1
    fi

    _info "Still waiting on:$_aw_missing"
    _sleep "$_aw_interval"
  done
}

dns_allns_add() {
  _aa_fulldomain="$1"
  _aa_txtvalue="$2"

  _allns_load_provider || return 1
  "${ALLNS_PROVIDER}_add" "$_aa_fulldomain" "$_aa_txtvalue" || return 1
  _allns_wait "$_aa_fulldomain" "$_aa_txtvalue"
}

dns_allns_rm() {
  _ar_fulldomain="$1"
  _ar_txtvalue="$2"

  _allns_load_provider || return 1
  "${ALLNS_PROVIDER}_rm" "$_ar_fulldomain" "$_ar_txtvalue"
}
