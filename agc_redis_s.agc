## The server: parse the options, start the store task, accept clients.

import Accept from "src/server/accept"
import Config from "src/server/config"
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
      downs: Channel[Int] = Channel.new(INBOX_SIZE)
      store = Task.spawn(&StoreTask.run, inbox)
      Task.monitor(store, downs) do |_| stop_inbox(inbox) end
      # Tests start the server on port 0 and read the real port from this line.
      puts("ready #{config.bind}:#{TCP.local_port(listener)}")
      IO.flush()
      Accept.accept_loop(listener, inbox, downs)
      # Without the store task no command can run: stop, do not hang the clients.
      fail("the store task stopped")
  end
end

# Closing the inbox is how the rest of the server learns that the store task is
# gone: sends to it end, and the accept loop stops.
def stop_inbox(inbox: Channel[Message]) -> Int
  inbox.close
  return 0
end

def fail(text: String) -> Void
  IO.warn(text)
  System.exit(1)
end
