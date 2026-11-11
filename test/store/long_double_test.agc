import LongDouble from "../../src/store/long_double"
import Prop from "pkg/prop/prop"

# What INCRBYFLOAT answers for `a` plus `b`: the text, "bad" when a number is
# refused by string2ld, "err" for a NaN or an infinity as the sum.
def sum_text(a: String, b: String) -> String
  case LongDouble.parse(a.bytes)
    none -> "bad"
    some(x) ->
      case LongDouble.parse(b.bytes)
        none -> "bad"
        some(y) -> shown(LongDouble.add(x, y))
      end
  end
end

def shown(total: Optional[LongDouble.Ext]) -> String
  case total
    none -> "err"
    some(z) -> LongDouble.format(z).decode("latin-1").unwrap!
  end
end

# Every expected text was printed by glibc on x86-64 for the same sum, as
# `strtold`, `+=` and `snprintf("%.17Lf")` with the trailing zeros cut (the code
# of util.c, compiled alone). A double would give 0.30000000000000004 here, and
# 3.3000000000000003 for 1.1 + 2.2. The 1024 rows are 1024 + 2^-54, a tie
# between two mantissas (it goes to the even one), then the same, and the next
# one, with a last digit that puts it above the tie. 0x1p-16445 is the smallest
# denormal and 0x1p-16446 half of it (a tie, to the even zero: out of range);
# the 2^54 rows: the same tie and one above it, with ten decimals;
# 0x1p16383 twice is 2^16384, past the largest number. (Decimal texts at these
# ends cost a long division, more than a test file's step limit allows.)
def test_sums_as_the_x87_long_double() -> Result[Void]
  cases = [
    ["10.5", "0.1", "10.6"],
    ["5.0e3", "2.0e2", "5200"],
    ["1.1", "2.2", "3.3"],
    ["0.1", "0.2", "0.3"],
    ["1", "-1", "0"],
    ["-1e-30", "0", "0"],
    ["-0", "-0", "0"],
    ["1e30", "1", "1000000000000000000024696061952"],
    ["123456789.123456789", "0.000000001", "123456789.12345678999554366"],
    ["18446744073709551615", "1", "18446744073709551616"],
    ["0x10", "0x1p-1", "16.5"],
    ["18014398509481984.0009765625", "0", "18014398509481984"],
    ["18014398509481984.00097656251", "0", "18014398509481984.001953125"],
    ["0x1p-16445", "0", "0"],
    ["0x1p-16446", "0", "bad"],
    ["0x1p16383", "0x1p16383", "err"],
    ["0x1p16384", "0", "bad"],
    ["1024.000000000000000055511151231257827021181583404541015625", "0", "1024"],
    ["1024.0000000000000000555111512312578270211815834045410156251", "0", "1024.00000000000000011"],
    ["1024.000000000000000166533453693773481063544750213623046875", "0", "1024.00000000000000022"],
  ]

  for row in cases
    try Test.eq(sum_text(row[0], row[1]), row[2])
  end

  Test.eq(1, 1)
end

# The texts string2ld refuses: not a number, nan, an exponent without digits,
# out of range, and the sums that are infinite or NaN.
def test_refused_texts_and_sums() -> Result[Void]
  for bad in ["", "1e", "0x", ".", "-", ".e1", "nan", "1e5000", "1e-4960", "1 ", "1,5"]
    try Test.eq(sum_text(bad, "1"), "bad")
  end

  for row in [["inf", "1"], ["-inf", "inf"]]
    try Test.eq(sum_text(row[0], row[1]), "err")
  end

  Test.eq(1, 1)
end

# A short decimal comes back as typed, without its trailing zeros: below 10 the
# error of 64 bits (under 6e-19) is far under the 17th decimal. From 128 on it
# shows, as it does in Redis (128.064518 is stored as 128.06451800000000001).
def test_short_decimals_round_trip() -> Result[Void]
  fractions = Prop.int(0, 999999)
  pairs = Prop.pair(Prop.int(0, 9), fractions)
  Prop.check(pairs, Prop.Config(runs: 60)) do |p|
    fraction = "#{p.second + 1000000}".slice(1, 6)
    shown_back = sum_text("#{p.first}.#{fraction}", "0")
    Prop.eq(shown_back, canonical(p.first, fraction))
  end
end

# Whole numbers add as Ints do (both are exact in 64 bits). 30 runs: the step
# limit is between 90 and 130 runs here and between 200 and 400 for the law
# above (60 runs), a third of the lower.
def test_whole_numbers_add_as_ints() -> Result[Void]
  numbers = Prop.int(-1_000_000_000_000_000, 1_000_000_000_000_000)
  Prop.check(Prop.pair(numbers, numbers), Prop.Config(runs: 30)) do |p|
    Prop.eq(sum_text("#{p.first}", "#{p.second}"), "#{p.first + p.second}")
  end
end

def canonical(whole: Int, fraction: String) -> String
  size = fraction.size
  while size > 0 and fraction.slice(size - 1, 1) == "0"
    size -= 1
  end

  return "#{whole}" if size == 0

  "#{whole}.#{fraction.slice(0, size)}"
end
