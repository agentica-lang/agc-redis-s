## Reading the arguments of a command, with Redis's rules.

import Errors from "errors"
import Integer from "../resp/integer"

## A reply of more items than this would pass the output cap of a client (dock
## drops it at 8 MiB, and an item takes 6 bytes at least, `$0\r\n\r\n`): the
## random commands refuse a negative count that asks for more, the only
## difference from Redis, which would stream it.
export MAX_ITEMS = 1_300_000

## The word as lowercase text, for matching option names without case. Latin-1
## maps every byte to a character, so this never fails.
export def lower(word: Bytes) -> String = word.decode("latin-1").unwrap!.downcase

## What Redis allows in a client name or a library name: printable ASCII
## without space. Its check is a C loop, so it stops at the first NUL byte.
export def plain_word?(word: Bytes) -> Bool
  for byte in word
    return true if byte == 0

    return false if byte < 33 or byte > 126
  end

  true
end

## An attribute a client set: the empty text means "not set", as in Redis.
export def present(word: Bytes) -> Optional[Bytes]
  return none if word.empty?

  some(word)
end

## An attribute as the text of CLIENT LIST: empty when not set.
export def shown(word: Optional[Bytes]) -> Bytes = word.unwrap_or("".bytes)

## The time argument of SET, GETEX, SETEX and PSETEX as an absolute deadline in
## ms (Redis's `getExpireMillisecondsOrReply`): it must be a positive integer.
## `relative` (EX, PX) adds the clock. The error is the whole reply text.
export def expire_ms(text: Bytes, seconds: Bool, relative: Bool, now_ms: Int, command: String) -> Result[Int]
  case Integer.parse(text)
    none -> error(Errors.NOT_INT)
    some(value) ->
      return bad_expire(command) if value <= 0 or (seconds and value > Integer.INT_MAX / 1000)

      ms = value
      if seconds
        ms = value * 1000
      end

      # The sum is compared first: an Int that overflows halts.
      return bad_expire(command) if relative and ms > Integer.INT_MAX - now_ms

      return ok(ms + now_ms) if relative

      ok(ms)
  end
end

## The time argument of the EXPIRE family (`expireGenericCommand`): any integer,
## also a negative one. `base_ms` is the clock for EXPIRE and PEXPIRE, 0 for
## the AT forms.
export def expire_when(text: Bytes, seconds: Bool, base_ms: Int, command: String) -> Result[Int]
  case Integer.parse(text)
    none -> error(Errors.NOT_INT)
    some(value) ->
      ms = value
      if seconds
        return bad_expire(command) if value > Integer.INT_MAX / 1000 or value < Integer.INT_MIN / 1000

        ms = value * 1000
      end

      return bad_expire(command) if ms > Integer.INT_MAX - base_ms

      ok(ms + base_ms)
  end
end

## A number that is zero or more (Redis's `getPositiveLongFromObjectOrReply`):
## the same `message` answers a word that is no number and a negative one.
export def positive(text: Bytes, message: String) -> Result[Int]
  case Integer.parse(text)
    none -> error(message)
    some(value) ->
      return error(message) if value < 0

      ok(value)
  end
end

## A number that is one or more (`getRangeLongFromObjectOrReply` from 1): the
## same `message` answers a word and a number below 1.
export def at_least_one(text: Bytes, message: String) -> Result[Int]
  case Integer.parse(text)
    none -> error(message)
    some(value) ->
      return error(message) if value < 1

      ok(value)
  end
end

def bad_expire(command: String) -> Result[Int] = error("ERR invalid expire time in '#{command}' command")
