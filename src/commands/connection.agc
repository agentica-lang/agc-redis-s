## Connection commands: PING and ECHO.

import {Call, Command, Flag, Outcome, reply} from "command"
import {Reply} from "../resp/reply"

export def commands() -> List[Command]
  return [
    Command(name: "ping", arity: -1, flags: [Flag.Fast], handler: &ping),
    Command(name: "echo", arity: 2, flags: [Flag.Fast], handler: &echo),
  ]
end

def ping(call: Call) -> Outcome
  if call.args.empty?
    return reply(call, Reply.Simple("PONG"))
  end

  if call.args.size > 1
    return reply(call, Reply.Error("ERR wrong number of arguments for 'ping' command"))
  end

  return reply(call, Reply.Bulk(call.args[0]))
end

def echo(call: Call) -> Outcome
  return reply(call, Reply.Bulk(call.args[0]))
end
