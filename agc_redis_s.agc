## The server: parse the options, start the store task, accept clients.

import Config from "src/server/config"
import Accept from "src/server/accept"
import {Message} from "src/server/message"
import StoreTask from "src/server/store_task"

INBOX_SIZE = 4096

def main() -> Void
  case Config.parse(System.args())
    error(text) -> fail(text)
    ok(config) -> start(config)
  end
end

def start(config: Config.Config) -> Void
  case TCP.listen(config.bind, config.port)
    error(text) -> fail(text)
    ok(listener) ->
      inbox: Channel[Message] = Channel.new(INBOX_SIZE)
      _ = Task.spawn(&StoreTask.run, inbox)
      # Tests start the server on port 0 and read the real port from this line.
      puts("ready #{config.bind}:#{TCP.local_port(listener)}")
      IO.flush()
      Accept.accept_loop(listener, inbox)
  end
end

def fail(text: String) -> Void
  IO.warn(text)
  System.exit(1)
end
