# A bare `just` lists these rather than starting a container build.
# Only the LAST comment line before a recipe becomes its summary in --list.

# Show available recipes.
default:
    @just --list --unsorted

# Full gate: lint + integration tests. Run before every push.
ci: lint test
    @echo "ci ok"

# Shellcheck every script, in a container so there is nothing to install.
lint:
    docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
      --shell=sh --severity=warning deploy/unifi_os.sh dnsapi/dns_allns.sh \
      entrypoint.sh healthcheck.sh test/gate_harness.sh
    docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
      --shell=bash --severity=warning test/run.sh

# Integration tests: mock nameservers, a mock console, no real CA.
test:
    bash test/run.sh

# Build the image locally, with real OCI labels taken from git.
build:
    docker build \
      --build-arg VERSION="$(git describe --tags --always --dirty)" \
      --build-arg REVISION="$(git rev-parse HEAD)" \
      --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      -t unifi-os-acme:local .

# Print the built image's OCI labels. Without the Dockerfile's LABEL block
# these would be inherited from the base and would claim to be acme.sh.
#
# Print the built image's OCI labels.
labels: build
    @docker image inspect unifi-os-acme:local | python3 -c "import json,sys; [print(k+'='+v) for k,v in sorted(json.load(sys.stdin)[0]['Config']['Labels'].items())]"

# Run the healthcheck against a running container.
health:
    docker compose exec acme /usr/local/bin/healthcheck.sh

# CI publishes on push to main and on release tags; this is the manual path.
# Requires: docker login ghcr.io
#
# Build and push a multi-arch image to GHCR by hand.
push tag="edge":
    docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 \
      --build-arg VERSION="{{ tag }}" \
      --build-arg REVISION="$(git rev-parse HEAD)" \
      --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      -t ghcr.io/nugget/unifi-os-acme:{{ tag }} --push .
