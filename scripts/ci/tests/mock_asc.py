"""A tiny stand-in for the App Store Connect API, for scripts/ci/tests/run-tests.sh.

    python3 -I mock_asc.py <request-log.jsonl> <port-file>

Serves the requests asc-testflight.sh, asc-certificates.sh, and asc-development-certificate.sh make, records each one (method, path, query, body, and the
JWT's header and payload) as a JSON line, and reports processing as "not listed", then PROCESSING,
then VALID, so the script's polling is exercised. Never talks to Apple.
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

LOG, PORT_FILE = sys.argv[1], sys.argv[2]
APP_ID, BUILD_ID, GROUP_ID = "6700000001", "build-1", "group-1"
# An internal group with access to every build: App Store Connect refuses to add builds to it.
ALL_BUILDS_GROUP_ID = "group-all"
state = {"build_polls": 0}
# Builds that are already there, for asc-testflight.sh --find-build: version -> (processingState, uploadedDate).
UPLOADED = {
    "2001": ("VALID", "2026-10-24T13:20:00.000-07:00"),
    "2001.2": ("FAILED", "2026-10-24T21:00:00Z"),
    "3001": ("VALID", "2026-01-01T00:00:00Z"),
}


# Development certificates, ages relative to NOW (run-tests.sh passes the same DAYBOOK_NOW): two pages.
NOW = 1793000000


def expires_in(days):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000+0000", time.gmtime(NOW + days * 86400))


CERTIFICATES = [
    [("cert-fresh", "DEVELOPMENT", "Apple Development: Created via API", "Created via API", expires_in(360)),
     ("cert-old", "DEVELOPMENT", "Apple Development: Created via API", "Created via API", expires_in(200)),
     ("cert-person", "DEVELOPMENT", "Apple Development: Vlad Zaharia", "Vlad Zaharia", expires_in(10))],
    [("cert-old-mac", "MAC_APP_DEVELOPMENT", "Mac Development: Created via API", "Created via API", expires_in(100)),
     ("cert-dist", "DISTRIBUTION", "Apple Distribution: Created via API", "Created via API", expires_in(5))],
]


def issue_certificate(csr_pem):
    """An "Apple Development" certificate for the CSR's key, signed by a throwaway CA, as DER in base64."""
    with tempfile.TemporaryDirectory() as tmp:
        def run(*args):
            subprocess.run(["openssl", *args], check=True, capture_output=True, cwd=tmp)
        with open(os.path.join(tmp, "request.csr"), "w") as f:
            f.write(csr_pem)
        run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "2",
            "-subj", "/CN=Mock Apple WWDR")
        run("x509", "-req", "-in", "request.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "4242",
            "-days", "365", "-out", "certificate.pem",
            "-subj", "/UID=ABCDE12345/CN=Apple Development: Created via API (ABCDE12345)/OU=48H7CLBV8Y/O=Example/C=US")
        run("x509", "-in", "certificate.pem", "-outform", "DER", "-out", "certificate.cer")
        with open(os.path.join(tmp, "certificate.cer"), "rb") as f:
            return base64.b64encode(f.read()).decode()


def decode_segment(segment):
    return json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self):
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        auth = self.headers.get("Authorization", "")
        jwt = {}
        if auth.startswith("Bearer "):
            parts = auth[len("Bearer "):].split(".")
            jwt = {"header": decode_segment(parts[0]), "payload": decode_segment(parts[1]),
                   "signature_bytes": len(base64.urlsafe_b64decode(parts[2] + "=" * (-len(parts[2]) % 4)))}
        entry = {"method": self.command, "path": url.path, "query": parse_qs(url.query),
                 "body": json.loads(body) if body else None, "jwt": jwt}
        with open(LOG, "a") as log:
            log.write(json.dumps(entry) + "\n")
        return entry

    def do_GET(self):
        entry = self.record()
        path, query = entry["path"], entry["query"]
        if path == "/v1/apps":
            self.reply(200, {"data": [{"type": "apps", "id": APP_ID,
                                       "attributes": {"bundleId": query["filter[bundleId]"][0], "name": "Daybook"}}]})
        elif path == "/v1/builds" and query["filter[version]"][0] != "1057":
            wanted = query["filter[version]"][0].split(",")
            builds = [{"type": "builds", "id": f"build-{v}", "attributes": {
                "version": v, "processingState": UPLOADED[v][0], "uploadedDate": UPLOADED[v][1], "expired": False}}
                for v in wanted if v in UPLOADED]
            builds.sort(key=lambda b: b["id"], reverse=True)
            self.reply(200, {"data": builds})
        elif path == "/v1/builds":
            state["build_polls"] += 1
            if state["build_polls"] == 1:
                self.reply(200, {"data": []})
            else:
                processing = "PROCESSING" if state["build_polls"] == 2 else "VALID"
                self.reply(200, {"data": [{"type": "builds", "id": BUILD_ID, "attributes": {
                    "version": query["filter[version]"][0], "processingState": processing,
                    "usesNonExemptEncryption": False, "expired": False}}]})
        elif path == "/v1/certificates":
            page = int(query.get("cursor", ["0"])[0])
            body = {"data": [{"type": "certificates", "id": c[0], "attributes": {
                "certificateType": c[1], "name": c[2], "displayName": c[3], "serialNumber": c[0].upper(),
                "expirationDate": c[4]}} for c in CERTIFICATES[page]], "links": {}}
            if page + 1 < len(CERTIFICATES):
                body["links"]["next"] = f"http://{self.headers['Host']}/v1/certificates?cursor={page + 1}&limit=200"
            self.reply(200, body)
        elif path == f"/v1/builds/{BUILD_ID}/betaBuildLocalizations":
            self.reply(200, {"data": []})
        elif path == "/v1/betaGroups":
            name = query.get("filter[name]", ["?"])[0]
            groups = [{"type": "betaGroups", "id": GROUP_ID,
                       "attributes": {"name": "External testers", "isInternalGroup": False}},
                      {"type": "betaGroups", "id": ALL_BUILDS_GROUP_ID,
                       "attributes": {"name": "Daybook Internal", "isInternalGroup": True, "hasAccessToAllBuilds": True}}]
            self.reply(200, {"data": [g for g in groups if g["attributes"]["name"] == name]})
        else:
            self.reply(404, {"errors": [{"status": "404", "code": "NOT_FOUND", "title": "not mocked"}]})

    def do_POST(self):
        entry = self.record()
        path = entry["path"]
        if path == "/v1/betaBuildLocalizations":
            self.reply(201, {"data": {"type": "betaBuildLocalizations", "id": "loc-1"}})
        elif path == f"/v1/betaGroups/{GROUP_ID}/relationships/builds":
            self.reply(204)
        elif path == f"/v1/betaGroups/{ALL_BUILDS_GROUP_ID}/relationships/builds":
            self.reply(422, {"errors": [{"status": "422", "code": "ENTITY_UNPROCESSABLE",
                                         "title": "Builds cannot be assigned to this internal group."}]})
        elif path == "/v1/betaAppReviewSubmissions":
            self.reply(201, {"data": {"type": "betaAppReviewSubmissions", "id": "review-1"}})
        elif path == "/v1/certificates":
            attributes = entry["body"]["data"]["attributes"]
            if attributes.get("certificateType") != "DEVELOPMENT":
                self.reply(409, {"errors": [{"status": "409", "code": "ENTITY_ERROR", "title": "wrong type"}]})
                return
            self.reply(201, {"data": {"type": "certificates", "id": "cert-new", "attributes": {
                "certificateType": "DEVELOPMENT", "name": "Apple Development: Created via API",
                "displayName": "Created via API", "serialNumber": "1092", "expirationDate": expires_in(365),
                "certificateContent": issue_certificate(attributes["csrContent"])}}})
        else:
            self.reply(404, {"errors": [{"status": "404", "code": "NOT_FOUND", "title": "not mocked"}]})

    def do_DELETE(self):
        entry = self.record()
        if entry["path"].startswith("/v1/certificates/"):
            self.reply(204)
        else:
            self.reply(404, {"errors": [{"status": "404", "code": "NOT_FOUND", "title": "not mocked"}]})

    def do_PATCH(self):
        self.record()
        self.reply(200, {"data": {}})


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
