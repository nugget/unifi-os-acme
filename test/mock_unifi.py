"""Minimal stand-in for unifi-core's certificate API, for testing the hook."""
import hashlib, json, os, ssl, tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CERTS = "/certs"
TOKEN = "sess-abc123"
CSRF = "csrf-xyz789"

def fp(pem_path):
    """SHA-1 over the DER of the first certificate in a PEM file."""
    import base64
    pem = open(pem_path).read()
    b = pem.split("-----BEGIN CERTIFICATE-----")[1].split("-----END CERTIFICATE-----")[0]
    return hashlib.sha1(base64.b64decode("".join(b.split()))).hexdigest()

state = {
    "certs": [
        # the stock self-signed cert, currently active
        {"id": "stock-1", "name": "Default", "active": True,
         "fingerprint": fp(f"{CERTS}/console.crt")},
        # a stale cert from a previous run of this hook - should be pruned
        {"id": "old-acme", "name": "acme.sh-20260101000000", "active": False,
         "fingerprint": "dead" * 10},
        # a hand-uploaded cert - must be left alone
        {"id": "manual-1", "name": "uploaded-by-hand", "active": False,
         "fingerprint": "beef" * 10},
    ],
    "next": 0,
}
ctx = None
log = []

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body=None, headers=None):
        raw = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def _authed(self):
        return TOKEN in self.headers.get("Cookie", "")

    def _csrf_ok(self):
        return self.headers.get("x-csrf-token") == CSRF

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def log_message(self, *a):
        pass

    def do_GET(self):
        log.append(("GET", self.path))
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        if self.path == "/api/userCertificates":
            return self._send(200, [{k: v for k, v in c.items()} for c in state["certs"]])
        self._send(404, {"error": "not found"})

    def do_POST(self):
        log.append(("POST", self.path))
        if self.path == "/api/auth/login":
            b = self._body()
            if b.get("username") != "acme" or b.get("password") != "s3cret":
                return self._send(401, {"error": "bad creds"})
            return self._send(200, {"ok": True}, {
                "Set-Cookie": f"TOKEN={TOKEN}; Path=/; HttpOnly",
                "X-CSRF-Token": CSRF,
            })
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        if not self._csrf_ok():
            return self._send(403, {"error": "csrf"})
        if self.path == "/api/auth/logout":
            return self._send(200, {"ok": True})
        if self.path == "/api/userCertificates":
            b = self._body()
            for field in ("name", "cert", "key"):
                if not b.get(field):
                    return self._send(400, {"error": f"missing {field}"})
            d = tempfile.mkdtemp()
            crt, key = os.path.join(d, "c.pem"), os.path.join(d, "k.pem")
            open(crt, "w").write(b["cert"])
            open(key, "w").write(b["key"])
            # unifi-core wants leaf + intermediates, no root; assert we got a chain
            n_certs = b["cert"].count("BEGIN CERTIFICATE")
            state["next"] += 1
            cid = f"new-{state['next']}"
            state["certs"].append({"id": cid, "name": b["name"], "active": False,
                                   "fingerprint": fp(crt), "_files": (crt, key),
                                   "_chain_len": n_certs})
            dump()
            return self._send(200, {"id": cid, "name": b["name"]})
        self._send(404, {"error": "not found"})

    def do_PUT(self):
        log.append(("PUT", self.path))
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        if not self._csrf_ok():
            return self._send(403, {"error": "csrf"})
        if self.path.startswith("/api/userCertificates/") and self.path.endswith("/status"):
            cid = self.path.split("/")[3]
            b = self._body()
            for c in state["certs"]:
                if c["id"] == cid and b.get("active"):
                    for other in state["certs"]:
                        other["active"] = False
                    c["active"] = True
                    if "_files" in c:
                        # what unifi-core does: reload nginx with the new cert
                        ctx.load_cert_chain(*c["_files"])
                    dump()
                    return self._send(200, {"ok": True})
            return self._send(404, {"error": "no such cert"})
        self._send(404, {"error": "not found"})

    def do_DELETE(self):
        log.append(("DELETE", self.path))
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        if not self._csrf_ok():
            return self._send(403, {"error": "csrf"})
        cid = self.path.rsplit("/", 1)[-1]
        before = len(state["certs"])
        state["certs"][:] = [c for c in state["certs"] if c["id"] != cid]
        if len(state["certs"]) == before:
            return self._send(404, {"error": "no such cert"})
        dump()
        self._send(200, {"ok": True})

def dump():
    """Snapshot state for the test harness. Called after every mutation so a
    reader never sees a stale view."""
    if True:
        open("/certs/state.json", "w").write(json.dumps(
            {"certs": [{k: v for k, v in c.items() if not k.startswith("_")}
                       | {"chain_len": c.get("_chain_len")} for c in state["certs"]],
             "log": log}, indent=2))

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(f"{CERTS}/console.crt", f"{CERTS}/console.key")
srv = ThreadingHTTPServer(("0.0.0.0", 443), H)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
dump()
print("mock unifi-core listening on 443", flush=True)
srv.serve_forever()
