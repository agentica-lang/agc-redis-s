## Runs one request against the table. Pure: the keyspace, the time and the
## client come in as data, the new keyspace and the reply go out.

import {Call, Command, Outcome, reply} from "command"
import {Reply} from "../resp/reply"

## `name` is what the client typed; the lookup ignores its case. `call` holds
## the arguments after the name.
export def execute(table: Map[String, Command], name: Bytes, call: Call) -> Outcome
  text = name.decode("latin-1").unwrap_or("")
  case table.get(text.downcase)
    none -> return reply(call, Reply.Error(unknown_text(text, call.args)))
    some(command) -> return run(command, call)
  end
end

def run(command: Command, call: Call) -> Outcome
  if bad_arity?(command.arity, call.args.size + 1)
    return reply(call, Reply.Error("ERR wrong number of arguments for '#{command.name}' command"))
  end

  return command.handler(call)
end

def bad_arity?(arity: Int, count: Int) -> Bool
  if arity >= 0
    return count != arity
  end

  return count < -arity
end

def unknown_text(name: String, args: List[Bytes]) -> String
  shown = args.map do |arg| "'#{arg.decode("latin-1").unwrap_or("")}' " end
  return "ERR unknown command '#{name}', with args beginning with: #{shown.join("")}"
end
