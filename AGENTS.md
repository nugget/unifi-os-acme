# AGENTS.md

unifi-os-acme issues a Let's Encrypt certificate over DNS-01 and installs it on
a UniFi OS console, then keeps it renewed. It is two acme.sh plugins plus an
entrypoint that turns environment variables into an acme.sh invocation. There
is no application code — the whole project is POSIX shell, and the base image
does the ACME protocol work.

## Build & Test

```bash
just ci      # shellcheck + integration tests. Run before every push.
just test    # integration tests only
just lint    # shellcheck only
just build   # local image
```

`just ci` must pass locally before pushing. Both commands run in containers;
nothing needs installing beyond Docker and just.

## Layout

| Path | |
|---|---|
| `deploy/unifi_os.sh` | acme.sh deploy hook. Installs the cert on the console. |
| `dnsapi/dns_allns.sh` | acme.sh DNS provider. Wraps a real provider, gates on all authoritative nameservers. |
| `entrypoint.sh` | Env vars in, `acme.sh --issue` and the renewal daemon out. |
| `healthcheck.sh` | Answers "is the certificate doing its job", for the image's HEALTHCHECK. |
| `test/run.sh` | The whole suite. Mock DNS + mock console, no network deps. |

## Conventions

- **POSIX sh** in everything shipped in the image. The base image has no bash.
  `test/run.sh` is bash and runs on the host.
- **Clean at `shellcheck --severity=warning`.** Where word splitting is
  deliberate, say so with a `# shellcheck disable=` and a reason.
- **acme.sh idiom.** The plugins are sourced into acme.sh and use its helpers
  (`_info`, `_err`, `_debug`, `_getdeployconf`, `_saveaccountconf_mutable`)
  rather than reimplementing them. Follow the naming its hook loader expects:
  `dns_<name>_add` / `_rm`, `<name>_deploy`.
- **Every knob is an environment variable**, documented in `.env.example` and
  in the README table. No site-specific defaults — this runs on other people's
  networks.
- **Conventional commits**: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
  `chore:`.

## The two things that matter

**The gate must fail closed.** If `dns_allns` cannot confirm every nameserver
has the record, it returns non-zero, which aborts issuance before the CA is
asked to validate. That turns a slow zone into a retry instead of a failed
validation against the rate limit. Do not "helpfully" let it proceed on a
timeout.

**The deploy hook must not strand the console.** It verifies by TLS handshake
that the console is serving the new certificate before deleting the one it
replaced, and only ever deletes entries carrying its own name prefix. A change
that deletes first, or that trusts the API's success response instead of
checking what is actually served, can leave someone locked out of their own
network's UI. Both behaviours have tests; keep them.

## Testing notes

`test/mock_dns.py` is a ~90-line authoritative nameserver that answers NS and
TXT and takes a `PUBLISH_AFTER` delay. That delay is the whole point: it
reproduces the partial-propagation race the gate exists to fix, hermetically.

`test/mock_unifi.py` stands in for `unifi-core`. It enforces the session cookie
and CSRF header, records the request sequence, and reloads its own TLS listener
on activation so the hook's fingerprint verification is exercised for real. It
also carries a hand-uploaded certificate the hook must leave alone.

## Health

The healthcheck deliberately does not test liveness. The renewal daemon is the
container's main process, so its death already exits the container; what needs
checking is the outcome, which fails silently. Keep it credential-free — the
console check is a bare TLS handshake — so it stays safe to run every 15
minutes.

## Contributing

- No direct pushes to `main` — branch and PR.
- One logical change per PR.
- Update `.env.example` and the README table in the same PR as any new knob.
