# A bare `just` lists these rather than starting a container build.
# Only the LAST comment line before a recipe becomes its summary in --list.

# Show available recipes.
default:
    @just --list --unsorted

# Full gate: lint + integration tests. Run before every push.
ci: lint test
    @echo "ci ok"

# Shellcheck every script and lint the workflows, in containers so there is
# nothing to install.
#
# Lint every script and workflow.
lint:
    docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
      --shell=sh --severity=warning deploy/unifi_os.sh dnsapi/dns_allns.sh \
      entrypoint.sh healthcheck.sh test/gate_harness.sh
    docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
      --shell=bash --severity=warning test/run.sh
    docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color

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

# Cut a signed release tag. CI builds from it and publishes `latest` plus the
# semver tags, with provenance and an SBOM attached. This is how `latest` is
# meant to move.
#
# Cut a signed release tag, e.g. `just release 1.0.0`.
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    v='{{ version }}'
    # Build metadata is valid semver but cannot be an image tag: '+' is not in
    # the set Docker allows, so v1.2.3+build would tag the git repo and then
    # fail in the registry.
    if [[ "$v" == *+* ]]; then
      echo "error: '$v' carries build metadata, which cannot appear in an image tag." >&2
      exit 1
    fi
    # MAJOR.MINOR.PATCH with an optional prerelease. Rejects 1.2.3.4 and 01.2.3.
    if [[ ! "$v" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]]; then
      echo "error: '$v' is not a semver version. Try: just release 1.0.0" >&2
      exit 1
    fi
    [[ -z "$(git status --porcelain)" ]] || {
      echo "error: working tree is dirty; commit or stash first." >&2; exit 1; }
    [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || {
      echo "error: releases are cut from main." >&2; exit 1; }
    git fetch -q origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || {
      echo "error: local main differs from origin/main; pull or push first." >&2; exit 1; }
    git tag -s "v$v" -m "v$v"
    git push origin "v$v"
    if [[ "$v" == *-* ]]; then
      echo "pushed v$v - CI will publish ghcr.io/nugget/unifi-os-acme:$v"
      echo "(prerelease: latest and ${v%%-*} major.minor are deliberately not moved)"
    else
      echo "pushed v$v - CI will publish ghcr.io/nugget/unifi-os-acme: $v, ${v%.*}, latest"
    fi

# Arguments are POSITIONAL: `just push 1.2.3`, not `just push tag=1.2.3`.
# Prefer `just release` - images built here carry no provenance or SBOM,
# because those are produced by the CI build, not by docker buildx alone.
# Requires: docker login ghcr.io
#
# Build and push a multi-arch image to GHCR by hand.
push tag="edge":
    #!/usr/bin/env bash
    set -euo pipefail
    tag='{{ tag }}'
    if [[ "$tag" == *=* ]]; then
      echo "error: '$tag' looks like name=value, but just takes positional arguments." >&2
      echo "       Did you mean:  just push ${tag#*=}" >&2
      exit 1
    fi
    if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
      echo "error: '$tag' is not a valid image tag." >&2
      exit 1
    fi
    if [[ "$tag" == "latest" && "${ALLOW_LATEST:-0}" != "1" ]]; then
      echo "error: 'latest' is published by CI from a release tag, so it carries" >&2
      echo "       provenance and an SBOM. Pushing it here would replace that with" >&2
      echo "       an unattested image." >&2
      echo "       Release properly:  just release 1.0.0" >&2
      echo "       Override anyway:   ALLOW_LATEST=1 just push latest" >&2
      exit 1
    fi
    docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 \
      --build-arg VERSION="$tag" \
      --build-arg REVISION="$(git rev-parse HEAD)" \
      --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      -t "ghcr.io/nugget/unifi-os-acme:$tag" --push .
