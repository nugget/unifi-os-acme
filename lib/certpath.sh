#!/usr/bin/env sh
# shellcheck disable=SC2034  # CERT_* are consumed by the scripts that source this
# Which certificate does acme.sh hold for this domain?
#
# acme.sh keeps EC certificates in <domain>_ecc and RSA ones in <domain>, and
# both can exist at once if the key type was ever changed. The directory alone
# is not the answer: it survives a switch back, and it can be left behind empty
# by a failed issuance. So look for the certificate file, and when both exist
# let ACME_KEYLENGTH break the tie, since that is the one a fresh issuance
# would write.
#
# Sourced by entrypoint.sh and healthcheck.sh so the two cannot disagree about
# which certificate is the live one - if they did, the healthcheck would call a
# correctly deployed console unhealthy.
#
# Sets CERT_FILE, CERT_KEY, CERT_ECC_FLAG. Returns 1 when there is no
# certificate at all.
select_cert() {
  _sc_domain="$1"
  _sc_home="${LE_CONFIG_HOME:-/acme.sh}"
  _sc_rsa_dir="$_sc_home/$_sc_domain"
  _sc_ecc_dir="$_sc_home/${_sc_domain}_ecc"
  _sc_rsa="$_sc_rsa_dir/$_sc_domain.cer"
  _sc_ecc="$_sc_ecc_dir/$_sc_domain.cer"

  if [ -f "$_sc_rsa" ] && [ -f "$_sc_ecc" ]; then
    case "${ACME_KEYLENGTH:-2048}" in
    ec-*) _sc_pick=ecc ;;
    *) _sc_pick=rsa ;;
    esac
  elif [ -f "$_sc_ecc" ]; then
    _sc_pick=ecc
  elif [ -f "$_sc_rsa" ]; then
    _sc_pick=rsa
  else
    return 1
  fi

  if [ "$_sc_pick" = ecc ]; then
    CERT_FILE="$_sc_ecc"
    CERT_KEY="$_sc_ecc_dir/$_sc_domain.key"
    CERT_ECC_FLAG="--ecc"
  else
    CERT_FILE="$_sc_rsa"
    CERT_KEY="$_sc_rsa_dir/$_sc_domain.key"
    CERT_ECC_FLAG=""
  fi
}
