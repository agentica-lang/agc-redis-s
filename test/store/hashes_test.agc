## The random positions HRANDFIELD uses.

import Hashes from "../../src/store/hashes"

# A draw of 64 positions in a hash of 2 must not split 32 and 32 for every
# seed: the low bits of the generator alternate, which made it so.
def test_repeating_draws_are_not_always_even() -> Result[Void]
  splits = (1..12).to_a.map do |seed| Hashes.sample_repeating(2, 64, seed * 7919).select do |at| at == 0 end.size end

  try Test.assert(splits.any? do |zeros| zeros != 32 end, "every split was 32/32: #{splits}")
  try Test.assert(splits.all? do |zeros| zeros > 10 and zeros < 54 end, "a split is too lopsided: #{splits}")
  return Test.assert(
    Hashes.sample_repeating(1000, 500, 5).all? do |at| at >= 0 and at < 1000 end,
    "positions are in range",
  )
end

# Different positions, ascending, as many as asked, for a few sizes and seeds.
def test_distinct_draws() -> Result[Void]
  for seed in 1..20
    picked = Hashes.sample_distinct(10, 4, seed * 104_729)
    try Test.assert(picked.size == 4 and picked.sort == picked and picked.uniq.size == 4, "bad draw: #{picked}")
  end

  return Test.eq(Hashes.sample_distinct(5, 1, 3).size, 1)
end
