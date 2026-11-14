import Slot from "../../src/shards/slot"

# The values of Redis: crc16.c's check value and CLUSTER KEYSLOT, with the hash
# tag rules of the cluster spec.
def test_slots_as_redis() -> Result[Void]
  try Test.eq(Slot.crc16("123456789".bytes), 0x31C3)
  try Test.eq(Slot.slot("foo".bytes), 12_182)
  try Test.eq(Slot.slot("{user1000}.following".bytes), Slot.slot("user1000".bytes))
  try Test.eq(Slot.slot("foo{}{bar}".bytes), Slot.crc16("foo{}{bar}".bytes).bit_and(16_383))
  try Test.eq(Slot.slot("foo{{bar}}zap".bytes), Slot.slot("{bar".bytes))
  try Test.eq(Slot.slot("foo{bar}{zap}".bytes), Slot.slot("bar".bytes))
  Test.eq(Slot.shard_of("foo".bytes, 1), 0)
end
