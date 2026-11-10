## The integers of the wire and of the arguments: one reading, Redis's.

MIN_DIV_10 = -922_337_203_685_477_580
INT_MIN = -9_223_372_036_854_775_807 - 1

## An integer as Redis's `string2ll` reads it: digits only, one optional `-`, no
## `+`, no space, no leading zero (`0` alone is fine, `-0` is not), and it must
## fit in 64 bits. `none` otherwise.
export def parse(text: Bytes) -> Optional[Int]
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
