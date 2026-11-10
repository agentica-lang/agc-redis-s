## What one client carries between its commands: the selected database and
## what it told about itself. It is an input of a handler (`Call.session`) and
## an output (`Outcome.session`); the store task keeps it per client.

export struct Session
  ## Index of the selected database.
  db: Int = 0
  ## `none` when never set, or set to the empty text, as Redis does.
  name: Optional[Bytes] = none
  lib_name: Optional[Bytes] = none
  lib_ver: Optional[Bytes] = none
end
