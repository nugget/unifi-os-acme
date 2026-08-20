"""A minimal authoritative DNS server, just enough to test the propagation gate.

Answers NS queries for a zone and TXT queries for one name. The interesting
knob is PUBLISH_AFTER: this server pretends not to have the TXT record until
that many seconds have passed, which is exactly how a real provider's
nameservers behave while a zone change is still rolling out.

Env:
  ZONE           zone this server is authoritative for
  NS_NAMES       space separated NS records to return for ZONE
  TXT_NAME       name that carries the challenge record
  TXT_VALUE      the challenge value
  PUBLISH_AFTER  seconds before TXT_VALUE becomes visible (default 0)
  NEVER          set to 1 to never publish TXT_VALUE
"""
import os
import socket
import struct
import time

ZONE = os.environ.get("ZONE", "example.test").lower().rstrip(".")
NS_NAMES = os.environ.get("NS_NAMES", "").split()
TXT_NAME = os.environ.get("TXT_NAME", "").lower().rstrip(".")
TXT_VALUE = os.environ.get("TXT_VALUE", "")
PUBLISH_AFTER = int(os.environ.get("PUBLISH_AFTER", "0"))
NEVER = os.environ.get("NEVER", "0") == "1"

STARTED = time.time()
TYPE_NS, TYPE_TXT = 2, 16


def encode_name(name):
    out = b""
    for label in name.rstrip(".").split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def parse_question(data):
    i = 12
    labels = []
    while data[i] != 0:
        n = data[i]
        labels.append(data[i + 1 : i + 1 + n])
        i += 1 + n
    i += 1
    qname = b".".join(labels).decode().lower()
    qtype, _qclass = struct.unpack("!HH", data[i : i + 4])
    return qname, qtype, data[12 : i + 4]


def published():
    if NEVER:
        return False
    return time.time() - STARTED >= PUBLISH_AFTER


def answers_for(qname, qtype):
    rrs = []
    if qtype == TYPE_NS and qname == ZONE:
        for ns in NS_NAMES:
            rrs.append((TYPE_NS, encode_name(ns)))
    elif qtype == TYPE_TXT and qname == TXT_NAME and published():
        payload = TXT_VALUE.encode()
        rrs.append((TYPE_TXT, bytes([len(payload)]) + payload))
    return rrs


def build_response(data):
    qname, qtype, question = parse_question(data)
    rrs = answers_for(qname, qtype)

    # QR + AA, NOERROR. An empty answer section is a truthful "not here yet".
    header = struct.pack("!HHHHHH", struct.unpack("!H", data[:2])[0], 0x8400, 1, len(rrs), 0, 0)
    body = question
    for rtype, rdata in rrs:
        body += b"\xc0\x0c" + struct.pack("!HHIH", rtype, 1, 60, len(rdata)) + rdata
    return header + body


sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", 53))
print(f"mock dns: zone={ZONE} txt={TXT_NAME} publish_after={PUBLISH_AFTER} never={NEVER}", flush=True)
while True:
    try:
        data, addr = sock.recvfrom(512)
        sock.sendto(build_response(data), addr)
    except Exception as exc:  # a malformed packet must not take the server down
        print(f"mock dns error: {exc}", flush=True)
