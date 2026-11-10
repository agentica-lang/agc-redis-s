## Runs one request against the table. Pure: the keyspace, the time and the
## client come in as data, the new keyspace and the replies go out.

import {Call, Command, Outcome, fail_bytes, wrong_arity} from "command"

# Redis cuts the command name and the echoed arguments at 128 bytes
# (processCommand in server.c), so a huge argument is not sent back whole.
SHOWN_BYTES = 128

## `name` is what the client typed; the lookup ignores its case. `call` holds
## the arguments after the name; `execute` sets `call.name`.
export def execute(table: Map[String, Command], name: Bytes, call: Call) -> Outcome
  # Latin-1 maps every byte to a character, so this never fails.
  lower = name.decode("latin-1").unwrap!.downcase
  case table.get(lower)
    none -> return unknown(name, call)
    some(command) -> return run(command, call.with(name: lower))
  end
end

def run(command: Command, call: Call) -> Outcome
  if bad_arity?(command.arity, call.args.size + 1)
    return wrong_arity(call)
  end

  return command.handler(call)
end

def bad_arity?(arity: Int, count: Int) -> Bool
  if arity >= 0
    return count != arity
  end

  return count < -arity
end

# The error is built from bytes: no decode, so no byte changes on the way.
def unknown(name: Bytes, call: Call) -> Outcome
  text = Bytes.concat([
    "ERR unknown command '".bytes,
    name.take(SHOWN_BYTES),
    "', with args beginning with: ".bytes,
    shown_args(call.args),
  ])

  return fail_bytes(call, text)
end

# Each argument as 'arg ', until 128 bytes are shown; the last one is cut to fit.
def shown_args(args: List[Bytes]) -> Bytes
  parts: List[Bytes] = []
  shown = 0
  for arg in args
    if shown >= SHOWN_BYTES
      break
    end

    part = Bytes.concat(["'".bytes, arg.take(SHOWN_BYTES - shown), "' ".bytes])
    parts = parts.push(part)
    shown += part.size
  end

  return Bytes.concat(parts)
end
