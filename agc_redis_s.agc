## The server: parse the options, build the store, the command table and the
## clock, start the store task, accept clients. This is the one place that
## builds them.

import Dock from "pkg/dock/dock"
import Engine from "src/commands/engine"
import Table from "src/commands/table"
import Config from "src/server/config"
import Connection from "src/server/connection"
import Clock from "src/server/clock"
import {Message} from "src/server/message"
import {fresh} from "src/store/databases"
import StoreTask from "src/server/store_task"

INBOX_SIZE = 4096
# Phase 0 cap on the replies a client has not read yet. Over it dock drops the
# client, so a client that never reads cannot make the server grow. Redis has
# no cap for normal clients by default; this is a stricter choice.
MAX_PENDING_BYTES = 8_388_608

def main() -> Void
  case Config.parse(System.args())
    error(e) -> fail(e.message)
    ok(config) -> start(config)
  end
end

def start(config: Config.Config) -> Void
  inbox: Channel[Message] = Channel.new(INBOX_SIZE)
  setup = StoreTask.Setup(inbox: inbox, store: Engine.start(fresh()), table: Table.build(), now_ms: &Clock.now_ms)
  store = Task.spawn(&StoreTask.run, setup)
  options = Dock.Config(port: config.port, host: config.bind, max_outbox_bytes: MAX_PENDING_BYTES)
  hooked = Dock.on_close(options) do |conn| Connection.gone(inbox, conn.id) end
  started = Dock.start(hooked) do |conn| Connection.serve(conn, inbox) end
  case started
    error(e) -> fail(e.message)
    ok(server) ->
      # Without the store task no command can run: dock stops the server, and
      # `wait` returns.
      Dock.watch(server, store)
      # Tests start the server on port 0 and read the real port from this line.
      puts("ready #{config.bind}:#{server.port}")
      IO.flush()
      case Dock.wait(server)
        error(e) -> fail(e.message)
        ok(_) -> fail("the store task stopped")
      end
  end
end

def fail(text: String) -> Void
  IO.warn(text)
  System.exit(1)
end
