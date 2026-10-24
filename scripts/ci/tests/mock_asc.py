"""A tiny stand-in for the App Store Connect API, for scripts/ci/tests/run-tests.sh.

    python3 -I mock_asc.py <request-log.jsonl> <port-file>

Serves the requests asc-testflight.sh makes, records each one (method, path, query, body, and the
JWT's header and payload) as a JSON line, and reports processing as "not listed", then PROCESSING,
then VALID, so the script's polling is exercised. Never talks to Apple.
"""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

LOG, PORT_FILE = sys.argv[1], sys.argv[2]
APP_ID, BUILD_ID, GROUP_ID = "6700000001", "build-1", "group-1"
state = {"build_polls": 0}


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
        elif path == "/v1/builds":
            state["build_polls"] += 1
            if state["build_polls"] == 1:
                self.reply(200, {"data": []})
            else:
                processing = "PROCESSING" if state["build_polls"] == 2 else "VALID"
                self.reply(200, {"data": [{"type": "builds", "id": BUILD_ID, "attributes": {
                    "version": query["filter[version]"][0], "processingState": processing,
                    "usesNonExemptEncryption": False, "expired": False}}]})
        elif path == f"/v1/builds/{BUILD_ID}/betaBuildLocalizations":
            self.reply(200, {"data": []})
        elif path == "/v1/betaGroups":
            name = query.get("filter[name]", ["?"])[0]
            groups = [{"type": "betaGroups", "id": GROUP_ID,
                       "attributes": {"name": "External testers", "isInternalGroup": False}}]
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
        elif path == "/v1/betaAppReviewSubmissions":
            self.reply(201, {"data": {"type": "betaAppReviewSubmissions", "id": "review-1"}})
        else:
            self.reply(404, {"errors": [{"status": "404", "code": "NOT_FOUND", "title": "not mocked"}]})

    def do_PATCH(self):
        self.record()
        self.reply(200, {"data": {}})


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
