#!/usr/bin/env python3
"""Embedding client — connects to the embedding daemon or falls back to inline loading.

Usage:
    from _embedding_helpers import embed, embed_batch, ensure_daemon
"""
import json
import os
import socket as socket_mod
import subprocess
import time

SOCKET_PATH = "/tmp/{{TENANT_LINUX_USER}}-embedding.sock"
MODEL_NAME = "all-MiniLM-L6-v2"
DAEMON_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "embedding-service.py")

_inline_model = None


def ensure_daemon(timeout: float = 15.0) -> bool:
    """Start the embedding daemon if not already running. Returns True if ready."""
    if _socket_ping():
        return True
    try:
        subprocess.Popen(
            ["python3", DAEMON_SCRIPT],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:
        return False
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.5)
        if _socket_ping():
            return True
    return False


def _socket_ping() -> bool:
    try:
        sock = socket_mod.socket(socket_mod.AF_UNIX, socket_mod.SOCK_STREAM)
        sock.settimeout(1.0)
        sock.connect(SOCKET_PATH)
        sock.close()
        return True
    except OSError:
        return False


def _socket_request(payload: dict, timeout: float = 10.0) -> dict | None:
    try:
        sock = socket_mod.socket(socket_mod.AF_UNIX, socket_mod.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(SOCKET_PATH)
        sock.sendall((json.dumps(payload) + "\n").encode())
        data = b""
        while True:
            chunk = sock.recv(131072)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
        sock.close()
        return json.loads(data.decode().strip())
    except Exception:
        return None


def _inline_embed(text: str) -> list[float]:
    global _inline_model
    if _inline_model is None:
        from sentence_transformers import SentenceTransformer
        _inline_model = SentenceTransformer(MODEL_NAME)
    return _inline_model.encode(text, normalize_embeddings=True).tolist()


def _inline_embed_batch(texts: list) -> list:
    global _inline_model
    if _inline_model is None:
        from sentence_transformers import SentenceTransformer
        _inline_model = SentenceTransformer(MODEL_NAME)
    return _inline_model.encode(texts, normalize_embeddings=True, batch_size=32).tolist()


def embed(text: str) -> list[float]:
    """Get normalized embedding for a single text string."""
    resp = _socket_request({"text": text}, timeout=5.0)
    if resp and "embedding" in resp:
        return resp["embedding"]
    return _inline_embed(text)


def embed_batch(texts: list) -> list:
    """Get normalized embeddings for a list of texts."""
    if not texts:
        return []
    resp = _socket_request({"texts": texts}, timeout=60.0)
    if resp and "embeddings" in resp:
        return resp["embeddings"]
    return _inline_embed_batch(texts)
