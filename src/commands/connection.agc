## Connection commands: PING, ECHO and QUIT. Server-wide commands (INFO,
## CLIENT, CONFIG, DBSIZE, FLUSHALL) go in a file of their own.

import {Call, Command, Outcome, reply, reply_and_close, wrong_arity} from "command"
import {Reply} from "../resp/reply"

export def commands() -> List[Command]
  return [
    Command(name: "ping", arity: -1, handler: &ping),
    Command(name: "echo", arity: 2, handler: &echo),
    Command(name: "quit", arity: -1, handler: &quit),
  ]
end

def ping(call: Call) -> Outcome
  if call.args.empty?
    return reply(call, Reply.Simple("PONG"))
  end

  if call.args.size > 1
    return wrong_arity(call)
  end

  return reply(call, Reply.Bulk(call.args[0]))
end

def echo(call: Call) -> Outcome
  return reply(call, Reply.Bulk(call.args[0]))
end

def quit(call: Call) -> Outcome
  return reply_and_close(call, Reply.Simple("OK"))
end
