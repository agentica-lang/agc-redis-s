## Natural numbers of any size, for INCRBYFLOAT, which must give Redis's
## answers for an x87 `long double` (a 64-bit mantissa). Little-endian limbs of
## 30 bits, so a product of a limb and a small factor fits in an Int. A number
## has no zero limb at its end, and 0 is the empty list.

## A quotient and the remainder of a division by a small number.
struct Divided
  quotient: List[Int]
  remainder: Int
end

## `n` as a number; `n` is not negative.
def from_int(n: Int) -> List[Int]
  limbs: List[Int] = []
  rest = n
  while rest > 0
    limbs = limbs.push(rest % LIMB)
    rest = rest / LIMB
  end

  limbs
end

## The number of bits: 0 for 0, else the position of the highest 1 bit plus one.
def bit_length(a: List[Int]) -> Int
  return 0 if a.empty?

  top = a[a.size - 1]
  bits = 0
  while top > 0
    bits += 1
    top = top / 2
  end

  (a.size - 1) * 30 + bits
end

## `a * small`, with `small` between 0 and 2^30.
def mul_small(a: List[Int], small: Int) -> List[Int]
  return [] if small == 0

  out: List[Int] = []
  carry = 0
  for limb in a
    cur = limb * small + carry
    out = out.push(cur % LIMB)
    carry = cur / LIMB
  end

  if carry > 0
    out = out.push(carry)
  end

  out
end

def add(a: List[Int], b: List[Int]) -> List[Int]
  out: List[Int] = []
  carry = 0
  i = 0
  while i < a.size or i < b.size or carry > 0
    cur = carry
    if i < a.size
      cur += a[i]
    end

    if i < b.size
      cur += b[i]
    end

    out = out.push(cur % LIMB)
    carry = cur / LIMB
    i += 1
  end

  out
end

## `a - b`, with `b` not greater than `a`.
def sub(a: List[Int], b: List[Int]) -> List[Int]
  out: List[Int] = []
  borrow = 0
  i = 0
  while i < a.size
    cur = a[i] - borrow
    if i < b.size
      cur -= b[i]
    end

    borrow = 0
    if cur < 0
      cur += LIMB
      borrow = 1
    end

    out = out.push(cur)
    i += 1
  end

  trim(out)
end

## -1, 0 or 1 as `a` is less than, equal to or greater than `b`.
def compare(a: List[Int], b: List[Int]) -> Int
  if a.size != b.size
    return -1 if a.size < b.size

    return 1
  end

  i = a.size - 1
  while i >= 0
    if a[i] != b[i]
      return -1 if a[i] < b[i]

      return 1
    end

    i -= 1
  end

  0
end

## `a * 2^bits`.
def shift_left(a: List[Int], bits: Int) -> List[Int]
  return a if a.empty? or bits == 0

  zeros: List[Int] = (0...(bits / 30)).to_a.map do |_| 0 end
  zeros.concat(mul_small(a, 2.pow(bits % 30)))
end

## `a / 2^bits` rounded to the nearest whole number, a tie going to the even
## one: the rounding of an x87 FPU and of `printf`.
def shift_right_even(a: List[Int], bits: Int) -> List[Int]
  return a if bits == 0 or a.empty?

  limbs = bits / 30
  inner = bits % 30
  kept = shift_floor(a, limbs, inner)
  return add(kept, [1]) if round_up?(a, bits, kept)

  kept
end

## `a / small` and the remainder, with `small` between 1 and 2^30.
def divide_small(a: List[Int], small: Int) -> Divided
  top_first: List[Int] = []
  rest = 0
  i = a.size - 1
  while i >= 0
    cur = rest * LIMB + a[i]
    top_first = top_first.push(cur / small)
    rest = cur % small
    i -= 1
  end

  Divided(quotient: trim(top_first.reverse), remainder: rest)
end

## The digits of `a`, without leading zeros ("0" for 0).
def to_decimal(a: List[Int]) -> String
  return "0" if a.empty?

  chunks: List[Int] = []
  rest = a
  while not rest.empty?
    step = divide_small(rest, 1_000_000_000)
    chunks = chunks.push(step.remainder)
    rest = step.quotient
  end

  top = chunks.reverse
  ["#{top[0]}"].concat(top.drop(1).map do |n| pad9(n) end).join("")
end

private

LIMB = 1_073_741_824

# The number of the limbs of `a` below `limbs`, shifted by `inner` bits, whole.
def shift_floor(a: List[Int], limbs: Int, inner: Int) -> List[Int]
  rest = a.drop(limbs)
  return rest if inner == 0

  divide_small(rest, 2.pow(inner)).quotient
end

# Whether the dropped part of `a` (its lowest `bits` bits) is above half, or
# is half and `kept` is odd.
def round_up?(a: List[Int], bits: Int, kept: List[Int]) -> Bool
  half_at = bits - 1
  return false if half_at / 30 >= a.size

  half = (a[half_at / 30] / 2.pow(half_at % 30)) % 2 == 1
  return false if not half

  return true if sticky?(a, half_at)

  not kept.empty? and kept[0] % 2 == 1
end

# Whether any bit of `a` below bit `at` is 1.
def sticky?(a: List[Int], at: Int) -> Bool
  whole = at / 30
  i = 0
  while i < whole
    return true if a[i] != 0

    i += 1
  end

  whole < a.size and a[whole] % 2.pow(at % 30) != 0
end

def trim(limbs: List[Int]) -> List[Int]
  size = limbs.size
  while size > 0 and limbs[size - 1] == 0
    size -= 1
  end

  limbs.take(size)
end

def pad9(n: Int) -> String
  text = "#{n}"
  zeros = (0...(9 - text.size)).to_a.map do |_| "0" end
  zeros.join("") + text
end
