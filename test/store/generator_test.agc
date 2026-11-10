import Generator from "../../src/store/generator"

# The sequence is part of the contract (a seeded command repeats), so a step is
# pinned: one value, the salt added modulo 65536, and the high bits of two steps.
def test_a_step_and_its_salt() -> Result[Void]
  try Test.eq(Generator.advance(1), 1_103_527_590)
  try Test.eq(Generator.advance(1, 5), 1_103_527_595)
  try Test.eq(Generator.advance(1, 65_536), Generator.advance(1))
  return Test.eq(Generator.below(2_147_483_647, 2_147_483_647, 2_000_000_000), 1_073_741_823)
end
