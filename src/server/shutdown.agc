## The graceful stop, as Redis does on SIGTERM and SIGINT: stop accepting, let
## the clients get what is queued for them, let the shards finish their inbox,
## and exit 0.

import Actor from "std/actor"
import Dock from "pkg/dock/dock"
import {Message} from "message"

## What the watcher of the signals needs.
struct Watch
  signals: Channel[System.Signal]
  server: Dock.Server
  ## Holds the signal's number once one came, so `main` tells a stop from a crash.
  stopping: ATS[String, Int]
end

## Subscribes to SIGTERM and SIGINT and stops `server` on the first one; none
## where signals cannot be subscribed to (Windows: they stop the program).
def watch(server: Dock.Server) -> Optional[ATS[String, Int]]
  case System.subscribe([System.Signal.Term, System.Signal.Int])
    error(_) -> none
    ok(signals) ->
      stopping: ATS[String, Int] = ATS.new()
      _watcher = Task.spawn(&watched, Watch(signals: signals, server: server, stopping: stopping))
      some(stopping)
  end
end

## Whether the server ended for a signal.
def asked?(stopping: Optional[ATS[String, Int]]) -> Bool
  case stopping
    none -> false
    some(table) -> table.has_key?(SIGNAL)
  end
end

## Lets each shard handle what is in its inbox, then ends it.
def finish[S](refs: List[Actor.Ref[S, Message]]) -> Void
  for ref in refs
    _ = Actor.stop(ref, SHARD_STOP_MS)
  end

  IO.warn("Redis is now ready to exit, bye bye...")
end

private

SIGNAL = "signal"
SHARD_STOP_MS = 5000
WAIT_MS = 60_000

def watched(watch: Watch) -> Void
  while true
    case watch.signals.recv(WAIT_MS)
      error(_) -> nil
      ok(signal) ->
        watch.stopping.put(SIGNAL, System.signal_number(signal))
        IO.warn("Received #{name_of(signal)} scheduling shutdown...")
        _ = Dock.stop(watch.server)
        return
    end
  end
end

def name_of(signal: System.Signal) -> String
  case signal
    System.Signal.Int -> "SIGINT"
    _ -> "SIGTERM"
  end
end
