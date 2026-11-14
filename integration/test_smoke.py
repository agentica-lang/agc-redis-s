"""One small smoke test: the real binary starts, answers, quits and stops.
The behavior of the commands is tested in process, in test/functional/."""

import signal
import socket
import time
import unittest

from server import Server, port_is_free, read_exactly


READ_SECONDS = 10


def read_to_eof(sock):
    """Everything up to the close; a server that never closes fails the test
    with a timeout instead of hanging it."""
    sock.settimeout(READ_SECONDS)
    data = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return data
        data += chunk


class SmokeTest(unittest.TestCase):
    def test_ping_quit_and_sigterm(self):
        server = Server()
        try:
            with server.connect() as sock:
                sock.sendall(b"*1\r\n$4\r\nPING\r\n")
                self.assertEqual(read_exactly(sock, 7), b"+PONG\r\n")
                sock.sendall(b"QUIT\r\n")
                self.assertEqual(read_exactly(sock, 5), b"+OK\r\n")
                self.assertEqual(sock.recv(10), b"")
            self.assert_nothing_runs_after_quit(server)
            self.assert_replies_survive_eof(server)
            # SIGTERM with a client connected and idle stops the server as
            # Redis does: gracefully, exit code 0, the port free.
            with server.connect():
                server.proc.send_signal(signal.SIGTERM)
                self.assertEqual(server.proc.wait(timeout=10), 0)
            self.assertTrue(port_is_free(server.port))
        finally:
            server.stop()

    def assert_replies_survive_eof(self, server):
        # `printf ... | nc` and redis-cli's pipe mode send, shut down their
        # side and read to the end: every reply must still arrive.
        with server.connect() as sock:
            sock.sendall(b"PING\r\n" * 1000 + b"SET a b\r\nGET a\r\n")
            sock.shutdown(socket.SHUT_WR)
            self.assertEqual(read_to_eof(sock), b"+PONG\r\n" * 1000 + b"+OK\r\n$1\r\nb\r\n")

    def assert_nothing_runs_after_quit(self, server):
        # The requests behind a QUIT in one write must not run, and a client
        # that closed or quit is not counted in connected_clients.
        with server.connect() as sock:
            sock.sendall(b"QUIT\r\nSET k v\r\n")
            self.assertEqual(read_to_eof(sock), b"+OK\r\n")
        with server.connect() as sock:
            sock.sendall(b"PING\r\n")
            self.assertEqual(read_exactly(sock, 7), b"+PONG\r\n")
        time.sleep(0.2)
        with server.connect() as sock:
            sock.sendall(b"GET k\r\nINFO clients\r\n")
            data = read_exactly(sock, 5 + 5 + 32 + 2)
        self.assertTrue(data.startswith(b"$-1\r\n"), data)
        self.assertIn(b"connected_clients:1\r\n", data)


if __name__ == "__main__":
    unittest.main()
