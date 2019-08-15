#? replace(sub = "\t", by = " ")
import os
import times
import deques
import sequtils
import httpclient
import httpcore
import asyncdispatch
import json
import xmltree

import fibonacci
import tools

type
	JsonResultPage* = JsonNode
	JsonPageFuture* = Future[JsonResultPage]

	XmlResultPage* = XmlNode
	XmlPageFuture* = Future[XmlResultPage]

	ResultPage* = JsonNode | XmlNode
	PageFuture* = Future[ResultPage]

	RestClientObj = object of RootObj
		keepalive: bool
		http: AsyncHttpClient
		headers: HttpHeaders
	RestClient* = ref RestClientObj

	RestCall* = object of RootObj
		client: RestClient
		name: string

	FutureQueueFifo* = Deque
	PageFuturesFifo*[T] = Deque[T]

	FutureQueueSeq* = seq
	PageFuturesSeq*[T] = seq[T]

	Recallable* = ref object of RootObj
		## a handle on input/output of a re-issuable API call
		headers*: HttpHeaders
		client*: RestClient
		url*: string
		json*: JsonNode
		body*: string
		retries*: int
		began*: Time
		took*: Duration
		meth*: HttpMethod
	RestError* = object of CatchableError       ## base for REST errors
	AsyncError* = object of RestError           ## undefined async error
	RetriesExhausted* = object of RestError     ## ran outta retries
	CallRequestError* = object of RestError     ## HTTP [45]00 status code

	Format* = enum JSON, XML

proc add*[T](futures: var PageFuturesFifo[T], value: PageFuture)
	{.raises: [].} =
	futures.addLast(value)

method `$`*(e: ref RestError): string
	{.raises: [].}=
	result = $typeof(e) & " " & e.msg

method initRestClient*(self: RestClient) {.base.} =
	self.http = newAsyncHttpClient()

proc newRestClient*(): RestClient =
	new result
	result.initRestClient()

#[
method `=headers`(self: var RestClient; headers: HttpHeaders)
	{.base, raises: [Exception].} =
	self.http.headers = headers
]#

method newRecallable*(call: RestCall; url: string;
	headers: openArray[tuple[key: string, val: string]]): Recallable
	{.base,raises: [Exception].} =
	## make a new HTTP request that we can reissue if desired
	new result
	result.url = url
	result.retries = 0
	##
	## XXX
	##
	## might need to disambiguate responses to requests
	##
	if call.client != nil and call.client.keepalive:
		result.client = call.client
	else:
		result.client = newRestClient()
	result.headers = newHttpHeaders(headers)
	result.client.headers = result.headers
	result.client.http.headers = result.headers
	result.meth = HttpPost

method newRecallable*(call: RestCall; url: string): Recallable
	{.base,raises: [Exception].} =
	result = call.newRecallable(url, [])

proc issueRequest*(rec: Recallable): Future[AsyncResponse]
	{.raises: [AsyncError].} =
	## submit a request and store some metrics
	assert rec.client != nil
	try:
		if rec.body == "":
			if rec.json != nil:
				rec.body = $rec.json
		rec.began = getTime()
		##
		## FIXME
		##
		## move this header-fu into something restClient-specific
		if rec.headers != nil:
			rec.client.http.headers = rec.headers
		elif rec.client.headers != nil:
			rec.client.http.headers = rec.client.headers
		else:
			rec.client.http.headers = newHttpHeaders()
		result = case rec.meth:
			of HttpPost: rec.client.http.post(rec.url, body=rec.body)
			of HttpGet: rec.client.http.get(rec.url)
			else:
				raise newException(AsyncError, "undefined http method: " & $rec.meth)
	except CatchableError as e:
		raise newException(AsyncError, e.msg)
	except Exception as e:
		raise newException(AsyncError, e.msg)

proc ok200*(response: AsyncResponse): bool
	{.raises: [].} =
	## true if the response indicates success
	try:
		let code = response.code()
		return (200 <= ord(code) and ord(code) < 300)
	except:
		return false

proc err400*(response: AsyncResponse): bool
	{.raises: [].} =
	## true if the response indicates a request error
	try:
		let code = response.code()
		return (400 <= ord(code) and ord(code) < 500)
	except:
		return false

proc err300*(response: AsyncResponse): bool
	{.raises: [].} =
	try:
		let code = response.code()
		return (300 <= ord(code) and ord(code) < 400)
	except:
		return false

proc err500*(response: AsyncResponse): bool
	{.raises: [].} =
	try:
		let code = response.code()
		return (500 <= ord(code) and ord(code) < 600)
	except:
		return true

proc retried*(rec: Recallable; tries=5): AsyncResponse
	{.raises: [RestError].} =
	## issue the call and return the response synchronously;
	## raises in the event of a failure
	try:
		for fib in fibonacci(0, tries):
			result = waitfor rec.issueRequest()
			if result.ok200():
				return
			if result.err400():
				error waitfor result.body
				raise newException(CallRequestError, result.status)
			warn result.status, "; sleeping", fib, "secs and retrying..."
			sleep fib * 1000
			rec.retries.inc()
	except RestError as e:
		raise e
	except CatchableError as e:
		raise newException(AsyncError, e.msg)
	except Exception as e:
		raise newException(AsyncError, e.msg)
	raise newException(RetriesExhausted, "Exhausted " & $tries & " retries")

proc retry*(rec: Recallable; tries=5): Future[AsyncResponse]
	{.async.} =
	## try to issue the call and return the response; only
	## retry if the status code is 1XX, 3XX, or 5XX.
	var response: AsyncResponse
	try:
		for fib in fibonacci(0, tries):
			response = await rec.issueRequest()
			if response.ok200():
				return response
			if response.err400():
				raise newException(CallRequestError, response.status)
			warn response.status, "; sleeping", fib, "secs and retrying..."
			await sleepAsync(fib * 1000)
			rec.retries.inc()
	except RestError as e:
		raise e
	except CatchableError as e:
		raise newException(AsyncError, e.msg)
	except Exception as e:
		raise newException(AsyncError, e.msg)
	if true:
		raise newException(RetriesExhausted, "Exhausted " & $tries & " retries")

iterator retried*(rec: Recallable; tries=5): AsyncResponse
	{.raises: [RestError].} =
	## synchronously do something every time the response comes back;
	## the iterator does not terminate if the request was successful;
	## obviously, you can terminate early.
	var response: AsyncResponse
	try:
		for fib in fibonacci(0, tries):
			response = waitfor rec.issueRequest()
			if response.err400():
				raise newException(CallRequestError, response.status)
			yield response
			warn response.status, "; sleeping", fib, "secs and retrying..."
			sleep(fib * 1000)
			rec.retries.inc()
	except RestError as e:
		raise e
	except CatchableError as e:
		raise newException(AsyncError, e.msg)
	except Exception as e:
		raise newException(AsyncError, e.msg)

proc errorFree*[T](rec: Recallable; call: T; tries=5): Future[string]
	{.async.} =
	## issue and re-issue a recallable until it yields a response
	var
		response: AsyncResponse
		text: string
	# this is sorta broken; we keep starting over on retries until we
	# 1. exhaust retries
	# 2. otherwise raise an exception
	# 3. get a valid response (with bad data in it)
	# 4. get a valid response with good data in it
	while true:
		try:
			response = await rec.retry(tries=tries)
			rec.took = getTime() - rec.began
			if not response.ok200():
				warn call, "retry number", rec.retries
				continue
			return await response.body
		except RestError as e:
			raise e
		except CatchableError as e:
			raise newException(AsyncError, e.msg)
		except Exception as e:
			raise newException(AsyncError, e.msg)
		finally:
			rec.took = getTime() - rec.began
			info call, "total request", rec.took

proc expectPages*(entries: int; total: int): int
	{.raises: [].} =
	## calculate how many pages we should fetch given entries, total
	result = case entries:
		of 0: 0
		else:
			case total:
				of 0: 0
				else:
					if total mod entries == 0:
						total div entries
					else:
						1 + total div entries

proc `or`*[T](fut1: Future[T], fut2: Future[T]): Future[T]
	{.raises: [Exception].} =
	## Returns a future which will complete once either ``fut1`` or ``fut2``
	## complete.
	var retFuture = newFuture[T]("or of two futures of the same type")
	proc cb[X](fut: Future[X]) =
		if retFuture.finished:
			return
		if fut.failed:
			retFuture.fail(fut.error)
		else:
			retFuture.complete(fut.read)
	fut1.addCallback cb[T]
	fut2.addCallback cb[T]
	result = retFuture

proc any*[T](futures: varargs[Future[T]]): Future[T]
	{.raises: [Defect, Exception].} =
	## wait for any of the input futures to complete; yield the value
	assert futures.len != 0
	case futures.len:
		of 0:
			raise newException(Defect, "any called without futures")
		of 1:
			result = futures[futures.low]
		else:
			var future = newFuture[T]("any")
			proc anycb[T](promise: Future[T])
				{.raises: [Exception].} =
				if future.finished:
					return
				if promise.failed:
					future.fail(promise.error)
				else:
					future.complete(promise.read)
			for vow in futures:
				vow.addCallback anycb[T]
			result = future

iterator ready*[T](futures: var PageFuturesSeq[T]; threads=0): T
	{.raises: [Exception]} =
	## iteratively drain a queue of futures
	var ready: PageFuturesSeq[T]
	while futures.len > 0:
		ready = futures.filterIt(it.finished)
		futures.keepItIf(not it.finished)
		if ready.len == 0:
			if futures.len <= threads:
				break
			discard waitfor futures.any()
			continue
		else:
			debug "futures ready:", ready.len, "unready:", futures.len
		for vow in ready:
			if vow.failed:
				raise vow.error
			yield vow


when isMainModule:
	import unittest

	suite "rest":
		type
			TestCall = object of RestCall

		const URL = "http://api.auctionhero.io/"

		setup:
			var
				call = TestCall()
				rec = call.newRecallable(URL)

		teardown:
			notice "(latency of below test)"

		test "retried via procs":
			var response = rec.retried()
			check response.ok200()
			var text = waitfor response.body
			check text != ""

		test "retried via iteration":
			var text: string
			for response in rec.retried(tries=5):
				if not response.ok200:
					warn "retried", rec.retries, "took", rec.took.ft()
					continue
				text = waitfor response.body
				check text != ""
				break

		test "async retry":
			var response = waitfor rec.retry()
			check response.ok200()
			var text = waitfor response.body
			check text != ""
