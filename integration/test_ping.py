import signal
import threading
import time
import unittest

from server import Server, port_is_free, read_exactly

PONG = b"+PONG\r\n"


def command(*args):
    parts = [b"*%d\r\n" % len(args)]
    for arg in args:
        parts.append(b"$%d\r\n%s\r\n" % (len(arg), arg))
    return b"".join(parts)


class PingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = Server()

    @classmethod
    def tearDownClass(cls):
        cls.server.stop()

    def ask(self, payload, size):
        with self.server.connect() as sock:
            sock.sendall(payload)
            return read_exactly(sock, size)

    def test_ping(self):
        self.assertEqual(self.ask(command(b"PING"), len(PONG)), PONG)

    def test_echo_is_binary_safe(self):
        data = b"\x00\r\n\xff"
        self.assertEqual(self.ask(command(b"ECHO", data), 10), b"$4\r\n" + data + b"\r\n")

    def test_two_pipelined_requests_in_one_write(self):
        self.assertEqual(self.ask(command(b"PING") * 2, 2 * len(PONG)), PONG * 2)

    def test_request_split_across_two_writes(self):
        with self.server.connect() as sock:
            sock.sendall(b"*2\r\n$4\r\nPING\r\n$5\r\nhe")
            time.sleep(0.2)
            sock.sendall(b"llo\r\n")
            self.assertEqual(read_exactly(sock, 11), b"$5\r\nhello\r\n")

    def test_unknown_command(self):
        reply = b"-ERR unknown command 'FOO', with args beginning with: 'a' 'b c' \r\n"
        self.assertEqual(self.ask(command(b"FOO", b"a", b"b c"), len(reply)), reply)

    def test_unknown_command_cannot_forge_a_reply(self):
        reply = b"-ERR unknown command 'FOO', with args beginning with: 'a  +OK\xff' \r\n"
        with self.server.connect() as sock:
            sock.sendall(command(b"FOO", b"a\r\n+OK\xff") + command(b"PING"))
            self.assertEqual(read_exactly(sock, len(reply) + len(PONG)), reply + PONG)

    def test_quit_replies_ok_then_closes(self):
        with self.server.connect() as sock:
            sock.sendall(command(b"QUIT") + command(b"PING"))
            self.assertEqual(read_exactly(sock, 5), b"+OK\r\n")
            self.assertEqual(sock.recv(10), b"")

    def test_connect_and_close_without_sending(self):
        self.server.connect().close()
        self.assertEqual(self.ask(command(b"PING"), len(PONG)), PONG)

    def test_fifty_clients_of_a_hundred_pings(self):
        failures = []

        def client():
            try:
                with self.server.connect() as sock:
                    sock.sendall(command(b"PING") * 100)
                    if read_exactly(sock, 100 * len(PONG)) != PONG * 100:
                        failures.append("wrong replies")
            except OSError as error:
                failures.append(repr(error))

        threads = [threading.Thread(target=client) for _ in range(50)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=60)
        self.assertEqual(failures, [])


class StopTest(unittest.TestCase):
    def test_sigterm_stops_the_server_and_frees_the_port(self):
        server = Server()
        try:
            server.proc.send_signal(signal.SIGTERM)
            server.proc.wait(timeout=10)
            self.assertTrue(port_is_free(server.port))
        finally:
            server.stop()


if __name__ == "__main__":
    unittest.main()
