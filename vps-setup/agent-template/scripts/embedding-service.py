#!/usr/bin/env python3
"""Embedding service daemon — serves all-MiniLM-L6-v2 over a Unix socket.

Keeps the model hot in memory so recall queries don't pay the load cost.

Protocol: newline-delimited JSON
  Request:  {"text": "..."}
  Request:  {"texts": ["...", "..."]}
  Response: {"embedding": [...]}
  Response: {"embeddings": [[...], ...]}
"""
import json
import os
import signal
import socket
import sys
import threading

SOCKET_PATH = "/tmp/{{TENANT_LINUX_USER}}-embedding.sock"
MODEL_NAME = "all-MiniLM-L6-v2"
LOG_PATH = "{{TENANT_AGENT_HOME}}/logs/embedding-service.log"


def _log(msg):
    import datetime
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"[{ts}] {msg}\n"
    sys.stdout.write(line)
    sys.stdout.flush()
    try:
        with open(LOG_PATH, "a") as f:
            f.write(line)
    except Exception:
        pass


def handle_client(conn, model):
    with conn:
        data = b""
        conn.settimeout(10.0)
        try:
            while True:
                chunk = conn.recv(131072)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break
        except OSError:
            return
        if not data:
            return
        try:
            req = json.loads(data.decode().strip())
            if "text" in req:
                emb = model.encode(req["text"], normalize_embeddings=True).tolist()
                resp = {"embedding": emb}
            elif "texts" in req:
                embs = model.encode(req["texts"], normalize_embeddings=True, batch_size=32).tolist()
                resp = {"embeddings": embs}
            else:
                resp = {"error": "missing text or texts field"}
        except Exception as e:
            resp = {"error": str(e)}
        try:
            conn.sendall((json.dumps(resp) + "\n").encode())
        except OSError:
            pass


def main():
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    _log("Loading all-MiniLM-L6-v2...")

    from sentence_transformers import SentenceTransformer
    model = SentenceTransformer(MODEL_NAME)
    # Warm up
    model.encode("warmup", normalize_embeddings=True)
    _log(f"Model ready (dim=384). Listening on {SOCKET_PATH}")

    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o660)
    server.listen(16)

    def shutdown(sig, frame):
        _log("Shutting down...")
        server.close()
        if os.path.exists(SOCKET_PATH):
            try:
                os.unlink(SOCKET_PATH)
            except OSError:
                pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    while True:
        try:
            conn, _ = server.accept()
            t = threading.Thread(target=handle_client, args=(conn, model), daemon=True)
            t.start()
        except OSError:
            break


if __name__ == "__main__":
    main()
