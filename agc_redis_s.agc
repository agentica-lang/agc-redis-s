## The server: parse the options, build the shards, the command table and the
## clock, start the shard actors, accept clients. This is the one place that
## builds them.

import Actor from "std/actor"
import Dock from "pkg/dock/dock"
import Engine from "src/commands/engine"
import Table from "src/commands/table"
import Config from "src/server/config"
import Connection from "src/server/connection"
import Clock from "src/server/clock"
import Shard from "src/server/shard"
import Shutdown from "src/server/shutdown"
import {Command} from "src/commands/command"
import {Message} from "src/server/message"
import {fresh} from "src/store/databases"

INBOX_SIZE = 4096
# Phase 0 cap on the replies a client has not read yet. Over it dock drops the
# client, so a client that never reads cannot make the server grow. Redis has
# no cap for normal clients by default; this is a stricter choice.
MAX_PENDING_BYTES = 8_388_608
# How long a stop lets the clients' queued replies be written.
GRACE_MS = 1000

def main() -> Void
  case Config.parse(System.args())
    error(e) -> fail(e.message)
    ok(config) -> start(config)
  end
end

def start(config: Config.Config) -> Void
  table = Table.build()
  refs = (0...config.shards).to_a.map do |_| start_shard(table) end
  addresses = refs.map do |ref| ref.address end
  shards = Connection.Shards(addresses: addresses, table: table, now_ms: &Clock.now_ms, clients: Connection.counter())
  options = Dock.Config(port: config.port, host: config.bind, max_outbox_bytes: MAX_PENDING_BYTES, grace_ms: GRACE_MS)

  hooked = Dock.on_close(options) do |_conn| Connection.gone(shards) end
  started = Dock.start(hooked) do |conn| Connection.serve(conn, shards) end
  case started
    error(e) -> fail(e.message)
    ok(server) ->
      # Without a shard no command on its keys can run: dock stops the server,
      # and `wait` returns.
      for ref in refs
        Dock.watch(server, ref.task)
      end

      stopping = Shutdown.watch(server)
      # Tests start the server on port 0 and read the real port from this line.
      puts("ready #{config.bind}:#{server.port}")
      IO.flush()
      case Dock.wait(server)
        error(e) -> fail(e.message)
        ok(_) -> ended(refs, stopping)
      end
  end
end

def ended(refs: List[Actor.Ref[Shard.State, Message]], stopping: Optional[ATS[String, Int]]) -> Void
  return fail("a shard stopped") if not Shutdown.asked?(stopping)

  Shutdown.finish(refs)
  System.exit(0)
end

def start_shard(table: Map[String, Command]) -> Actor.Ref[Shard.State, Message]
  Shard.start(Shard.Setup(store: Engine.start(fresh()), table: table, now_ms: &Clock.now_ms), INBOX_SIZE)
end

def fail(text: String) -> Void
  IO.warn(text)
  System.exit(1)
end
