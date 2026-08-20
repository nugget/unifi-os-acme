default: ci

# Full gate: lint then the integration suite. Run this before every push.
ci: lint test
    @echo "ci ok"

# Shellcheck everything, in a container so there is nothing to install.
lint:
    docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
      --shell=sh --severity=warning deploy/unifi_os.sh dnsapi/dns_allns.sh \
      entrypoint.sh test/gate_harness.sh
    docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
      --shell=bash --severity=warning test/run.sh

# Integration tests: mock nameservers, a mock console, no real CA.
test:
    bash test/run.sh

build:
    docker build -t unifi-os-acme:local .

# Build and push a multi-arch image to GHCR.
# Requires: docker login ghcr.io
push tag="latest":
    docker buildx build --platform linux/amd64,linux/arm64 \
      -t ghcr.io/nugget/unifi-os-acme:{{tag}} --push .
