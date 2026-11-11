## CONFIG GET and SET for the settings a client reads at start. This server has
## no configuration file and cannot change a setting: the values are the ones it
## runs with. Checked against Redis 7.2 config.c (configGetCommand,
## configSetCommand) and redis-benchmark.c, which asks for `save` and `appendonly`.

import Args from "args"
import Errors from "errors"
import {Call, Command, Outcome, container, fail, fail_bytes, reply} from "command"
import {Reply} from "../resp/reply"
import Databases from "../store/databases"
import Glob from "../store/glob"
import Strings from "../store/strings"

# No persistence, so `save` is empty and `appendonly` is no.
SETTINGS = [
  Setting(name: "databases", value: "#{Databases.COUNT}"),
  Setting(name: "save", value: ""),
  Setting(name: "appendonly", value: "no"),
  Setting(name: "timeout", value: "0"),
  Setting(name: "maxclients", value: "10000"),
  Setting(name: "maxmemory", value: "0"),
  Setting(name: "maxmemory-policy", value: "noeviction"),
  Setting(name: "proto-max-bulk-len", value: "#{Strings.MAX_BYTES}"),
  Setting(name: "requirepass", value: ""),
]

struct Setting
  name: String
  value: String
end

export def commands() -> List[Command]
  [
    container("config"),
    Command(name: "config|get", arity: -3, handler: &get),
    Command(name: "config|set", arity: -4, handler: &change),
  ]
end

# An exact name is echoed as typed; a setting already answered is not repeated.
def get(call: Call) -> Outcome
  found: List[Setting] = []
  items: List[Reply] = []
  for pattern in call.args
    for setting in SETTINGS
      if matches?(pattern, setting.name) and not found.include?(setting)
        found = found.push(setting)
        items = items.concat([Reply.Bulk(echoed(pattern, setting)), Reply.Bulk(setting.value.bytes)])
      end
    end
  end

  reply(call, Reply.Array(items))
end

# An exact lookup answers with the name the client typed.
def echoed(pattern: Bytes, setting: Setting) -> Bytes
  return pattern if Args.lower(pattern) == setting.name

  setting.name.bytes
end

# A name with a pattern character (`[`, `*` or `?`) is matched as a glob, any
# case; any other is looked up whole, any case.
def matches?(pattern: Bytes, name: String) -> Bool
  special = pattern.to_a.any? do |byte| byte == 91 or byte == 42 or byte == 63 end
  return Glob.matches?(pattern, name.bytes, true) if special

  Args.lower(pattern) == name
end

# Pairs of a name and a value. The first name that is not a setting is the
# error, as in Redis; a setting is one Redis would not let change at run time,
# since this server keeps no state for it.
def change(call: Call) -> Outcome
  return fail(call, Errors.SYNTAX) if call.args.size % 2 == 1

  i = 0
  while i < call.args.size
    name = Args.lower(call.args[i])
    if not SETTINGS.any? do |setting| setting.name == name end
      return fail_bytes(
        call,
        "ERR Unknown option or number of arguments for CONFIG SET - '".bytes + call.args[i] + "'".bytes,
      )
    end

    i += 2
  end

  text = (
    "ERR CONFIG SET failed (possibly related to argument '".bytes +
    call.args[0] +
    "') - can't set immutable config".bytes
  )

  fail_bytes(call, text)
end
