## Glob matching as Redis 7.2 does it (`stringmatchlen` in util.c): `*`, `?`,
## `[...]` with ranges, `^` and `\`, and an optional case-blind mode. KEYS, SCAN
## and CONFIG GET use it.
##
## Redis recurses on each `*`; this matcher walks the pattern once and, on a
## mismatch, goes back to the last `*` (one step forward in the subject), so
## it takes at most pattern length times subject length steps, never a number
## that grows with the stars. Every element but `*` takes exactly one byte, so
## going back only to the last `*` finds a match when there is one.
##
## The quirks of Redis are kept: an empty subject matches only the empty
## pattern (so not even `*`: callers that take `*` as "all" test for it first, as
## KEYS does), `[a-]` is the range from `a` to `]`, a `[` without its `]` runs to
## the end of the pattern, and a `\` ends the pattern as itself.

STAR = 42
QUESTION = 63
OPEN = 91
CLOSE = 93
BACKSLASH = 92
CARET = 94
DASH = 45

## True when `pattern` matches the whole of `text`.
export def matches?(pattern: Bytes, text: Bytes, nocase: Bool = false) -> Bool
  if text.empty?
    return pattern.empty?
  end

  p = 0
  t = 0
  retry_p = -1
  retry_t = 0
  while t < text.size
    if p < pattern.size and pattern[p] == STAR
      while p < pattern.size and pattern[p] == STAR
        p += 1
      end

      if p == pattern.size
        return true
      end

      retry_p = p
      retry_t = t
    else
      after = -1
      if p < pattern.size
        after = step(pattern, p, text[t], nocase)
      end

      if after >= 0
        p = after
        t += 1
      elsif retry_p >= 0
        retry_t += 1
        t = retry_t
        p = retry_p
      else
        return false
      end
    end
  end

  while p < pattern.size and pattern[p] == STAR
    p += 1
  end

  return p == pattern.size
end

# Matches the element that starts at `p` (not a `*`) against one byte: the
# index after the element, or -1 when it does not match.
def step(pattern: Bytes, p: Int, c: Int, nocase: Bool) -> Int
  first = pattern[p]
  if first == QUESTION
    return p + 1
  end

  if first == OPEN
    return bracket(pattern, p + 1, c, nocase)
  end

  literal = first
  after = p + 1
  if first == BACKSLASH and p + 1 < pattern.size
    literal = pattern[p + 1]
    after = p + 2
  end

  if same?(literal, c, nocase)
    return after
  end

  return -1
end

# The set `[...]` whose first byte after the `[` is at `q`.
def bracket(pattern: Bytes, q: Int, c: Int, nocase: Bool) -> Int
  size = pattern.size
  at = q
  negate = at < size and pattern[at] == CARET
  if negate
    at += 1
  end

  found = false
  while true
    left = size - at
    if left == 0
      return finish_set(found, negate, size)
    end

    if pattern[at] == BACKSLASH and left >= 2
      at += 1
      found = found or pattern[at] == c
    elsif pattern[at] == CLOSE
      return finish_set(found, negate, at + 1)
    elsif left >= 3 and pattern[at + 1] == DASH
      found = found or in_range?(pattern[at], pattern[at + 2], c, nocase)
      at += 2
    else
      found = found or same?(pattern[at], c, nocase)
    end

    at += 1
  end

  return -1
end

def finish_set(found: Bool, negate: Bool, after: Int) -> Int
  if found != negate
    return after
  end

  return -1
end

def in_range?(a: Int, b: Int, c: Int, nocase: Bool) -> Bool
  low = a
  high = b
  if a > b
    low = b
    high = a
  end

  if nocase
    return lower(c) >= lower(low) and lower(c) <= lower(high)
  end

  return c >= low and c <= high
end

def same?(a: Int, b: Int, nocase: Bool) -> Bool
  if nocase
    return lower(a) == lower(b)
  end

  return a == b
end

# ASCII only, as `tolower` in the C locale.
def lower(byte: Int) -> Int
  if byte >= 65 and byte <= 90
    return byte + 32
  end

  return byte
end
