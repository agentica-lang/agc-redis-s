## The one pseudo-random generator of the server: a linear congruential one,
## small and pure. `Store.seed` holds its state; a request takes two steps of it,
## and a command that needs several draws seeds itself from `Call.random`.

## The state is 0 to this, exclusive.
MODULUS = 2_147_483_648

## One step; the product stays under 2^62, so no overflow. A `salt` (the clock
## in the store task) is added so the sequence is not the same after every
## start; the default leaves the plain generator.
def advance(seed: Int, salt: Int = 0) -> Int = (seed * 1_103_515_245 + 12_345 + salt % 65_536) % MODULUS

## A number in 0...size from two steps of the generator. The low bits of a
## linear congruential generator have a short period (the lowest alternates), so
## each step gives its high 15 bits and the two make 30.
def below(high: Int, low: Int, size: Int) -> Int = ((high / 65536) * 32768 + low / 65536) % size

## `count` positions in 0...size, each picked at random with repeats
## (HRANDFIELD, SRANDMEMBER with a negative count); `random` seeds the draws.
def repeating(size: Int, count: Int, random: Int) -> List[Int]
  seed = random % MODULUS
  picked: List[Int] = []
  for _ in 1..count
    first = advance(seed)
    seed = advance(first)
    picked = picked.push(below(first, seed, size))
  end

  picked
end

## `count` different positions of 0...size, in ascending order, every subset
## equally likely (selection sampling: position i is taken with the chance
## needed / left). The count is below the size.
def distinct(size: Int, count: Int, random: Int) -> List[Int]
  seed = random % MODULUS
  picked: List[Int] = []
  for i in 0...size
    first = advance(seed)
    seed = advance(first)
    if below(first, seed, size - i) < count - picked.size
      picked = picked.push(i)
    end
  end

  picked
end

## The positions of 0...size a RANDFIELD or RANDMEMBER count asks for: a
## positive count that covers the size gives all of them in order; a smaller
## one gives that many different positions, also in order (as the listpack case
## of Redis); a negative one (or 1) samples with repeats.
def picks(size: Int, count: Int, random: Int) -> List[Int]
  return repeating(size, 0 - count, random) if count < 0

  return (0...size).to_a if count >= size

  return distinct(size, count, random) if count > 1

  repeating(size, 1, random)
end
