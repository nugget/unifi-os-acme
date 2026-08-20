#!/usr/bin/env sh

# acme.sh deploy hook: UniFi OS console (EFG / UDM / UCG / Cloud Key Gen2+).
#
# Pushes the certificate over the unifi-core HTTPS API from a remote machine.
# acme.sh's bundled `unifi` hook only writes local files and must run ON the
# console; this one talks to /api/userCertificates, the same API the
# Control Plane -> Console -> Certificates page uses.
#
# Configuration (env on first run, then persisted to the domain conf):
#   DEPLOY_UNIFI_OS_HOST      console hostname or IP  (default: cert domain)
#   DEPLOY_UNIFI_OS_USER      console admin, Local Access Only, no MFA
#   DEPLOY_UNIFI_OS_PASSWORD  password for that admin (stored base64 in the
#                             domain conf on the acme.sh volume)
#   DEPLOY_UNIFI_OS_NAME      name prefix for uploaded certs (default: acme.sh)
#   DEPLOY_UNIFI_OS_KEEP_OLD  1 = never delete superseded certs (default: 0)
#   DEPLOY_UNIFI_OS_VERIFY    1 = verify the console's TLS cert (default: 0)

# Request helper. Uses _unifi_os_base / _unifi_os_jar / _unifi_os_csrf /
# _unifi_os_curlopts set by unifi_os_deploy.
# Usage: _unifi_os_req METHOD PATH BODY_OUT_FILE [JSON_PAYLOAD_FILE]
_unifi_os_req() {
  _rq_method="$1"
  _rq_path="$2"
  _rq_out="$3"
  _rq_data="$4"

  if [ -n "$_rq_data" ]; then
    # shellcheck disable=SC2086
    curl $_unifi_os_curlopts -o "$_rq_out" -w '%{http_code}' \
      -b "$_unifi_os_jar" \
      -H "x-csrf-token: $_unifi_os_csrf" \
      -H 'Content-Type: application/json' \
      -X "$_rq_method" --data-binary "@$_rq_data" \
      "$_unifi_os_base$_rq_path"
  else
    # shellcheck disable=SC2086
    curl $_unifi_os_curlopts -o "$_rq_out" -w '%{http_code}' \
      -b "$_unifi_os_jar" \
      -H "x-csrf-token: $_unifi_os_csrf" \
      -X "$_rq_method" \
      "$_unifi_os_base$_rq_path"
  fi
}

# SHA-1 fingerprint of a PEM cert on stdin or in a file, lowercase, no colons.
_unifi_os_fp() {
  openssl x509 ${1:+-in "$1"} -noout -fingerprint -sha1 2>/dev/null \
    | cut -d= -f2 | tr -d ':\r\n' | tr 'A-Z' 'a-z'
}

# Fingerprint the certificate the console is actually serving right now.
_unifi_os_served_fp() {
  echo | openssl s_client -connect "$1" -servername "$2" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
    | cut -d= -f2 | tr -d ':\r\n' | tr 'A-Z' 'a-z'
}

unifi_os_deploy() {
  _cdomain="$1"
  _ckey="$2"
  _ccert="$3"
  _cca="$4"
  _cfullchain="$5"

  _debug _cdomain "$_cdomain"
  _debug _ccert "$_ccert"
  _debug _cfullchain "$_cfullchain"

  for _bin in curl jq openssl; do
    if ! _exists "$_bin"; then
      _err "unifi_os deploy hook requires '$_bin'."
      return 1
    fi
  done

  _getdeployconf DEPLOY_UNIFI_OS_HOST
  _getdeployconf DEPLOY_UNIFI_OS_USER
  _getdeployconf DEPLOY_UNIFI_OS_PASSWORD
  _getdeployconf DEPLOY_UNIFI_OS_NAME
  _getdeployconf DEPLOY_UNIFI_OS_KEEP_OLD
  _getdeployconf DEPLOY_UNIFI_OS_VERIFY

  _unifi_host="${DEPLOY_UNIFI_OS_HOST:-$_cdomain}"
  _unifi_name="${DEPLOY_UNIFI_OS_NAME:-acme.sh}"
  _unifi_keep="${DEPLOY_UNIFI_OS_KEEP_OLD:-0}"
  _unifi_verify="${DEPLOY_UNIFI_OS_VERIFY:-0}"

  if [ -z "$DEPLOY_UNIFI_OS_USER" ] || [ -z "$DEPLOY_UNIFI_OS_PASSWORD" ]; then
    _err "DEPLOY_UNIFI_OS_USER and DEPLOY_UNIFI_OS_PASSWORD must be set."
    _err "The account must be a console admin with Local Access Only and no MFA."
    return 1
  fi

  _debug _unifi_host "$_unifi_host"
  _debug _unifi_name "$_unifi_name"
  _secure_debug DEPLOY_UNIFI_OS_PASSWORD "$DEPLOY_UNIFI_OS_PASSWORD"

  _unifi_os_base="https://$_unifi_host"
  _unifi_os_curlopts="-sS --connect-timeout 10 --max-time 60"
  if [ "$_unifi_verify" != "1" ]; then
    # The console is normally still presenting its self-signed cert the first
    # time through. Correctness is established by fingerprint check below.
    _unifi_os_curlopts="$_unifi_os_curlopts -k"
  fi

  case "$_unifi_host" in
  *:*) _unifi_hostport="$_unifi_host" ;;
  *) _unifi_hostport="$_unifi_host:443" ;;
  esac
  _unifi_sni="${_unifi_hostport%:*}"

  _unifi_os_jar="$(_mktemp)"
  _unifi_hdr="$(_mktemp)"
  _unifi_body="$(_mktemp)"
  _unifi_payload="$(_mktemp)"
  _unifi_rc=1

  # Everything from here on funnels through _unifi_os_done for cleanup.
  _unifi_os_cleanup() {
    [ -n "$_unifi_os_csrf" ] &&
      _unifi_os_req POST /api/auth/logout "$_unifi_body" >/dev/null 2>&1
    rm -f "$_unifi_os_jar" "$_unifi_hdr" "$_unifi_body" "$_unifi_payload"
  }

  _info "Logging in to UniFi OS at $_unifi_host"
  jq -n --arg u "$DEPLOY_UNIFI_OS_USER" --arg p "$DEPLOY_UNIFI_OS_PASSWORD" \
    '{username: $u, password: $p}' >"$_unifi_payload"

  # shellcheck disable=SC2086
  _code="$(curl $_unifi_os_curlopts -o "$_unifi_body" -w '%{http_code}' \
    -c "$_unifi_os_jar" -D "$_unifi_hdr" \
    -X POST "$_unifi_os_base/api/auth/login" \
    -H 'Content-Type: application/json' \
    --data-binary "@$_unifi_payload")"

  if [ "$_code" != "200" ]; then
    _err "Login failed (HTTP $_code)."
    case "$_code" in
    401 | 403) _err "Check the credentials, and that the account is Local Access Only with MFA off." ;;
    499 | 000) _err "Could not reach $_unifi_host. Check DNS/routing from the container." ;;
    esac
    _debug2 response "$(cat "$_unifi_body")"
    _unifi_os_cleanup
    return 1
  fi

  _unifi_os_csrf="$(grep -i '^x-csrf-token:' "$_unifi_hdr" | tail -1 |
    sed 's/^[^:]*: *//' | tr -d '\r\n')"
  _debug _unifi_os_csrf "$_unifi_os_csrf"

  # Persisted only after a successful login, so a typo'd password cannot
  # overwrite a working saved one.
  _savedeployconf DEPLOY_UNIFI_OS_HOST "$_unifi_host"
  _savedeployconf DEPLOY_UNIFI_OS_USER "$DEPLOY_UNIFI_OS_USER"
  _savedeployconf DEPLOY_UNIFI_OS_PASSWORD "$DEPLOY_UNIFI_OS_PASSWORD" 1
  _savedeployconf DEPLOY_UNIFI_OS_NAME "$_unifi_name"
  _savedeployconf DEPLOY_UNIFI_OS_KEEP_OLD "$_unifi_keep"
  _savedeployconf DEPLOY_UNIFI_OS_VERIFY "$_unifi_verify"

  # --- current state -------------------------------------------------------
  _code="$(_unifi_os_req GET /api/userCertificates "$_unifi_body")"
  if [ "$_code" != "200" ]; then
    _err "Could not list certificates (HTTP $_code)."
    _debug2 response "$(cat "$_unifi_body")"
    _unifi_os_cleanup
    return 1
  fi

  # Tolerate either a bare array or an envelope object.
  _certs="$(jq 'if type == "object" then (.data // .certificates // []) else . end' \
    <"$_unifi_body" 2>/dev/null)"
  if [ -z "$_certs" ]; then
    _err "Unexpected response from /api/userCertificates."
    _debug2 response "$(cat "$_unifi_body")"
    _unifi_os_cleanup
    return 1
  fi

  _local_fp="$(_unifi_os_fp "$_ccert")"
  _active_fp="$(printf '%s' "$_certs" |
    jq -r 'map(select(.active == true)) | first | (.fingerprint // "")' |
    tr -d ':\r\n' | tr 'A-Z' 'a-z')"
  _debug _local_fp "$_local_fp"
  _debug _active_fp "$_active_fp"

  if [ -n "$_local_fp" ] && [ "$_local_fp" = "$_active_fp" ]; then
    _info "Certificate $_local_fp is already active on $_unifi_host, nothing to do."
    _unifi_os_cleanup
    return 0
  fi

  # --- upload --------------------------------------------------------------
  _new_name="$_unifi_name-$(date -u +%Y%m%d%H%M%S)"
  _info "Uploading certificate as '$_new_name'"

  # --rawfile keeps the PEM byte-exact, trailing newline included.
  jq -n --arg name "$_new_name" \
    --rawfile cert "$_cfullchain" \
    --rawfile key "$_ckey" \
    '{name: $name, cert: $cert, key: $key}' >"$_unifi_payload"

  _code="$(_unifi_os_req POST /api/userCertificates "$_unifi_body" "$_unifi_payload")"
  if [ "$_code" != "200" ] && [ "$_code" != "201" ]; then
    _err "Certificate upload failed (HTTP $_code)."
    _err "$(cat "$_unifi_body")"
    _unifi_os_cleanup
    return 1
  fi

  _new_id="$(jq -r '(.id // ._id // .data.id // "")' <"$_unifi_body" 2>/dev/null)"
  if [ -z "$_new_id" ] || [ "$_new_id" = "null" ]; then
    _err "Upload succeeded but no certificate id came back."
    _err "$(cat "$_unifi_body")"
    _unifi_os_cleanup
    return 1
  fi
  _info "Uploaded certificate id $_new_id"

  # --- activate ------------------------------------------------------------
  printf '%s' '{"active": true}' >"$_unifi_payload"
  _code="$(_unifi_os_req PUT "/api/userCertificates/$_new_id/status" \
    "$_unifi_body" "$_unifi_payload")"
  if [ "$_code" != "200" ] && [ "$_code" != "204" ]; then
    _err "Activation failed (HTTP $_code). Leaving the previous certificate in place."
    _err "$(cat "$_unifi_body")"
    _unifi_os_cleanup
    return 1
  fi
  _info "Activated certificate id $_new_id"

  # --- verify --------------------------------------------------------------
  # unifi-core reloads nginx asynchronously; give it a few seconds to settle.
  _served_fp=""
  _tries=0
  while [ "$_tries" -lt 10 ]; do
    _served_fp="$(_unifi_os_served_fp "$_unifi_hostport" "$_unifi_sni")"
    [ "$_served_fp" = "$_local_fp" ] && break
    _tries=$((_tries + 1))
    sleep 3
  done

  if [ "$_served_fp" != "$_local_fp" ]; then
    _err "$_unifi_host is still serving $_served_fp, expected $_local_fp."
    _err "The new certificate was uploaded and activated but is not being served."
    _err "Keeping every existing certificate so the console stays recoverable."
    _unifi_os_cleanup
    return 1
  fi
  _info "$_unifi_host is serving $_served_fp"
  _unifi_rc=0

  # --- prune ---------------------------------------------------------------
  # Only ever touch certificates this hook created. Anything uploaded by hand
  # through the UI is left alone.
  if [ "$_unifi_keep" = "1" ]; then
    _info "DEPLOY_UNIFI_OS_KEEP_OLD=1, leaving superseded certificates in place."
  else
    _old_ids="$(printf '%s' "$_certs" |
      jq -r --arg p "$_unifi_name-" \
        '.[] | select((.name // "") | startswith($p)) | (.id // ._id // empty)')"
    for _old_id in $_old_ids; do
      [ "$_old_id" = "$_new_id" ] && continue
      _info "Deleting superseded certificate id $_old_id"
      _code="$(_unifi_os_req DELETE "/api/userCertificates/$_old_id" "$_unifi_body")"
      if [ "$_code" != "200" ] && [ "$_code" != "204" ]; then
        _info "Could not delete $_old_id (HTTP $_code), continuing."
      fi
    done
  fi

  _unifi_os_cleanup
  return $_unifi_rc
}
