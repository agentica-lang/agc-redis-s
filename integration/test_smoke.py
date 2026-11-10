"""One small smoke test: the real binary starts, answers, quits and stops.
The behavior of the commands is tested in process, in test/functional/."""

import signal
import unittest

from server import Server, port_is_free, read_exactly


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
            server.proc.send_signal(signal.SIGTERM)
            server.proc.wait(timeout=10)
            self.assertTrue(port_is_free(server.port))
        finally:
            server.stop()


if __name__ == "__main__":
    unittest.main()
