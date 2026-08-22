# acme.sh, plus two plugins:
#   deploy/unifi_os.sh   installs the certificate on a UniFi OS console
#   dnsapi/dns_allns.sh  gates DNS-01 on every authoritative nameserver
#
# The base is pinned by digest, not just by tag. This container can take a
# console's web UI offline if a future acme.sh release changes hook semantics,
# so moving to a new base should be a deliberate commit rather than whatever
# the tag happened to point at on build day. AUTO_UPGRADE is off for the same
# reason; see docker-compose.yml.
#
# Base: neilpang/acme.sh:3.1.4
FROM neilpang/acme.sh@sha256:08bad323dd6537ea2caba64260ef6e70e96057c4d9214afb9c07861db26653d9

# acme.sh finds hooks under $_SCRIPT_HOME/{deploy,dnsapi}, which is /acmebin in
# this image. dig, which dns_allns needs, ships in the base image already.
COPY deploy/unifi_os.sh /acmebin/deploy/unifi_os.sh
COPY dnsapi/dns_allns.sh /acmebin/dnsapi/dns_allns.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod 0644 /acmebin/deploy/unifi_os.sh /acmebin/dnsapi/dns_allns.sh \
  && chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []

# start-period covers a first issuance that has to wait out DNS propagation:
# the gate's own default timeout is 30 minutes, and failures during the start
# period do not count against the container. The interval is what decides how
# quickly a certificate replaced on the console gets noticed.
HEALTHCHECK --interval=15m --timeout=30s --start-period=40m --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

# Declared last so a metadata-only change does not invalidate the layer cache.
#
# These are not optional decoration: without them the image silently inherits
# the base image's OCI labels and claims to be acme.sh, pointing registries and
# tooling at acme.sh's repository, revision, and version instead of ours.
ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=1970-01-01T00:00:00Z
LABEL org.opencontainers.image.title="unifi-os-acme" \
      org.opencontainers.image.description="Maintains a valid certificate chain on a UniFi OS console, with a DNS-01 propagation gate that waits on every authoritative nameserver." \
      org.opencontainers.image.source="https://github.com/nugget/unifi-os-acme" \
      org.opencontainers.image.url="https://github.com/nugget/unifi-os-acme" \
      org.opencontainers.image.documentation="https://github.com/nugget/unifi-os-acme#readme" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.base.name="docker.io/neilpang/acme.sh:3.1.4" \
      org.opencontainers.image.base.digest="sha256:08bad323dd6537ea2caba64260ef6e70e96057c4d9214afb9c07861db26653d9"
