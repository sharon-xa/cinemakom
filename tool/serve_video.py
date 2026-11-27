#!/usr/bin/env python3
"""Serves one video file over HTTP with byte ranges, as the CDN does.

For the memory test's MEMORY_STREAM (docs/MEMORY.md §4): mpv streams it the
way it streams the CDN (HTTP, ranges, its cache file), but without the
internet in the way, so start and seek times show the player, not the
network. Make the file once with a stream copy of the CDN's, e.g. the first
28 minutes:

    ffmpeg -i '<stream url>' -map 0:v:0 -map 0:a:0 -c copy -t 1680 \\
        -movflags +faststart build/memory/local/endgame-4k.mp4
    tool/serve_video.py build/memory/local/endgame-4k.mp4          # port 8765
    tool/serve_video.py build/memory/local/endgame-4k.mp4 --mbps 50  # a steady 50 Mbit/s

Any path serves the file. Nothing is logged.
"""

import argparse
import http.server
import os
import re
import socket
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("file")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument(
        "--mbps", type=float, default=0, help="cap each response (0: no cap)"
    )
    args = parser.parse_args()
    path = os.path.abspath(args.file)
    size = os.path.getsize(path)
    bytes_per_s = args.mbps * 1e6 / 8

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_HEAD(self):
            self._serve(body=False)

        def do_GET(self):
            self._serve(body=True)

        def _serve(self, body: bool) -> None:
            start, end, status = 0, size - 1, 200
            ranged = re.fullmatch(
                r"bytes=(\d*)-(\d*)", self.headers.get("Range", "").strip()
            )
            if ranged and (ranged[1] or ranged[2]):
                status = 206
                if ranged[1]:
                    start = int(ranged[1])
                    if ranged[2]:
                        end = min(int(ranged[2]), size - 1)
                else:
                    start = max(size - int(ranged[2]), 0)
                if start >= size or start > end:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
            length = end - start + 1
            self.send_response(status)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if not body:
                return
            try:
                with open(path, "rb") as f:
                    if bytes_per_s <= 0:
                        # sendfile may send less than asked: loop.
                        sent = 0
                        while sent < length:
                            n = os.sendfile(
                                self.connection.fileno(),
                                f.fileno(),
                                start + sent,
                                length - sent,
                            )
                            if n == 0:
                                break
                            sent += n
                        return
                    f.seek(start)
                    began, sent = time.monotonic(), 0
                    while sent < length:
                        chunk = f.read(min(64 * 1024, length - sent))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        sent += len(chunk)
                        ahead = sent / bytes_per_s - (time.monotonic() - began)
                        if ahead > 0:
                            time.sleep(ahead)
            except (BrokenPipeError, ConnectionResetError, socket.timeout):
                pass  # mpv dropped the connection: a seek, or it closed.

    server = http.server.ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(f"serving {path} ({size / 1e9:.2f} GB) on http://{args.host}:{args.port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
