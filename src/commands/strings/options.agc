## The options of SET and GETEX, and the deadline they ask for.
##
## SET key value [NX | XX] [GET] [KEEPTTL | EX s | PX ms | EXAT s | PXAT ms], and
## GETEX key [PERSIST | EX | PX | EXAT | PXAT] with the same time words. A
## second time word of another kind is a syntax error, one of the same kind
## replaces the first, as in Redis.

import Args from "../args"
import Errors from "../errors"
import {Call} from "../command"

## SET takes NX, XX, GET and KEEPTTL; GETEX takes PERSIST. Anything else is a
## syntax error.
export enum Form
  Set
  GetEx
end

export struct Options
  nx: Bool = false
  xx: Bool = false
  get: Bool = false
  keepttl: Bool = false
  persist: Bool = false
  ## The time word, lowercase, or empty.
  kind: String = ""
  time: Optional[Bytes] = none
end

export def read(words: List[Bytes], form: Form) -> Result[Options]
  found = Options()
  i = 0
  while i < words.size
    word = Args.lower(words[i])
    timed = ["ex", "px", "exat", "pxat"].include?(word)
    return error(Errors.SYNTAX) if not timed and not own?(form, word)

    if timed and (found.keepttl or found.persist or (found.kind != "" and found.kind != word) or i + 1 == words.size)
      return error(Errors.SYNTAX)
    end

    case word
      "nx" ->
        return error(Errors.SYNTAX) if found.xx

        found = found.with(nx: true)
      "xx" ->
        return error(Errors.SYNTAX) if found.nx

        found = found.with(xx: true)
      "get" -> found = found.with(get: true)
      "keepttl" ->
        return error(Errors.SYNTAX) if found.kind != ""

        found = found.with(keepttl: true)
      "persist" ->
        return error(Errors.SYNTAX) if found.kind != ""

        found = found.with(persist: true)
      _ ->
        found = found.with(kind: word, time: some(words[i + 1]))
        i += 1
    end

    i += 1
  end

  ok(found)
end

## The deadline the options ask for; `none` when they ask for none. The error is
## the reply.
export def deadline_of(call: Call, found: Options) -> Result[Optional[Int]]
  case found.time
    none -> ok(none)
    some(text) ->
      seconds = found.kind == "ex" or found.kind == "exat"
      relative = found.kind == "ex" or found.kind == "px"
      ok(some(try Args.expire_ms(text, seconds, relative, call.now_ms, call.name)))
  end
end

# The words that only one of the forms knows.
def own?(form: Form, word: String) -> Bool
  case form
    Form.Set -> ["nx", "xx", "get", "keepttl"].include?(word)
    Form.GetEx -> word == "persist"
  end
end
