## Runs one request against the table. Pure: the keyspace, the time and the
## client come in as data, the new keyspace and the replies go out.

import Args from "args"
import {Call, Command, Outcome, fail_bytes, wrong_arity} from "command"

# Redis cuts the command name and the echoed arguments at 128 bytes
# (processCommand in server.c), so a huge argument is not sent back whole.
SHOWN_BYTES = 128

## `name` is what the client typed; the lookup ignores its case. `call` holds
## the arguments after the name; `execute` sets `call.name`.
export def execute(table: Map[String, Command], name: Bytes, call: Call) -> Outcome
  # Latin-1 maps every byte to a character, so this never fails.
  lower = Args.lower(name)
  # `client|id` is the key of a subcommand, never a command of its own.
  if lower.include?("|")
    return unknown(name, call)
  end

  case table.get(lower)
    none -> return unknown(name, call)
    some(command) -> return run(command, table, call.with(name: lower))
  end
end

def run(command: Command, table: Map[String, Command], call: Call) -> Outcome
  if bad_arity?(command.arity, call.args.size + 1)
    return wrong_arity(call)
  end

  if command.container and not call.args.empty?
    return subcommand(command, table, call)
  end

  return command.handler(call)
end

# Called with at least one argument. The subcommand's arity counts
# the container name, the subcommand and its arguments, and its error names it
# as `client|id`, as Redis 7.2 does.
def subcommand(container: Command, table: Map[String, Command], call: Call) -> Outcome
  key = "#{call.name}|#{Args.lower(call.args[0])}"
  case table.get(key)
    none ->
      text = Bytes.concat([
        "ERR unknown subcommand '".bytes,
        call.args[0].take(SHOWN_BYTES),
        "'. Try #{container.name.upcase} HELP.".bytes,
      ])

      return fail_bytes(call, text)
    some(sub) ->
      inner = call.with(name: key, args: call.args.drop(1))
      if bad_arity?(sub.arity, call.args.size + 1)
        return wrong_arity(inner)
      end

      return sub.handler(inner)
  end
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
