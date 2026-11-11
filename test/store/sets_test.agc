## The members of a set: the slots stay 0 up to size - 1 with no gap, and the
## index and the slots name each other, whatever the adds and removals.

import Sets from "../../src/store/sets"
import {Members} from "../../src/store/sets"
import Prop from "pkg/prop/prop"

def member(n: Int) -> Bytes = "m#{n % 6}".bytes

# Every slot holds a member whose index entry points back at it, both maps have
# the same size, and the members are those of the model (a Map of the numbers
# added and not removed).
def sound?(members: Members, model: Map[Int, Bool]) -> Bool
  size = Sets.size(members)
  return false if members.index.size != size or model.size != size

  for slot in 0...size
    name = Sets.at(members, slot)
    return false if members.index.get(name, -1) != slot or not model.has_key?(slot_number(name))
  end

  true
end

def slot_number(name: Bytes) -> Int = name[1] - 48

# Adds and removals of six members (an op is the number: odd adds, even removes;
# the member is the number mod 6), 150 runs; the step limit is between 400 and 500.
def test_slots_stay_dense() -> Result[Void]
  ops = Prop.list(Prop.int(0, 255), 40)
  Prop.check(ops, Prop.Config(runs: 150)) do |list|
    members = Sets.empty()
    model: Map[Int, Bool] = {}
    for op in list
      if op % 2 == 1
        members = Sets.add(members, member(op / 2))
        model = model.put((op / 2) % 6, true)
      else
        members = Sets.remove(members, member(op / 2))
        model = model.delete((op / 2) % 6)
      end
    end

    Prop.eq(sound?(members, model), true)
  end
end
