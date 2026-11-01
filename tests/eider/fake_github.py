"""A fake GitHub API for tests/eider/run.sh: serves the releases of a release directory
(<dir>/v<version>/<files>, the layout `EIDER_RELEASES=file://` reads) the way the GitHub
REST API does for a private repository, and insists on the token.

    python3 -I fake_github.py <dir> <owner/repo> <token> <port file>

GET /repos/<owner/repo>/releases            the releases as JSON (newest first), with assets
GET /repos/<owner/repo>/releases/latest     the newest; .../releases/tags/<tag>: that one
GET /repos/<owner/repo>/releases/assets/<n> with Accept: application/octet-stream: a 302 to
                                            /storage/<n> on another host name, localhost, as
                                            GitHub redirects to its storage
GET /storage/<n>                            the file; refused if an Authorization header came
                                            along (the token must not follow the redirect)
Anything without `Authorization: Bearer <token>` (but /storage) is 401; an unknown path 404.
It writes the port it listens on to <port file> and serves until killed.
"""
import http.server
import json
import os
import sys

root, repo, token, port_file = sys.argv[1:5]


def releases():
    out, assets = [], []
    for tag in sorted(os.listdir(root), reverse=True):
        d = os.path.join(root, tag)
        if not os.path.isdir(d):
            continue
        items = []
        for name in sorted(os.listdir(d)):
            n = len(assets)
            assets.append(os.path.join(d, name))
            items.append({"url": f"http://127.0.0.1:{port}/repos/{repo}/releases/assets/{n}",
                          "id": n, "name": name, "uploader": {"url": "http://127.0.0.1/users/x"}})
        out.append({"url": f"http://127.0.0.1:{port}/repos/{repo}/releases/{tag}", "tag_name": tag,
                    "name": "Eider " + tag, "draft": False, "prerelease": False, "assets": items})
    return out, assets


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/json", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        rels, assets = releases()
        if path.startswith("/storage/"):
            if self.headers.get("Authorization"):
                return self.send(400, b'{"message":"the token followed the redirect"}')
            n = int(path.rsplit("/", 1)[1])
            with open(assets[n], "rb") as f:
                return self.send(200, f.read(), "application/octet-stream")
        if self.headers.get("Authorization") != "Bearer " + token:
            return self.send(401, b'{"message":"Bad credentials"}')
        if path == f"/repos/{repo}/releases":
            return self.send(200, json.dumps(rels).encode())
        if path == f"/repos/{repo}/releases/latest" and rels:
            newest = max(rels, key=lambda r: tuple(int(x) for x in r["tag_name"][1:].split(".")))
            return self.send(200, json.dumps(newest).encode())
        for r in rels:
            if path == f"/repos/{repo}/releases/tags/{r['tag_name']}":
                return self.send(200, json.dumps(r).encode())
        prefix = f"/repos/{repo}/releases/assets/"
        if path.startswith(prefix):
            if self.headers.get("Accept") != "application/octet-stream":
                return self.send(415, b'{"message":"Accept: application/octet-stream"}')
            n = int(path[len(prefix):])
            return self.send(302, b"", extra={"Location": f"http://localhost:{port}/storage/{n}"})
        return self.send(404, b'{"message":"Not Found"}')


server = http.server.HTTPServer(("127.0.0.1", 0), H)
port = server.server_address[1]
with open(port_file + ".tmp", "w") as f:
    f.write(str(port))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
