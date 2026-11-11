import Glob from "../../src/store/glob"
import Prop from "pkg/prop/prop"

def hit?(pattern: String, text: String) -> Bool = Glob.matches?(pattern.bytes, text.bytes)

def hit_nocase?(pattern: String, text: String) -> Bool = Glob.matches?(pattern.bytes, text.bytes, true)

# The cases of Redis's own tests and the quirks of its stringmatchlen: sets,
# ranges (swapped bounds too), `^`, escapes, `[a-]` as a range up to `]`, a set
# that never closes, a `\` at the end, and the empty subject.
def test_the_rules_of_redis() -> Result[Void]
  yes = [
    ["h?llo", "hello"],
    ["h*llo", "hllo"],
    ["h*llo", "heeeello"],
    ["h[ae]llo", "hallo"],
    ["h[^e]llo", "hallo"],
    ["h[a-b]llo", "hbllo"],
    ["h[b-a]llo", "hallo"],
    ["\\*", "*"],
    ["a\\", "a\\"],
    ["[a-]", "]"],
    ["[ab", "a"],
    ["a*", "a"],
    ["a**b*", "axxbyy"],
    ["[\\]]", "]"],
    ["", ""],
  ]

  no = [
    ["h?llo", "hllo"],
    ["h[^e]llo", "hello"],
    ["\\*", "a"],
    ["[ab", "c"],
    ["a*b", "ac"],
    ["a", ""],
    ["*", ""],
    ["", "a"],
  ]

  for pair in yes
    try Test.assert(hit?(pair[0], pair[1]), "#{pair[0]} matches #{pair[1]}")
  end

  for pair in no
    try Test.assert(not hit?(pair[0], pair[1]), "#{pair[0]} does not match #{pair[1]}")
  end

  try Test.assert(hit_nocase?("H*LLO", "heLLo"), "case-blind star")
  try Test.assert(hit_nocase?("[A-C]x", "bX"), "case-blind range")
  Test.assert(not hit?("H*LLO", "hello"), "case matters by default")
end

# Many stars must not cost more than the pattern times the subject: the loops
# ran for minutes when each star recursed.
def test_many_stars_are_fast() -> Result[Void]
  stars = (1..30).to_a.map do |_| "*" end.join("")
  letters = (1..400).to_a.map do |_| "a" end.join("")
  try Test.assert(not hit?(stars + "z", letters), "stars then z")
  spread = (1..20).to_a.map do |_| "*a" end.join("") + "b"
  Test.assert(not hit?(spread, letters), "alternating")
end

def slow(pattern: List[Int], text: List[Int]) -> Bool
  return text.empty? if pattern.empty?

  return slow(pattern.drop(1), text) or (not text.empty? and slow(pattern, text.drop(1))) if pattern[0] == 42

  return false if text.empty?

  (pattern[0] == 63 or pattern[0] == text[0]) and slow(pattern.drop(1), text.drop(1))
end

def code(n: Int) -> Int = [97, 98, 42, 63][n]

# On `a`, `b`, `*` and `?` the matcher agrees with a plain recursive matcher
# (the empty subject aside, which Redis answers with "no" except for the empty
# pattern). Subjects up to 6 bytes, patterns up to 6; 600 runs; the step
# limit comes between 1200 and 2400.
def test_agrees_with_a_slow_matcher() -> Result[Void]
  patterns = Prop.list(Prop.int(0, 3), 6)
  texts = Prop.list(Prop.int(0, 1), 6)
  Prop.check(Prop.pair(patterns, texts), Prop.Config(runs: 600)) do |pair|
    pattern = pair.first.map do |n| code(n) end
    text = pair.second.map do |n| 97 + n end
    expected = slow(pattern, text)
    if text.empty?
      expected = pattern.empty?
    end

    got = Glob.matches?(Bytes.from_list(pattern).unwrap!, Bytes.from_list(text).unwrap!)
    Prop.eq(got, expected)
  end
end
