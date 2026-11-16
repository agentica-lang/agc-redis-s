"""A load benchmark of the server with redis-benchmark.

Starts agc_redis_s.agc on 127.0.0.1, port 0, with the given Agentica binary and scheduler count, runs redis-benchmark
against that port only (never the default 6379, which may be another server), and prints, per test, the requests per
second, p50 and p99, and the server's RSS after it.

    python3 tools/bench.py --agentica ~/.local/share/agentica/agentica-0.33.0-linux-x86_64/bin/agentica --schedulers 4
"""

import argparse
import csv
import io
import os
import shutil
import socket
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "integration"))

MGET_KEYS = [b"k%d" % i for i in range(1, 11)]

# Each run: a name and the arguments of redis-benchmark after the connection ones.
RUNS = [
    ("P16 3 B", ["-P", "16", "-c", "50", "-n", "200000", "-t", "set,get", "-d", "3"]),
    ("P16 1 KiB", ["-P", "16", "-c", "50", "-n", "200000", "-t", "set,get", "-d", "1024"]),
    ("P16", ["-P", "16", "-c", "50", "-n", "50000", "-t", "lrange_100,mset"]),
    ("P16", ["-P", "16", "-c", "50", "-n", "200000", "MGET", *[key.decode() for key in MGET_KEYS]]),
    ("P1 3 B", ["-P", "1", "-c", "50", "-n", "50000", "-t", "set,get", "-d", "3"]),
]


def seed(port):
    """The keys of the MGET run, each a 3-byte value."""
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    for key in MGET_KEYS:
        sock.sendall(b"*3\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$3\r\nabc\r\n" % (len(key), key))
    data = b""
    while data.count(b"+OK\r\n") < len(MGET_KEYS):
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("the server closed during the setup: %r" % data)
        data += chunk
    sock.close()


def benchmark(port, args):
    out = subprocess.run(
        ["redis-benchmark", "-h", "127.0.0.1", "-p", str(port), "--csv", *args],
        capture_output=True,
        text=True,
        timeout=600,
        check=True,
    ).stdout
    rows = [row for row in csv.reader(io.StringIO(out)) if row and row[0] != "test"]
    return [(row[0], float(row[1]), float(row[4]), float(row[6])) for row in rows]


def rss_mib(pid):
    values = {}
    with open("/proc/%d/status" % pid) as status:
        for line in status:
            name, _, rest = line.partition(":")
            if name in ("VmRSS", "VmHWM"):
                values[name] = int(rest.split()[0]) // 1024
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--agentica", default="agentica")
    parser.add_argument("--schedulers", type=int, default=1)
    parser.add_argument("--label", default="")
    options = parser.parse_args()
    if shutil.which("redis-benchmark") is None:
        sys.exit("redis-benchmark is not installed")

    os.environ["AGENTICA"] = options.agentica
    os.environ["AGENTICA_SCHEDULERS"] = str(options.schedulers)
    from server import Server

    server = Server()
    try:
        seed(server.port)
        version = subprocess.run([options.agentica, "--version"], capture_output=True, text=True).stdout.strip()
        label = options.label or "%s s%d" % (version, options.schedulers)
        for name, args in RUNS:
            for test, rps, p50, p99 in benchmark(server.port, args):
                memory = rss_mib(server.proc.pid)
                print(
                    "%s | %s %s | %.0f req/s | p50 %.3f ms | p99 %.3f ms | RSS %d MiB (peak %d MiB)"
                    % (label, test, name, rps, p50, p99, memory["VmRSS"], memory["VmHWM"]),
                    flush=True,
                )
    finally:
        server.stop()


if __name__ == "__main__":
    main()
