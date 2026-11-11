## The integers of the wire and of the arguments: one reading, Redis's.

MIN_DIV_10 = -922_337_203_685_477_580
export INT_MIN = -9_223_372_036_854_775_807 - 1
export INT_MAX = 9_223_372_036_854_775_807

## An integer as Redis's `string2ll` reads it: digits only, one optional `-`, no
## `+`, no space, no leading zero (`0` alone is fine, `-0` is not), and it must
## fit in 64 bits. `none` otherwise.
export def parse(text: Bytes) -> Optional[Int]
  return none if text.empty?

  negative = text[0] == 45
  digits = text
  if negative
    digits = text.drop(1)
  end

  return none if digits.empty? or (digits[0] == 48 and (digits.size > 1 or negative))

  # Summed as a negative number: its range holds the magnitude of INT_MIN.
  total = 0
  for byte in digits
    return none if byte < 48 or byte > 57

    digit = byte - 48
    return none if total < MIN_DIV_10 or (total == MIN_DIV_10 and digit > 8)

    total = total * 10 - digit
  end

  return some(total) if negative

  return none if total == INT_MIN

  some(-total)
end
