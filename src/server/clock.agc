## The only clock of the server. The core never reads it: `main` hands it to the
## store task, which reads it once per request and passes the value down as `now_ms`.

export def now_ms() -> Int = Time.now_ms()
