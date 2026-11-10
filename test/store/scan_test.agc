## The pages of SCAN: every key that stays for the whole scan is in a page.

import Scan from "../../src/store/scan"
import Prop from "pkg/prop/prop"

def named(prefix: String, ids: List[Int]) -> List[Bytes]
  return ids.map do |id| "#{prefix}#{id}".bytes end
end

# The pages of a scan that loses one of the keys it has not met and gains a new
# one after every page: the whole scan, as the keys it returned.
def walk(start: List[Bytes], count: Int) -> List[Bytes]
  names = start
  seen: List[Bytes] = []
  cursor = 0
  step = 0
  for _ in 0...200
    got = Scan.page(names, cursor, count)
    seen = seen.concat(got.keys)
    cursor = got.next
    if cursor == 0
      break
    end

    step += 1
    names = names.select do |key| key != "drop#{step}".bytes end.push("new#{step}".bytes)
  end

  return seen
end

# `brgrn` and `cnmnj` have the same hash: a page never splits them, even with a
# COUNT of 1, or the cursor would skip one.
def test_equal_hashes_stay_in_one_page() -> Result[Void]
  pair = ["brgrn".bytes, "cnmnj".bytes]
  try Test.eq(Scan.hash(pair[0]), Scan.hash(pair[1]))
  got = Scan.page(pair, 0, 1)
  try Test.eq(got.keys.size, 2)
  return Test.eq(got.next, 0)
end

# Any keys, a COUNT of 1 to 5, and keys that come and go between the pages: the
# keys that were there the whole time are all returned.
def test_scan_returns_every_key_that_stays() -> Result[Void]
  ids = Prop.list(Prop.int(0, 20), 12)
  return Prop.check(Prop.pair(ids, Prop.int(1, 5)), Prop.Config(runs: 60)) do |input|
    stable = named("stay", input.first)
    start = stable.concat(named("drop", (1...12).to_a))
    seen = walk(start, input.second)
    missed = stable.select do |key| not seen.include?(key) end
    Prop.eq(missed.size, 0)
  end
end

# An empty or a past-the-end cursor ends the scan at once.
def test_cursor_past_the_end() -> Result[Void]
  names = named("k", [1, 2, 3])
  try Test.eq(Scan.page([], 0, 10), Scan.Page(keys: [], next: 0))
  return Test.eq(Scan.page(names, 5_000_000_000, 10), Scan.Page(keys: [], next: 0))
end
