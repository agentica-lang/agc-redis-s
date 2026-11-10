import os
import select
import shutil
import socket
import subprocess
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENTICA = os.environ.get("AGENTICA", "agentica")
START_SECONDS = 30


class Server:
    """One server process on port 0; it prints the real port on a `ready` line."""

    def __init__(self):
        if shutil.which(AGENTICA) is None:
            # CI must not skip: a missing binary there is a broken setup.
            if os.environ.get("CI"):
                raise RuntimeError("%s is not installed" % AGENTICA)
            raise unittest.SkipTest("%s is not installed" % AGENTICA)
        self.proc = subprocess.Popen(
            [AGENTICA, os.path.join(ROOT, "agc_redis_s.agc"), "--port", "0"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=ROOT,
        )
        self.port = self._read_port()

    def _read_port(self):
        deadline = time.time() + START_SECONDS
        seen = b""
        while time.time() < deadline:
            ready, _, _ = select.select([self.proc.stdout], [], [], 0.2)
            if ready:
                chunk = os.read(self.proc.stdout.fileno(), 4096)
                if not chunk:
                    break
                seen += chunk
            for line in seen.splitlines():
                if line.startswith(b"ready ") and b":" in line:
                    return int(line.rsplit(b":", 1)[1])
        self.stop()
        raise RuntimeError("server did not start: %r" % seen)

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
    # TIME_WAIT of a closed connection is not a listener: ignore it.
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        probe.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        probe.close()
