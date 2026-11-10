## A reply to a client: the RESP2 types a command can answer with.

export enum Reply
  Simple(String)
  Error(String)
  Integer(Int)
  Bulk(Bytes)
  NilBulk
  Array(List[Reply])
  NilArray
end
