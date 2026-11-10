## The only clock of the server. The core never reads it: the store task reads
## it once per request and passes the value down as `now_ms`.

export def now_ms() -> Int
  return Time.now_ms()
end
