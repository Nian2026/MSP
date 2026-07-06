#!/usr/bin/env python3
"""Capture complete model request bodies while forwarding to a real upstream.

The proxy is intentionally small and transport-level: it does not understand
agent turns, tools, or app state.  It records the exact POST body bytes that the
client sent, then streams the upstream response back to the client.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, Iterable, Tuple
from urllib.parse import ParseResult, urlparse


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}

REDACTED_HEADERS = {
    "authorization",
    "cookie",
    "set-cookie",
    "x-api-key",
    "x-error-json",
    "api-key",
    "openai-api-key",
    "x-openai-api-key",
    "x-openai-actor-authorization",
}


class CaptureState:
    def __init__(
        self,
        *,
        label: str,
        out_dir: Path,
        upstream_base_url: str,
        upstream_api_key: str | None,
        chunk_size: int,
    ) -> None:
        self.label = label
        self.out_dir = out_dir
        self.upstream = urlparse(upstream_base_url.rstrip("/"))
        if self.upstream.scheme not in {"http", "https"} or not self.upstream.netloc:
            raise ValueError(f"invalid upstream base URL: {upstream_base_url}")
        self.upstream_api_key = upstream_api_key
        self.chunk_size = chunk_size
        self.lock = threading.Lock()
        self.sequence = 0
        self.requests_dir = self.out_dir / "requests"
        self.requests_dir.mkdir(parents=True, exist_ok=True)

    def next_sequence(self) -> int:
        with self.lock:
            self.sequence += 1
            return self.sequence


def redact_headers(headers: Iterable[Tuple[str, str]]) -> Dict[str, str]:
    redacted: Dict[str, str] = {}
    for name, value in headers:
        if name.lower() in REDACTED_HEADERS:
            redacted[name] = "<redacted>"
        else:
            redacted[name] = value
    return redacted


def upstream_path(upstream: ParseResult, incoming_target: str) -> str:
    parsed = urlparse(incoming_target)
    incoming_path = parsed.path or "/"
    base_path = upstream.path.rstrip("/")

    if base_path and (incoming_path == base_path or incoming_path.startswith(base_path + "/")):
        path = incoming_path
    elif base_path:
        path = base_path + "/" + incoming_path.lstrip("/")
    else:
        path = incoming_path

    if parsed.query:
        return path + "?" + parsed.query
    return path


def connection_for(upstream: ParseResult, timeout: float) -> http.client.HTTPConnection:
    port = upstream.port
    if upstream.scheme == "https":
        return http.client.HTTPSConnection(upstream.hostname, port=port, timeout=timeout)
    return http.client.HTTPConnection(upstream.hostname, port=port, timeout=timeout)


def json_dump(path: Path, value: object) -> None:
    data = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
    path.write_bytes(data + b"\n")


class CaptureProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "msp-request-capture-proxy/1.0"

    def do_GET(self) -> None:
        if self.path in {"/healthz", "/readyz"}:
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404, "not found")

    def do_POST(self) -> None:
        state: CaptureState = self.server.capture_state  # type: ignore[attr-defined]
        seq = state.next_sequence()
        prefix = f"{seq:04d}-{state.label}"
        started = time.time()

        body = self._read_request_body()
        body_sha = hashlib.sha256(body).hexdigest()
        body_path = state.requests_dir / f"{prefix}.body.json"
        meta_path = state.requests_dir / f"{prefix}.metadata.json"
        body_path.write_bytes(body)

        forward_path = upstream_path(state.upstream, self.path)
        upstream_url = f"{state.upstream.scheme}://{state.upstream.netloc}{forward_path}"
        request_headers = self._forward_headers(body, state)
        metadata = {
            "sequence": seq,
            "label": state.label,
            "started_at_unix": started,
            "method": self.command,
            "path": self.path,
            "upstream_url": upstream_url,
            "request_headers": redact_headers(self.headers.items()),
            "forward_headers": redact_headers(request_headers.items()),
            "request_body_bytes": len(body),
            "request_body_sha256": body_sha,
        }

        response_status = 502
        response_headers: Dict[str, str] = {}
        response_bytes = 0
        error_message: str | None = None
        conn: http.client.HTTPConnection | None = None

        try:
            conn = connection_for(state.upstream, timeout=300)
            conn.request(self.command, forward_path, body=body, headers=request_headers)
            upstream_response = conn.getresponse()
            response_status = upstream_response.status
            response_headers = {name: value for name, value in upstream_response.getheaders()}

            self.send_response(upstream_response.status, upstream_response.reason)
            for name, value in upstream_response.getheaders():
                lowered = name.lower()
                if lowered in HOP_BY_HOP_HEADERS or lowered == "content-length":
                    continue
                self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()

            while True:
                chunk = upstream_response.read(state.chunk_size)
                if not chunk:
                    break
                response_bytes += len(chunk)
                self.wfile.write(chunk)
                self.wfile.flush()
        except BrokenPipeError:
            error_message = "client disconnected while upstream response was streaming"
        except Exception as exc:  # pragma: no cover - exercised by real network failures.
            error_message = f"{type(exc).__name__}: {exc}"
            if not self.wfile.closed:
                payload = json.dumps({"error": error_message}, ensure_ascii=False).encode("utf-8")
                try:
                    self.send_response(502)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(payload)
                except Exception:
                    pass
        finally:
            if conn is not None:
                conn.close()
            metadata.update(
                {
                    "finished_at_unix": time.time(),
                    "duration_seconds": time.time() - started,
                    "response_status": response_status,
                    "response_headers": redact_headers(response_headers.items()),
                    "response_body_bytes_streamed": response_bytes,
                    "error": error_message,
                    "body_file": str(body_path),
                }
            )
            json_dump(meta_path, metadata)

    def _read_request_body(self) -> bytes:
        length = self.headers.get("Content-Length")
        if length is None:
            return b""
        return self.rfile.read(int(length))

    def _forward_headers(self, body: bytes, state: CaptureState) -> Dict[str, str]:
        headers: Dict[str, str] = {}
        for name, value in self.headers.items():
            lowered = name.lower()
            if lowered in HOP_BY_HOP_HEADERS or lowered in {"host", "content-length"}:
                continue
            if state.upstream_api_key and lowered in REDACTED_HEADERS:
                continue
            headers[name] = value

        headers["Host"] = state.upstream.netloc
        headers["Content-Length"] = str(len(body))
        headers.setdefault("Accept-Encoding", "identity")
        if state.upstream_api_key:
            headers["Authorization"] = f"Bearer {state.upstream_api_key}"
        return headers

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write(
            "%s - - [%s] %s\n"
            % (self.address_string(), self.log_date_time_string(), fmt % args)
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--label", required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--upstream-base-url", default="https://api.openai.com/v1")
    parser.add_argument("--upstream-api-key")
    parser.add_argument("--upstream-api-key-env", default="MSP_REQUEST_PARITY_UPSTREAM_API_KEY")
    parser.add_argument("--chunk-size", type=int, default=8192)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    upstream_api_key = args.upstream_api_key
    if upstream_api_key is None and args.upstream_api_key_env:
        upstream_api_key = os.environ.get(args.upstream_api_key_env)
    if upstream_api_key is None:
        upstream_api_key = os.environ.get("OPENAI_API_KEY")
    if upstream_api_key is None:
        upstream_api_key = os.environ.get("MSP_PLAYGROUND_MODEL_API_KEY")

    state = CaptureState(
        label=args.label,
        out_dir=args.out_dir,
        upstream_base_url=args.upstream_base_url,
        upstream_api_key=upstream_api_key,
        chunk_size=args.chunk_size,
    )
    server = ThreadingHTTPServer((args.listen_host, args.port), CaptureProxyHandler)
    server.capture_state = state  # type: ignore[attr-defined]

    host, port = server.server_address[:2]
    base_url = f"http://{host}:{port}"
    ready_payload = {
        "label": args.label,
        "base_url": base_url,
        "upstream_base_url": args.upstream_base_url,
        "out_dir": str(args.out_dir),
        "requests_dir": str(state.requests_dir),
        "pid": os.getpid(),
    }
    if args.ready_file:
        args.ready_file.parent.mkdir(parents=True, exist_ok=True)
        json_dump(args.ready_file, ready_payload)
    print(json.dumps(ready_payload, ensure_ascii=False), flush=True)

    def stop(_signum: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    server.serve_forever(poll_interval=0.25)
    server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
