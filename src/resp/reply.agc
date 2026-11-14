## A reply to a client: the RESP2 types a command can answer with.

enum Reply
  Simple(String)
  ## The text is bytes because it may echo what the client sent.
  Error(Bytes)
  Integer(Int)
  Bulk(Bytes)
  NilBulk
  Array(List[Reply])
  NilArray
  ## Bytes already in RESP form, written as they are: a command that builds a
  ## long reply in one pass (LRANGE) skips one `Reply` and one encode per item.
  Raw(Bytes)
end
