# acme.sh, plus two plugins:
#   deploy/unifi_os.sh   installs the certificate on a UniFi OS console
#   dnsapi/dns_allns.sh  gates DNS-01 on every authoritative nameserver
#
# The version is pinned deliberately. This container can take a console's web
# UI offline if a future acme.sh release changes hook semantics, so upgrading
# should be a decision rather than a side effect. AUTO_UPGRADE is off for the
# same reason; see docker-compose.yml.
FROM neilpang/acme.sh:3.1.4

# acme.sh finds hooks under $_SCRIPT_HOME/{deploy,dnsapi}, which is /acmebin in
# this image. dig, which dns_allns needs, ships in the base image already.
COPY deploy/unifi_os.sh /acmebin/deploy/unifi_os.sh
COPY dnsapi/dns_allns.sh /acmebin/dnsapi/dns_allns.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0644 /acmebin/deploy/unifi_os.sh /acmebin/dnsapi/dns_allns.sh \
  && chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
