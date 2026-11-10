import Integer from "../../src/resp/integer"
import Prop from "pkg/prop/prop"

def parsed(text: String) -> Optional[Int]
  return Integer.parse(text.bytes)
end

# What Redis's string2ll refuses, and the edges of the 64-bit range it accepts.
def test_parse_edges() -> Result[Void]
  try Test.eq(parsed("0"), some(0))
  try Test.eq(parsed("-12"), some(-12))
  try Test.eq(parsed("9223372036854775807"), some(9_223_372_036_854_775_807))
  try Test.eq(parsed("-9223372036854775808"), some(-9_223_372_036_854_775_807 - 1))
  for text in [
    "", "-", "+1", "01", "-0", "1 ", " 1", "1x", "--1", "9223372036854775808", "-9223372036854775809",
    "99999999999999999999",
  ]
    try Test.eq(parsed(text), none)
  end

  return Test.assert(true, "edges")
end

# Any Int written in decimal reads back as itself, over a range wider than 2^60.
def test_parse_round_trip() -> Result[Void]
  half = Prop.int(-1_000_000_000, 1_000_000_000)
  gen = Prop.map(Prop.pair(half, half), &widen)
  return Prop.check(gen, Prop.Config(runs: 100)) do |n| Prop.eq(parsed("#{n}"), some(n)) end
end

def widen(p: Prop.Pair[Int, Int]) -> Int
  return p.first * 4_000_000_000 + p.second
end
