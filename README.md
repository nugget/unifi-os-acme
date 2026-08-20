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

Set `ACME_SERVER=letsencrypt_test` while you get it working. The staging CA
issues untrusted certificates but has far looser rate limits, so a
misconfiguration costs you nothing.

Your DNS provider's credentials are named by acme.sh (`CF_Token`,
`LINODE_V4_API_KEY`, `AWS_ACCESS_KEY_ID`, …). Put them straight into `.env`;
the whole file is passed through.

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
| `RUN_ONCE` | `0` | Issue/renew once and exit, for external schedulers. |
| `ACME_EXTRA_ARGS` | | Appended to `acme.sh --issue`. |

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
acme.sh --issue -d unifi.example.com --dns dns_allns --dnssleep 1 \
        --deploy-hook unifi_os
```

`dns_allns` is useful on its own, with no UniFi involved, for any provider
whose nameservers converge slowly.

## Development

```bash
just ci      # shellcheck + integration tests
just test    # integration tests only
just build   # local image
just push    # multi-arch image to ghcr.io (not yet published)
```

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
