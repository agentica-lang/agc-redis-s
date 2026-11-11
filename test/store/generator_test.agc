import Generator from "../../src/store/generator"

# The sequence is part of the contract (a seeded command repeats), so a step is
# pinned: one value, the salt added modulo 65536, and the high bits of two steps.
def test_a_step_and_its_salt() -> Result[Void]
  try Test.eq(Generator.advance(1), 1_103_527_590)
  try Test.eq(Generator.advance(1, 5), 1_103_527_595)
  try Test.eq(Generator.advance(1, 65_536), Generator.advance(1))
  Test.eq(Generator.below(2_147_483_647, 2_147_483_647, 2_000_000_000), 1_073_741_823)
end

# A draw of 64 positions in a set of 2 must not split 32 and 32 for every
# seed: the low bits of the generator alternate, which made it so.
def test_repeating_draws_are_not_always_even() -> Result[Void]
  splits = (1..12).to_a.map do |seed| Generator.repeating(2, 64, seed * 7919).select do |at| at == 0 end.size end

  try Test.assert(splits.any? do |zeros| zeros != 32 end, "every split was 32/32: #{splits}")
  try Test.assert(splits.all? do |zeros| zeros > 10 and zeros < 54 end, "a split is too lopsided: #{splits}")
  Test.assert(Generator.repeating(1000, 500, 5).all? do |at| at >= 0 and at < 1000 end, "positions are in range")
end

# Different positions, ascending, as many as asked, for a few sizes and seeds.
def test_distinct_draws() -> Result[Void]
  for seed in 1..20
    picked = Generator.distinct(10, 4, seed * 104_729)
    try Test.assert(picked.size == 4 and picked.sort == picked and picked.uniq.size == 4, "bad draw: #{picked}")
  end

  Test.eq(Generator.distinct(5, 1, 3).size, 1)
end
