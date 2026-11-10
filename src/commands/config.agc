## CONFIG GET for the settings a client reads at start. This server has no
## configuration file and no CONFIG SET: the values are the ones it runs with.
## Checked against Redis 7.2 config.c (configGetCommand) and redis-benchmark.c,
## which asks for `save` and `appendonly`.

import Args from "args"
import {Call, Command, Outcome, container, reply} from "command"
import {Reply} from "../resp/reply"
import Databases from "../store/databases"

# No persistence, so `save` is empty and `appendonly` is no.
SETTINGS = [
  Setting(name: "databases", value: "#{Databases.COUNT}"),
  Setting(name: "save", value: ""),
  Setting(name: "appendonly", value: "no"),
  Setting(name: "timeout", value: "0"),
  Setting(name: "maxclients", value: "10000"),
  Setting(name: "maxmemory", value: "0"),
  Setting(name: "maxmemory-policy", value: "noeviction"),
  Setting(name: "proto-max-bulk-len", value: "536870912"),
  Setting(name: "requirepass", value: ""),
]

struct Setting
  name: String
  value: String
end

export def commands() -> List[Command]
  return [container("config"), Command(name: "config|get", arity: -3, handler: &get)]
end

# A name without a pattern character is looked up, case-blind, and echoed as
# typed; a pattern is matched against every setting (`*` and `?` only, not the
# `[]` of Redis), and a setting already answered is not repeated.
def get(call: Call) -> Outcome
  found: List[Setting] = []
  items: List[Reply] = []
  for pattern in call.args
    text = Args.lower(pattern)
    for setting in SETTINGS
      if matches?(text, setting.name) and not found.include?(setting)
        found = found.push(setting)
        items = items.concat([Reply.Bulk(echoed(pattern, setting)), Reply.Bulk(setting.value.bytes)])
      end
    end
  end

  return reply(call, Reply.Array(items))
end

# An exact lookup answers with the name the client typed.
def echoed(pattern: Bytes, setting: Setting) -> Bytes
  if Args.lower(pattern) == setting.name
    return pattern
  end

  return setting.name.bytes
end

def matches?(pattern: String, text: String) -> Bool
  return glob(pattern.bytes, 0, text.bytes, 0)
end

# `*` takes any run, `?` any byte; every other byte must be equal.
def glob(pattern: Bytes, p: Int, text: Bytes, t: Int) -> Bool
  if p == pattern.size
    return t == text.size
  end

  if pattern[p] == 42
    return glob(pattern, p + 1, text, t) or (t < text.size and glob(pattern, p, text, t + 1))
  end

  if t == text.size
    return false
  end

  return (pattern[p] == 63 or pattern[p] == text[t]) and glob(pattern, p + 1, text, t + 1)
end
