## Reading the arguments of a command, with Redis's rules.

MIN_DIV_10 = -922_337_203_685_477_580
INT_MIN = -9_223_372_036_854_775_807 - 1

## An integer as Redis's `string2ll` reads it: digits only, one optional `-`, no
## `+`, no space, no leading zero (`0` alone is fine, `-0` is not), and it must
## fit in 64 bits. `none` otherwise.
export def parse_int(text: Bytes) -> Optional[Int]
  if text.empty?
    return none
  end

  negative = text[0] == 45
  digits = text
  if negative
    digits = text.drop(1)
  end

  if digits.empty? or (digits[0] == 48 and (digits.size > 1 or negative))
    return none
  end

  # Summed as a negative number: its range holds the magnitude of INT_MIN.
  total = 0
  for byte in digits
    if byte < 48 or byte > 57
      return none
    end

    digit = byte - 48
    if total < MIN_DIV_10 or (total == MIN_DIV_10 and digit > 8)
      return none
    end

    total = total * 10 - digit
  end

  if negative
    return some(total)
  end

  if total == INT_MIN
    return none
  end

  return some(-total)
end

## The word as lowercase text, for matching option names without case. Latin-1
## maps every byte to a character, so this never fails.
export def lower(word: Bytes) -> String
  return word.decode("latin-1").unwrap!.downcase
end

## What Redis allows in a client name or a library name: printable ASCII
## without space. Its check is a C loop, so it stops at the first NUL byte.
export def plain_word?(word: Bytes) -> Bool
  for byte in word
    if byte == 0
      return true
    end

    if byte < 33 or byte > 126
      return false
    end
  end

  return true
end

## An attribute a client set: the empty text means "not set", as in Redis.
export def present(word: Bytes) -> Optional[Bytes]
  if word.empty?
    return none
  end

  return some(word)
end

## An attribute as the text of CLIENT LIST: empty when not set.
export def shown(word: Optional[Bytes]) -> Bytes
  return word.unwrap_or("".bytes)
end
