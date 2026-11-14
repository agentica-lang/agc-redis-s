"""Many clients at once, each pipelining: every reply comes back whole, in the
order of its client's requests, no write is lost between clients, a write to
keys of several shards is never seen half done, and clients that reset or
never read do not stop the others."""

import socket
import struct
import threading
import unittest

from server import Server

CLIENTS = 50
ROUNDS = 20
# Commands per round of one client: SET, GET, INCR and RPUSH, each BATCH times.
BATCH = 16
READ_SECONDS = 30


class Replies:
    def __init__(self, sock):
        self.sock = sock
        self.buffer = b""

    def line(self):
        while b"\r\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed with %r left" % self.buffer)
            self.buffer += chunk
        head, self.buffer = self.buffer.split(b"\r\n", 1)
        return head

    def bulk(self):
        head = self.line()
        if head == b"$-1":
            return None
        size = int(head[1:])
        while len(self.buffer) < size + 2:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed inside a bulk")
            self.buffer += chunk
        body, self.buffer = self.buffer[:size], self.buffer[size + 2 :]
        return body


def command(*words):
    parts = [b"*%d\r\n" % len(words)]
    for word in words:
        parts.append(b"$%d\r\n%s\r\n" % (len(word), word))
    return b"".join(parts)


def client(server, number, failures):
    try:
        with server.connect() as sock:
            sock.settimeout(READ_SECONDS)
            replies = Replies(sock)
            last_count = 0
            pushed = 0
            for round_ in range(ROUNDS):
                keys = [b"k:%d:%d:%d" % (number, round_, i) for i in range(BATCH)]
                out = []
                for i, key in enumerate(keys):
                    out.append(command(b"SET", key, b"v%d" % i))
                    out.append(command(b"GET", key))
                    out.append(command(b"INCR", b"shared"))
                    out.append(command(b"RPUSH", b"list:%d" % number, b"%d" % (pushed + i)))
                sock.sendall(b"".join(out))
                for i in range(BATCH):
                    assert replies.line() == b"+OK"
                    got = replies.bulk()
                    assert got == b"v%d" % i, (number, round_, i, got)
                    count = int(replies.line()[1:])
                    # One client sees the shared counter only go up.
                    assert count > last_count, (count, last_count)
                    last_count = count
                    pushed += 1
                    assert replies.line() == b":%d" % pushed
            sock.sendall(command(b"LRANGE", b"list:%d" % number, b"0", b"-1"))
            head = replies.line()
            assert head == b"*%d" % pushed, head
            items = [replies.bulk() for _ in range(pushed)]
            assert items == [b"%d" % i for i in range(pushed)], "list out of order"
    except Exception as failure:  # noqa: BLE001 - reported by the test
        failures.append((number, repr(failure)))


# Keys that the hash slots spread over the shards, written together.
GROUP = [b"group:%d" % i for i in range(10)]


def group_writer(server, number, failures):
    """MSET of every key of GROUP at once: a reader must never see two values."""
    try:
        with server.connect() as sock:
            sock.settimeout(READ_SECONDS)
            replies = Replies(sock)
            for round_ in range(ROUNDS * 5):
                value = b"%d-%d" % (number, round_)
                words = [b"MSET"]
                for key in GROUP:
                    words += [key, value]
                # DBSIZE locks every shard; now and then, as it joins all keys.
                count = round_ % 10 == 0
                sock.sendall(command(*words) + command(b"MGET", *GROUP) + (command(b"DBSIZE") if count else b""))
                assert replies.line() == b"+OK"
                assert replies.line() == b"*%d" % len(GROUP)
                seen = {replies.bulk() for _ in GROUP}
                assert len(seen) == 1, "torn MSET: %r" % seen
                if count:
                    assert replies.line().startswith(b":")
    except Exception as failure:  # noqa: BLE001 - reported by the test
        failures.append(("group", number, repr(failure)))


def reset_after_pipeline(server):
    """A big INCR pipeline, then a close with RST while the replies are due."""
    sock = server.connect()
    sock.sendall(command(b"INCR", b"reset") * 20000)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    sock.close()


def never_reads(server):
    """Big GET replies to a client that never reads: dock drops it at the cap."""
    sock = server.connect()
    sock.sendall(command(b"SET", b"big", b"x" * 1_000_000))
    try:
        for _ in range(40):
            sock.sendall(command(b"GET", b"big") * 4)
    except OSError:
        pass
    return sock


class StressTest(unittest.TestCase):
    def test_parallel_pipelined_clients(self):
        for shards in ("1", "4"):
            with self.subTest(shards=shards):
                self.run_clients(Server("--shards", shards))

    def run_clients(self, server):
        try:
            reset_after_pipeline(server)
            silent = never_reads(server)
            with server.connect() as sock:
                sock.sendall(command(b"PING"))
                self.assertEqual(Replies(sock).line(), b"+PONG")
            silent.close()
            failures = []
            threads = [threading.Thread(target=client, args=(server, n, failures)) for n in range(CLIENTS)]
            threads += [threading.Thread(target=group_writer, args=(server, n, failures)) for n in range(5)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            self.assertEqual(failures, [])
            with server.connect() as sock:
                replies = Replies(sock)
                # The reset may come before the server read any INCR.
                sock.sendall(command(b"GET", b"shared") + command(b"DEL", b"big", b"reset") + command(b"DBSIZE"))
                self.assertEqual(replies.bulk(), b"%d" % (CLIENTS * ROUNDS * BATCH))
                self.assertIn(replies.line(), (b":1", b":2"))
                self.assertEqual(replies.line(), b":%d" % (CLIENTS * ROUNDS * BATCH + CLIENTS + 1 + len(GROUP)))
        finally:
            server.stop()


if __name__ == "__main__":
    unittest.main()
