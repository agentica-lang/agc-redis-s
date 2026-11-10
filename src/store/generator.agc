## The one pseudo-random generator of the server: a linear congruential one,
## small and pure. `Store.seed` holds its state; a request takes two steps of it,
## and a command that needs several draws seeds itself from `Call.random`.

## The state is 0 to this, exclusive.
export MODULUS = 2_147_483_648

## One step; the product stays under 2^62, so no overflow. A `salt` (the clock
## in the store task) is added so the sequence is not the same after every
## start; the default leaves the plain generator.
export def advance(seed: Int, salt: Int = 0) -> Int
  return (seed * 1_103_515_245 + 12_345 + salt % 65_536) % MODULUS
end

## A number in 0...size from two steps of the generator. The low bits of a
## linear congruential generator have a short period (the lowest alternates), so
## each step gives its high 15 bits and the two make 30.
export def below(high: Int, low: Int, size: Int) -> Int
  return ((high / 65536) * 32768 + low / 65536) % size
end
