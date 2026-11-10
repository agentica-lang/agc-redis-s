"""Starts the server on a free port and talks RESP over a raw socket."""

import os
import socket
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENTICA = os.environ.get("AGENTICA", "agentica")


class Server:
    """One server process; it prints the real port after `--port 0`."""

    def __init__(self):
        self.proc = subprocess.Popen(
            [AGENTICA, os.path.join(ROOT, "agc_redis_s.agc"), "--port", "0"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            cwd=ROOT,
        )
        line = self.proc.stdout.readline()
        if not line.startswith("ready "):
            self.stop()
            raise RuntimeError("server did not start: %r" % line)
        self.port = int(line.strip().rsplit(":", 1)[1])

    def connect(self):
        return socket.create_connection(("127.0.0.1", self.port), timeout=5)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stdout.close()


def read_exactly(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            break
        data += chunk
    return data


def port_is_free(port):
    probe = socket.socket()
    try:
        probe.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def wait_until(predicate, seconds=5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()
