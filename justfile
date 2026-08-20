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
    docker build \
      --build-arg VERSION="$(git describe --tags --always --dirty)" \
      --build-arg REVISION="$(git rev-parse HEAD)" \
      --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      -t unifi-os-acme:local .

# Show the image's OCI labels. Without the LABEL block in the Dockerfile these
# would be inherited from the base image and would claim to be acme.sh.
labels: build
    @docker image inspect unifi-os-acme:local | python3 -c "import json,sys; [print(k+'='+v) for k,v in sorted(json.load(sys.stdin)[0]['Config']['Labels'].items())]"

# Build and push a multi-arch image to GHCR by hand. CI does this on push to
# main and on release tags; this is for when you need it locally.
# Requires: docker login ghcr.io
push tag="edge":
    docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 \
      --build-arg VERSION="{{ tag }}" \
      --build-arg REVISION="$(git rev-parse HEAD)" \
      --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      -t ghcr.io/nugget/unifi-os-acme:{{ tag }} --push .
