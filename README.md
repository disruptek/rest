# rest

A hack providing convenience around HTTP calls in various projects.

This should always be deprecated in favor of proper interfaces, but let's face
it -- it rarely is.

I don't really want to document this garbage, but I guess I will.

```nim
import rest

pseudo:
  var futures = ...my list of futures...

  for promise in futures.ready:
    promise is a ready future

pseudo:
  var futures = ...my list of futures...
  var promise = futures.first()
  promise is the value of the first ready future

block:
  var
    # compose a call that may be reissued
    request = newRecallable("someurl")

    # get response headers
    response = waitfor request.issueRequest()

  # read the body
  echo waitfor response.body

block:
  var
    request = newRecallable("someurl")

    # retry up to 5 times waiting 1000ms the first
    # time and then following fibonnaci backoff
    response = request.retried()
    echo waitfor reply.body

block:
  var
    request = newRecallable("someurl")

  try:
    # retry up to 3 times waiting 500ms the first
    # time and then following fibonnaci backoff
    for reply in request.retried(tries=3, ms=500):
      if not reply.code.is2xx:
        continue
      echo waitfor reply.body
  except RetriesExhausted:
    echo "tried three times and then gave up"

block:
  var
    request = newRecallable("someurl")
    reply = waitfor request.retry()
  echo waitfor reply.body
```
