"""Many clients at once, each pipelining: every reply comes back whole, in the
order of its client's requests, and no write is lost between clients."""

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


class StressTest(unittest.TestCase):
    def test_parallel_pipelined_clients(self):
        server = Server()
        try:
            failures = []
            threads = [threading.Thread(target=client, args=(server, n, failures)) for n in range(CLIENTS)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            self.assertEqual(failures, [])
            with server.connect() as sock:
                replies = Replies(sock)
                sock.sendall(command(b"GET", b"shared") + command(b"DBSIZE"))
                self.assertEqual(replies.bulk(), b"%d" % (CLIENTS * ROUNDS * BATCH))
                self.assertEqual(replies.line(), b":%d" % (CLIENTS * ROUNDS * BATCH + CLIENTS + 1))
        finally:
            server.stop()


if __name__ == "__main__":
    unittest.main()
