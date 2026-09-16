"""Stand-in for POST /v1/crash: rejects anything that is not a gzipped batch, saves the JSON.

Deliberately strict about `Content-Encoding`, because gzip is a requirement of the route rather than
an optimisation — a run that quietly sent plain JSON would pass here and fail in production.
"""
import gzip, json, sys, http.server

OUT = sys.argv[1]
PORT = int(sys.argv[2])
STATUS = int(sys.argv[3]) if len(sys.argv) > 3 else 202


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Content-Encoding") != "gzip":
            self.send_error(400, "not gzip")
            return
        body = gzip.decompress(raw)
        with open(OUT, "w") as f:
            json.dump(json.loads(body), f, indent=2)
        print(f"ingest: {self.path} key={self.headers.get('x-union-key')} "
              f"{len(raw)}B gzip -> {len(body)}B json -> {STATUS}", flush=True)
        payload = b"{}"
        self.send_response(STATUS)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
