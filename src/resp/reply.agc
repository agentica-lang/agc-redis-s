## A reply to a client: the RESP2 types a command can answer with.

export enum Reply
  Simple(String)
  ## The text is bytes because it may echo what the client sent.
  Error(Bytes)
  Integer(Int)
  Bulk(Bytes)
  NilBulk
  Array(List[Reply])
  NilArray
end
