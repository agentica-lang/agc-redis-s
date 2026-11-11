## The `long double` of Redis, for INCRBYFLOAT: on x86-64 Linux the x87 extended
## format, a 64-bit mantissa and an exponent down to 2^-16445 (denormals) and up
## to 2^16383. `parse` is `strtold` as `string2ld` (util.c) calls it, `add` is
## one exactly rounded addition, `format` is `ld2string` in its human friendly
## mode (`%.17Lf`, then the trailing zeros and a bare `.` cut). A `Float` is a
## 53-bit double and would print other digits (0.1 as 0.10000000000000001), so
## this keeps the number as an exact binary value in a `Bignum`.

import Bignum from "bignum"

# string2ld refuses a text of MAX_LONG_DOUBLE_CHARS (5 * 1024) bytes or more.
MAX_CHARS = 5120
MANTISSA_BITS = 64
# The lowest bit of a denormal, and the highest exponent of a finite number.
LOWEST_BIT = -16445
HIGHEST_POWER = 16383
# 10^4933 is above the largest finite value, 10^-4952 is under half of the
# smallest denormal: past them the text is out of range for sure.
DECIMAL_HIGH = 4933
DECIMAL_LOW = -4952
SATURATED = 1_000_000

## The value is `mant * 2^exp`, negated if `negative`; no mantissa is 0. An
## infinity is only read from the text "inf"; no operation makes one.
export struct Ext
  negative: Bool
  mant: List[Int]
  exp: Int
  infinite: Bool
end

# The parts of a number text: the digit values, how many follow the `.`, and the
# exponent.
struct Mantissa
  digits: List[Int]
  fraction_size: Int
  power: Int
end

# What follows the number in the text: the end of a run of digits.
struct Run
  value: Int
  end_at: Int
end

## The number a text means as `strtold` reads it, or none when `string2ld`
## refuses: empty, 5120 bytes or more, not entirely a number (a sign, digits
## with an optional `.` and exponent, a hex float `0x1.8p3`, `inf`, `infinity`),
## `nan`, a space first, or out of range (an overflow, or a non-zero value that
## rounds to zero).
export def parse(text: Bytes) -> Optional[Ext]
  return none if text.empty? or text.size >= MAX_CHARS

  negative = text[0] == 45
  start = 0
  if negative or text[0] == 43
    start = 1
  end

  body = text.drop(start)
  word = body.decode("latin-1").unwrap!.downcase
  return some(Ext(negative: negative, mant: [], exp: 0, infinite: true)) if word == "inf" or word == "infinity"

  return hex_number(negative, body.drop(2)) if word.start_with?("0x")

  decimal_number(negative, body)
end

## The sum of two numbers, or none when it is NaN or infinite: INCRBYFLOAT
## refuses both. One exact addition, then one rounding.
export def add(a: Ext, b: Ext) -> Optional[Ext]
  return none if a.infinite or b.infinite

  return finite(b) if a.mant.empty?

  return finite(a) if b.mant.empty?

  low = a.exp
  if b.exp < low
    low = b.exp
  end

  left = Bignum.shift_left(a.mant, a.exp - low)
  right = Bignum.shift_left(b.mant, b.exp - low)
  return finite(round_to(a.negative, Bignum.add(left, right), low)) if a.negative == b.negative

  order = Bignum.compare(left, right)
  # Equal magnitudes give a zero (of either sign: it is printed as 0).
  return finite(round_to(a.negative, Bignum.sub(left, right), low)) if order >= 0

  finite(round_to(b.negative, Bignum.sub(right, left), low))
end

## The text INCRBYFLOAT stores: `%.17Lf` of the value with the trailing zeros
## and then a bare `.` cut, and "-0" as "0". The value is finite.
export def format(x: Ext) -> Bytes
  return "0".bytes if x.mant.empty?

  # The value times 10^17, rounded to a whole number as printf rounds.
  scaled = Bignum.mul_small(Bignum.mul_small(x.mant, 100_000_000), 1_000_000_000)
  whole = scaled
  if x.exp >= 0
    whole = Bignum.shift_left(scaled, x.exp)
  else
    whole = Bignum.shift_right_even(scaled, -x.exp)
  end

  digits = Bignum.to_decimal(whole)
  if digits.size < 18
    padding = (0...(18 - digits.size)).to_a.map do |_| "0" end
    digits = padding.join("") + digits
  end

  integer = digits.slice(0, digits.size - 17)
  fraction = trim_zeros(digits.slice(digits.size - 17, 17))
  return "0".bytes if fraction.empty? and integer == "0"

  sign = ""
  if x.negative
    sign = "-"
  end

  return "#{sign}#{integer}".bytes if fraction.empty?

  "#{sign}#{integer}.#{fraction}".bytes
end

# Zero, or a finite number that is not infinite (an overflow is infinite).
def finite(x: Ext) -> Optional[Ext]
  return none if x.infinite

  some(x)
end

# `n * 2^e` as an extended number: the mantissa cut to 64 bits (or to the lowest
# bit of a denormal), a tie to the even, and an infinity above the largest.
def round_to(negative: Bool, n: List[Int], e: Int) -> Ext
  return Ext(negative: negative, mant: [], exp: 0, infinite: false) if n.empty?

  bits = Bignum.bit_length(n)
  lowest = e + bits - MANTISSA_BITS
  if lowest < LOWEST_BIT
    lowest = LOWEST_BIT
  end

  mant = n
  exp = e
  if lowest > e
    mant = Bignum.shift_right_even(n, lowest - e)
    exp = lowest
    # Rounding up from 2^64 - 1 gives 2^64: one more bit, exact.
    if Bignum.bit_length(mant) > MANTISSA_BITS
      mant = Bignum.shift_right_even(mant, 1)
      exp += 1
    end
  end

  top = exp + Bignum.bit_length(mant) - 1
  Ext(negative: negative, mant: mant, exp: exp, infinite: not mant.empty? and top > HIGHEST_POWER)
end

# The text read as an extended number, none when it is out of range: an
# infinity from a finite text (an overflow), or zero from a non-zero text.
def ranged(negative: Bool, n: List[Int], e: Int) -> Optional[Ext]
  return some(Ext(negative: negative, mant: [], exp: 0, infinite: false)) if n.empty?

  rounded = round_to(negative, n, e)
  return none if rounded.infinite or rounded.mant.empty?

  some(rounded)
end

# Digits, an optional `.` and digits (at least one in all), an optional `e` and
# an exponent with a sign, and nothing after.
def decimal_number(negative: Bool, t: Bytes) -> Optional[Ext]
  case mantissa(t, 10, 101)
    none -> none
    some(m) -> decimal_value(negative, m.digits, m.power - m.fraction_size)
  end
end

def decimal_value(negative: Bool, digits: List[Int], power: Int) -> Optional[Ext]
  lead = 0
  while lead < digits.size and digits[lead] == 0
    lead += 1
  end

  return ranged(negative, [], 0) if lead == digits.size

  kept = digits.drop(lead)
  trail = 0
  while kept[kept.size - 1 - trail] == 0
    trail += 1
  end

  kept = kept.take(kept.size - trail)
  e10 = power + trail
  return none if kept.size - 1 + e10 >= DECIMAL_HIGH or kept.size + e10 <= DECIMAL_LOW

  big = from_digits(kept, 10)
  return ranged(negative, times_five_to(big, e10), e10) if e10 >= 0

  ranged_quotient(negative, big, 0 - e10)
end

# `big / 10^q` as a number with at least 66 correct bits and, in the lowest bit,
# whether anything was left over: `big * 2^k / 5^q` by floors, which add up to
# the floor of the whole division, then times 2^-(k + q).
def ranged_quotient(negative: Bool, big: List[Int], q: Int) -> Optional[Ext]
  bits_of_five_power = (q * 23220) / 10000 + 2
  k = 66 + bits_of_five_power - Bignum.bit_length(big)
  if k < 0
    k = 0
  end

  rest = Bignum.shift_left(big, k)
  left = q
  inexact = false
  while left >= 12
    step = Bignum.divide_small(rest, 244_140_625)
    inexact = inexact or step.remainder != 0
    rest = step.quotient
    left -= 12
  end

  if left > 0
    last = Bignum.divide_small(rest, 5.pow(left))
    inexact = inexact or last.remainder != 0
    rest = last.quotient
  end

  marked = Bignum.mul_small(rest, 2)
  if inexact
    marked = Bignum.add(marked, [1])
  end

  ranged(negative, marked, 0 - k - q - 1)
end

# `big * 5^power`: with the 2^power left to the exponent of the number, 10^power
# costs fewer limbs.
def times_five_to(big: List[Int], power: Int) -> List[Int]
  out = big
  left = power
  while left >= 12
    out = Bignum.mul_small(out, 244_140_625)
    left -= 12
  end

  Bignum.mul_small(out, 5.pow(left))
end

# Hex digits, an optional `.` and hex digits (at least one in all), and an
# optional `p` with a binary exponent: the value is the digits times 2^power.
def hex_number(negative: Bool, t: Bytes) -> Optional[Ext]
  case mantissa(t, 16, 112)
    none -> none
    some(m) -> hex_value(negative, from_digits(m.digits, 16), m.power - 4 * m.fraction_size)
  end
end

def hex_value(negative: Bool, big: List[Int], e2: Int) -> Optional[Ext]
  bits = Bignum.bit_length(big)
  return none if not big.empty? and (bits + e2 > HIGHEST_POWER + 2 or bits + e2 < LOWEST_BIT - 2)

  ranged(negative, big, e2)
end

# Digits, an optional `.` and digits (at least one in all), then an optional
# exponent introduced by `mark`; none when the text does not end with it.
def mantissa(t: Bytes, base: Int, mark: Int) -> Optional[Mantissa]
  whole_end = digits_end(t, 0, base)
  frac_end = whole_end
  if whole_end < t.size and t[whole_end] == 46
    frac_end = digits_end(t, whole_end + 1, base)
  end

  fraction_size = 0
  if frac_end > whole_end
    fraction_size = frac_end - whole_end - 1
  end

  power = exponent(t, frac_end, mark)
  return none if whole_end + fraction_size == 0 or power.end_at != t.size

  run = t.take(whole_end)
  if fraction_size > 0
    run = run + t.slice(whole_end + 1, fraction_size)
  end

  some(Mantissa(digits: run.to_a.map do |b| digit_of(b) end, fraction_size: fraction_size, power: power.value))
end

# The end of the run of digits of `base` that starts at `from`.
def digits_end(t: Bytes, from: Int, base: Int) -> Int
  i = from
  while i < t.size and digit_of(t[i]) >= 0 and digit_of(t[i]) < base
    i += 1
  end

  i
end

# 0 to 15 for a hex digit, -1 for any other byte.
def digit_of(b: Int) -> Int
  return b - 48 if b >= 48 and b <= 57

  return b - 87 if b >= 97 and b <= 102

  return b - 55 if b >= 65 and b <= 70

  -1
end

# The exponent that starts at `at` with the letter `mark` (`e` or `p`, in either
# case) and a sign: its value, capped, and where it ends. No letter is no
# exponent; a letter without digits stays unread, so the text does not end
# there and the caller refuses it.
def exponent(t: Bytes, at: Int, mark: Int) -> Run
  return Run(value: 0, end_at: at) if at >= t.size or (t[at] != mark and t[at] != mark - 32)

  from = at + 1
  negative = from < t.size and t[from] == 45
  if negative or (from < t.size and t[from] == 43)
    from += 1
  end

  stop = digits_end(t, from, 10)
  return Run(value: 0, end_at: at) if stop == from

  value = 0
  for b in t.slice(from, stop - from)
    value = value * 10 + b - 48
    if value > SATURATED
      value = SATURATED
    end
  end

  if negative
    value = 0 - value
  end

  Run(value: value, end_at: stop)
end

# The number with these digits in `base` (10 or 16): chunks of nine decimal
# digits or one hex digit at a time.
def from_digits(digits: List[Int], base: Int) -> List[Int]
  out: List[Int] = []
  if base == 16
    for d in digits
      out = Bignum.add(Bignum.mul_small(out, 16), Bignum.from_int(d))
    end

    return out
  end

  i = 0
  while i < digits.size
    size = digits.size - i
    if size > 9
      size = 9
    end

    chunk = digits.drop(i).take(size).reduce(0) do |acc, d| acc * 10 + d end
    scaled = Bignum.mul_small(out, 10.pow(size))
    out = Bignum.add(scaled, Bignum.from_int(chunk))
    i += size
  end

  out
end

def trim_zeros(text: String) -> String
  size = text.size
  while size > 0 and text.slice(size - 1, 1) == "0"
    size -= 1
  end

  text.slice(0, size)
end
