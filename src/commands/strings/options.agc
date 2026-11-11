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
    if not timed and not own?(form, word)
      return error(Errors.SYNTAX)
    end

    if timed and (found.keepttl or found.persist or (found.kind != "" and found.kind != word) or i + 1 == words.size)
      return error(Errors.SYNTAX)
    end

    case word
      "nx" ->
        if found.xx
          return error(Errors.SYNTAX)
        end

        found = found.with(nx: true)
      "xx" ->
        if found.nx
          return error(Errors.SYNTAX)
        end

        found = found.with(xx: true)
      "get" -> found = found.with(get: true)
      "keepttl" ->
        if found.kind != ""
          return error(Errors.SYNTAX)
        end

        found = found.with(keepttl: true)
      "persist" ->
        if found.kind != ""
          return error(Errors.SYNTAX)
        end

        found = found.with(persist: true)
      _ ->
        found = found.with(kind: word, time: some(words[i + 1]))
        i += 1
    end

    i += 1
  end

  return ok(found)
end

## The deadline the options ask for; `none` when they ask for none. The error is
## the reply.
export def deadline_of(call: Call, found: Options) -> Result[Optional[Int]]
  case found.time
    none -> return ok(none)
    some(text) ->
      seconds = found.kind == "ex" or found.kind == "exat"
      relative = found.kind == "ex" or found.kind == "px"
      return ok(some(try Args.expire_ms(text, seconds, relative, call.now_ms, call.name)))
  end
end

# The words that only one of the forms knows.
def own?(form: Form, word: String) -> Bool
  case form
    Form.Set -> return ["nx", "xx", "get", "keepttl"].include?(word)
    Form.GetEx -> return word == "persist"
  end
end
