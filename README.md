# unifi-os-acme

Maintains a valid certificate chain on a UniFi OS console.

It runs as an ordinary container elsewhere on your network. Nothing is
installed on the console and no SSH access to it is required — certificates are
obtained from Let's Encrypt over DNS-01 and installed through the same
undocumented API endpoints the console's own dashboard uses. The operator
surface is a `.env` file and `docker compose up -d`.

UniFi OS consoles ship with a self-signed `unifi.local` certificate and have no
built-in ACME client. You can upload a certificate by hand through
**Control Plane → Console → Certificates**, but nothing renews it.

```sh
# .env
ACME_DOMAINS=unifi.example.com
ACME_EMAIL=you@example.com
ACME_DNS_PROVIDER=dns_cf
CF_Token=your-cloudflare-token
DEPLOY_UNIFI_OS_USER=acme
DEPLOY_UNIFI_OS_PASSWORD=the-password
```

```bash
docker compose up -d
```

## What it does

1. Issues a certificate over **DNS-01**, using any of [acme.sh's 150+ DNS
   providers](https://github.com/acmesh-official/acme.sh/wiki/dnsapi).
2. Waits until **every authoritative nameserver** for your zone actually serves
   the challenge record before asking the CA to validate. See
   [The propagation gate](#the-propagation-gate) — this is the part that makes
   renewals stop failing intermittently.
3. Installs it on the console over the `unifi-core` API, activates it, verifies
   by TLS handshake that the console is really serving it, and only then removes
   the certificate it replaced.
4. Stays up and repeats every 60 days.

One certificate covers the console and the Network application it proxies.

## Requirements

- A **UniFi OS console**: Dream Machine / Pro / SE / Router, Cloud Key Gen2+,
  UNVR, EFG, UXG, and similar. UniFi OS 4.1 or newer.
- A domain whose DNS you can automate.
- A console admin with **Account Type: Local Access Only** and **MFA disabled**.
  A Ubiquiti SSO account cannot authenticate against the local API.

> **Not for the self-hosted UniFi Network Application.** That one keeps its
> certificate in a Java keystore; use acme.sh's built-in
> [`unifi` deploy hook](https://github.com/acmesh-official/acme.sh/wiki/deployhooks#3-deploy-the-cert-to-unifi-server)
> instead. This project is for consoles running UniFi OS.

## Quick start

```bash
git clone https://github.com/nugget/unifi-os-acme
cd unifi-os-acme
cp .env.example .env
$EDITOR .env
docker compose up -d && docker compose logs -f
```

`docker-compose.yml` pulls `ghcr.io/nugget/unifi-os-acme:latest`; nothing is
built locally. To update, `docker compose pull && docker compose up -d` — compose
will not re-pull on its own, so moving to a new release stays deliberate. For a
local build, run `just build` and point `image:` at `unifi-os-acme:local`.

Set `ACME_SERVER=letsencrypt_test` while you get it working. The staging CA
issues untrusted certificates but has far looser rate limits, so a
misconfiguration costs you nothing.

Your DNS provider's credentials are named by acme.sh (`CF_Token`,
`LINODE_V4_API_KEY`, `AWS_ACCESS_KEY_ID`, …). Put them straight into `.env`;
the whole file is passed through.

## Portainer

Portainer does not create a `.env`. It writes the stack's variables to
`stack.env` in its own stack directory and hands them to the compose process,
which makes them available for interpolation and for named passthrough — but
**compose only passes variables it names**. That is why `docker-compose.yml`
carries an explicit `environment:` list rather than relying on `env_file`.

1. **Stacks → Add stack → Web editor**, paste `docker-compose.yml`.
2. Add your settings under **Environment variables** — the same names as
   `.env.example`, including your DNS provider's credentials.
3. Deploy.

`env_file` is still declared, marked `required: false`, so a command-line
deployment can keep using `.env` and Portainer does not fail for the lack of
one.

If your DNS provider's credentials are not in the `environment:` list, add
their names to it. A bare name passes the variable through when set and leaves
it unset otherwise, so unused entries cost nothing and never become empty
strings.

## Configuration

Every knob is an environment variable. Full annotated list in
[.env.example](.env.example).

| Variable | Default | |
|---|---|---|
| `ACME_DOMAINS` | *required* | Names on the certificate. First is primary. |
| `ACME_EMAIL` | *required* | ACME account contact. |
| `ACME_DNS_PROVIDER` | *required* | acme.sh DNS provider, e.g. `dns_cf`. |
| `DEPLOY_UNIFI_OS_USER` | *required* | Local-only console admin. |
| `DEPLOY_UNIFI_OS_PASSWORD` | *required* | Its password. |
| `DEPLOY_UNIFI_OS_HOST` | primary domain | Console address; may include `:port`. |
| `ACME_SERVER` | `letsencrypt` | Or `letsencrypt_test`, `zerossl`, `buypass`, `google`. |
| `ACME_KEYLENGTH` | `2048` | `ec-256` also works on current UniFi OS. |
| `ACME_NS_GATE` | `1` | The propagation gate. |
| `ALLNS_TIMEOUT` | `1800` | Seconds to wait for full propagation. |
| `ALLNS_INTERVAL` | `20` | Seconds between polls. |
| `ALLNS_SERVERS` | discovered | Override the nameserver list. |
| `ALLNS_RESOLVER` | system | Resolver used for zone/NS discovery. |
| `DEPLOY_UNIFI_OS_NAME` | `acme.sh` | Name prefix for uploaded certificates. |
| `DEPLOY_UNIFI_OS_KEEP_OLD` | `0` | `1` keeps superseded certificates. |
| `DEPLOY_UNIFI_OS_VERIFY` | `0` | Verify the console's own TLS certificate. |
| `HEALTHCHECK_MIN_DAYS` | `21` | Report unhealthy under this many days to expiry. |
| `HEALTHCHECK_CHECK_CONSOLE` | `1` | Also check the console is serving our certificate. |
| `RUN_ONCE` | `0` | Issue/renew once and exit, for external schedulers. |
| `ACME_EXTRA_ARGS` | | Appended to `acme.sh --issue`. |

## The image

Published to `ghcr.io/nugget/unifi-os-acme` for `linux/amd64`, `linux/arm64`,
and `linux/arm/v7`, built by GitHub Actions with build provenance and an SBOM
attached.

`latest` moves only on a release tag; pushes to `main` publish `main` and
`sha-<short>`. That is deliberate — a bad image here can leave you unable to
reach your console's web UI, so following a moving tag is opt-in. To pin:

```bash
docker pull ghcr.io/nugget/unifi-os-acme:1.0.0
# or by digest, which is what a pin really means
docker pull ghcr.io/nugget/unifi-os-acme@sha256:...
```

The image carries full [OCI annotations](https://github.com/opencontainers/image-spec/blob/main/annotations.md)
— title, description, source, licenses, version, revision, and the base image
it was built from, by name *and* digest:

```bash
docker image inspect ghcr.io/nugget/unifi-os-acme:latest \
  --format '{{json .Config.Labels}}' | jq
```

The base itself is pinned by digest in the `Dockerfile`, so a rebuild of an old
commit produces the same thing rather than whatever the upstream tag points at
today. Verify provenance with:

```bash
gh attestation verify oci://ghcr.io/nugget/unifi-os-acme:latest --owner nugget
```

## The propagation gate

This is the interesting part, and it applies well beyond UniFi.

Most ACME clients check DNS-01 propagation by querying a **recursive resolver**
— acme.sh does it over DNS-over-HTTPS, lego waits a fixed `delayBeforeCheck`
and then does much the same. A recursive resolver follows whichever
authoritative server it happens to pick.

If your DNS provider publishes zone changes to its nameservers at *different
times* — Linode is a well-known example — then that check goes green as soon as
**one** nameserver has the record. The CA then queries the authoritative set
itself, may land on one that is still lagging, and validation fails.

The symptom is renewals that fail *intermittently*, for no reason you can
reproduce. Raising the delay makes it rarer without fixing it, because it is a
race, not a duration.

So this container does not use your DNS provider directly. It uses
`dns_allns`, a wrapper that adds the record with the real provider and then
asks **every** authoritative nameserver for the zone, one at a time, until they
all have it:

```
[info] Waiting for _acme-challenge.unifi.example.com on every authoritative
       nameserver: ns1.example.net ns2.example.net ns3.example.net
[info] Still waiting on: ns2.example.net ns3.example.net
[info] Still waiting on: ns3.example.net
[info] All nameservers are serving the challenge record.
```

The nameservers are discovered from the zone's `NS` records — walking up from
the challenge name, so a delegated subzone wins over its parent. Override with
`ALLNS_SERVERS` if discovery gets the wrong answer, which mostly happens behind
a split-horizon resolver.

If the gate times out it **fails the DNS hook**, which aborts issuance *before*
the CA is asked to validate. A slow zone therefore costs you a retry, not a
failed validation against your rate limit. Renewal starts 30 days before
expiry and retries four times a day, so there are roughly 120 attempts in hand.

Set `ACME_NS_GATE=0` to turn it off and use acme.sh's normal behaviour.

## How the certificate gets installed

UniFi's documented API surfaces — the Site Manager cloud API and the local
Network Integration API — **do not cover certificates**. What does exist is the
API the Control Plane → Console → Certificates page itself drives:

```
POST   /api/auth/login                          session cookie + CSRF token
GET    /api/userCertificates                    what is installed now
POST   /api/userCertificates                    upload {name, cert, key}
PUT    /api/userCertificates/{id}/status        {"active": true}
DELETE /api/userCertificates/{id}               remove the superseded one
```

This is unversioned and undocumented, so a firmware update could change it.
That risk is why the deploy hook is careful:

- **Idempotent.** Compares the local certificate's SHA-1 against the active
  one and does nothing if they match.
- **Verifies before pruning.** After activation it opens a real TLS connection
  to the console and confirms the fingerprint being served. If the console
  activated the certificate but is not serving it, the hook fails loudly and
  deletes **nothing**, so the previous certificate is still there to reactivate
  from the UI.
- **Only prunes its own.** Deletes only entries whose name carries
  `DEPLOY_UNIFI_OS_NAME`. Your hand-uploaded certificates are untouched.

## Health

The container carries a healthcheck, so `docker ps` and anything watching
container health can tell you whether the certificate is actually doing its
job — not merely whether a process is running.

Liveness is not the interesting question here: the renewal daemon is the
container's main process, so if it dies the container exits and you already
know. What fails *silently* is the outcome. Three things can be wrong while the
container looks perfectly fine, and each is checked directly:

| Condition | Reported as |
|---|---|
| Issuance never succeeded | `no certificate has been issued for <name>` |
| Renewals failing, expiry closing in | `expires <date>, under <HEALTHCHECK_MIN_DAYS>d away; renewals are failing` |
| Console stopped serving our certificate | `<host> is serving <fp>, expected <fp>` |
| Console unreachable | `<host> did not complete a TLS handshake` |

The third one is worth having. A firmware update, another tool, or someone in
the UI can replace the certificate on the console, and nothing in the ACME
world would notice — the certificate is still valid, still renewed, just not
the one being served. The check is a plain TLS handshake; no credentials
involved.

```console
$ docker inspect --format '{{.State.Health.Status}}' unifi-os-acme
healthy
$ just health
healthy: unifi.example.com is serving the certificate for unifi.example.com
```

Renewal begins 30 days before expiry, so crossing `HEALTHCHECK_MIN_DAYS`
(default 21) means renewals have been failing for over a week. The start period
is 40 minutes, which covers a first issuance that has to wait out DNS
propagation.

Note that Docker does not restart unhealthy containers on its own — this is a
signal for you or your monitoring, not an action. Set
`HEALTHCHECK_CHECK_CONSOLE=0` if the console is not reachable from the
container between renewals.

## Troubleshooting

**`Login failed (HTTP 401)`** — the account is not Local Access Only, or has
MFA enabled, or the password is wrong.

**`Could not reach <host>`** — the container cannot resolve or route to the
console. If the name only exists on an internal DNS view, pin it with
`extra_hosts` in `docker-compose.yml`. DNS-01 does not need the console's name
to resolve publicly, so this affects only the install step.

**`Timed out … Still missing the record: <ns>`** — that nameserver had not
published the challenge record. Raise `ALLNS_TIMEOUT`; the renewal retries on
its own regardless.

**`is still serving <fingerprint>, expected <fingerprint>`** — the console
accepted and activated the certificate but kept serving the old one. Nothing
was deleted. Check the console's UI; this usually means `unifi-core` did not
reload.

Use the container as an acme.sh CLI for anything else:

```bash
docker compose run --rm acme --list
```

## Using the plugins without the container

Both files are ordinary acme.sh plugins. Drop them into your acme.sh
installation and they work with any acme.sh setup:

```bash
cp deploy/unifi_os.sh   ~/.acme.sh/deploy/
cp dnsapi/dns_allns.sh  ~/.acme.sh/dnsapi/

export ALLNS_PROVIDER=dns_cf
export DEPLOY_UNIFI_OS_USER=acme DEPLOY_UNIFI_OS_PASSWORD=...
acme.sh --issue  -d unifi.example.com --dns dns_allns --dnssleep 1
acme.sh --deploy -d unifi.example.com --deploy-hook unifi_os
```

The second command is not optional, and it is not the same as passing
`--deploy-hook` to `--issue`. acme.sh accepts that flag on `--issue` and
silently ignores it: the flag is read only by the deploy command, and the
post-issue deploy fires on `Le_DeployHook` in the domain config, which only an
actual deploy writes. `--issue --deploy-hook x` therefore issues a certificate,
installs nothing, and leaves renewals with nothing to run either. Running
`--deploy` once installs it and registers the hook, after which renewals deploy
on their own.

`dns_allns` is useful on its own, with no UniFi involved, for any provider
whose nameservers converge slowly.

## Development

A bare `just` lists what is available:

```console
$ just
Available recipes:
    default         # Show available recipes.
    ci              # Full gate: lint + integration tests. Run before every push.
    lint            # Shellcheck every script, in a container so there is nothing to install.
    test            # Integration tests: mock nameservers, a mock console, no real CA.
    build           # Build the image locally, with real OCI labels taken from git.
    labels          # Print the built image's OCI labels.
    health          # Run the healthcheck against a running container.
    release version # Cut a signed release tag, e.g. `just release 1.0.0`.
    push tag="edge" # Build and push a multi-arch image to GHCR by hand.
```

Recipe arguments are **positional**: `just push 1.2.3`, not `just push tag=1.2.3`.
The `tag="edge"` in the listing is just showing you the default value.

Releases go through `just release 1.0.0`. It checks the tree is clean and level
with `origin/main`, pushes a signed `v1.0.0` tag, waits for CI to publish the
image, and then creates the GitHub release with generated notes. Waiting first
means a release object never points at an image that failed to build; pass
`SKIP_IMAGE_WAIT=1` to publish without waiting. CI publishes `1.0.0`, `1.0`, and
`latest` with provenance and an SBOM; a prerelease (`1.0.0-rc.1`) publishes only
itself and does not move `latest`.

Pushing images by hand is possible but carries neither provenance nor an SBOM,
which is why `just push latest` refuses without an explicit override.

The test suite stands up mock authoritative nameservers and a mock
`unifi-core` — which enforces the session cookie and CSRF header, and swaps its
own TLS certificate on activation — on a throwaway Docker network. It never
touches a real CA, a real console, or real DNS, so it runs anywhere and is
safe in CI.

It covers the partial-propagation case directly: one mock nameserver publishes
the record immediately, another is told to lag, and the gate is asserted to
wait rather than proceed.

## License

GPL-3.0, matching [acme.sh](https://github.com/acmesh-official/acme.sh), into
which both plugins are sourced.
