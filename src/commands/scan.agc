## SCAN. Checked against Redis 7.2 db.c (scanCommand, scanGenericCommand,
## parseScanCursorOrReply). The pages come from store/scan.agc. As in Redis,
## COUNT is a hint, MATCH and TYPE filter after the page was taken (so a page can
## be empty with a cursor that is not 0), and an expired key is never listed.

import Args from "args"
import {Call, Command, Outcome, fail, reply} from "command"
import {Reply} from "../resp/reply"
import Glob from "../store/glob"
import Keyspace from "../store/keyspace"
import Scan from "../store/scan"

STAR = 42
DEFAULT_COUNT = 10
# A cursor past every hash: the scan answers an empty last page.
BEYOND = 9_000_000_000

# What the options say; `refused` is the error reply.
struct Options
  count: Int = DEFAULT_COUNT
  pattern: Optional[Bytes] = none
  string_only: Bool = true
  refused: Optional[String] = none
end

export def commands() -> List[Command]
  return [Command(name: "scan", arity: -2, handler: &scan)]
end

def scan(call: Call) -> Outcome
  case cursor_of(call.args[0])
    none -> return fail(call, "ERR invalid cursor")
    some(cursor) -> return scan_from(call, cursor)
  end
end

def scan_from(call: Call, cursor: Int) -> Outcome
  options = read_options(call.args.drop(1))
  case options.refused
    some(text) -> return fail(call, text)
    none -> nil
  end

  names = call.keyspace.entries.keys
  page = Scan.page(names, cursor, options.count)
  listed = page.keys.select do |key| wanted?(call, options, key) end
  return reply(
    call,
    Reply.Array([Reply.Bulk("#{page.next}".bytes), Reply.Array(listed.map do |key| Reply.Bulk(key) end)]),
  )
end

def wanted?(call: Call, options: Options, key: Bytes) -> Bool
  if not options.string_only or Keyspace.get(call.keyspace, key, call.now_ms).none?
    return false
  end

  case options.pattern
    none -> return true
    some(pattern) -> return (pattern.size == 1 and pattern[0] == STAR) or Glob.matches?(pattern, key)
  end
end

# `strtoul`: an optional `+`, then digits; no space. An empty text is 0. A `-`
# makes a huge number, which is a cursor past the end.
def cursor_of(text: Bytes) -> Optional[Int]
  if text.empty?
    return some(0)
  end

  digits = text
  if text[0] == 43 or text[0] == 45
    digits = text.drop(1)
  end

  if digits.empty?
    return none
  end

  total = 0
  for byte in digits
    if byte < 48 or byte > 57
      return none
    end

    if total < BEYOND
      total = total * 10 + byte - 48
    end
  end

  if text[0] == 45 and total > 0
    return some(BEYOND)
  end

  return some(total)
end

def read_options(words: List[Bytes]) -> Options
  found = Options()
  i = 0
  while i < words.size
    word = Args.lower(words[i])
    has_value = i + 1 < words.size
    if word == "count" and has_value
      case Args.parse_int(words[i + 1])
        none -> return found.with(refused: some("ERR value is not an integer or out of range"))
        some(count) ->
          if count < 1
            return found.with(refused: some("ERR syntax error"))
          end

          found = found.with(count: count)
      end
    elsif word == "match" and has_value
      found = found.with(pattern: some(words[i + 1]))
    elsif word == "type" and has_value
      found = found.with(string_only: Args.lower(words[i + 1]) == "string")
    else
      return found.with(refused: some("ERR syntax error"))
    end

    i += 2
  end

  return found
end
