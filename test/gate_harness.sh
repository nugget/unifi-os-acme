#!/usr/bin/env sh
# Exercises the gate directly, standing in for the acme.sh helpers it is
# normally sourced alongside.
_info()   { echo "[info] $*"; }
_err()    { echo "[err ] $*"; }
_debug()  { :; }
_debug2() { :; }
_sleep()  { sleep "$1"; }
_time()   { date -u +%s; }
_math()   { _m="$*"; printf "%s" "$(( _m ))"; }
_exists() { command -v "$1" >/dev/null 2>&1; }
_readaccountconf_mutable() { :; }
_saveaccountconf_mutable() { :; }

. /hook/dns_allns.sh

if [ -n "$ALLNS_PROVIDER_OVERRIDE" ]; then
  # shellcheck disable=SC2034  # read by the sourced plugin
  ALLNS_PROVIDER="$ALLNS_PROVIDER_OVERRIDE"
  _allns_load_provider
  echo "rc=$?"
  exit 0
fi

_allns_wait "$TXT_NAME" "$TXT_VALUE"
echo "rc=$?"
