## The order and the pages of SCAN. The keys are ordered by a hash of their
## name, and the cursor is a hash: a page holds the keys whose hash is at least
## the cursor, and the next cursor is the hash of the first key left. Adding or
## removing keys never moves the others in that order, so every key that stays
## for the whole scan is in exactly one page (Redis's guarantee). Keys with the
## same hash are never split between two pages.

struct Page
  keys: List[Bytes]
  ## 0 when this page was the last one.
  next: Int
end

def hash(key: Bytes) -> Int
  total = 0
  for byte in key
    total = (total * 257 + byte + 1) % MODULUS
  end

  total
end

## About `count` keys (more when hashes are equal), from the cursor on. It hashes
## and sorts every key name each call, unlike Redis's table walk: O(n log n) per
## page. Names chosen to have the same hash make a big page (the hash is not
## secret), which only costs the client that sent them.
def page(names: List[Bytes], cursor: Int, count: Int) -> Page
  ranked = names.map do |key| Ranked(rank: hash(key), key: key) end
  later = ranked.select do |item| item.rank >= cursor end
  ordered = later.sort_by do |item| item.rank end
  taken = take_count(ordered, count)
  return Page(keys: ordered.map do |item| item.key end, next: 0) if taken >= ordered.size

  Page(keys: ordered.take(taken).map do |item| item.key end, next: ordered[taken].rank)
end

private

# The largest prime under 2^32: a hash is below it, and the multiply in `hash`
# stays under 2^41.
MODULUS = 4_294_967_291

struct Ranked
  rank: Int
  key: Bytes
end

# How many to take: `count`, then on while the next key has the hash of the last.
def take_count(ordered: List[Ranked], count: Int) -> Int
  taken = count
  return ordered.size if taken > ordered.size

  while taken < ordered.size and ordered[taken].rank == ordered[taken - 1].rank
    taken += 1
  end

  taken
end
