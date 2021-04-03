# batchsend Library 
# Copyright (C) 2021, by Marco Mengelkoch
# Licensed under MIT License, see License file for more details
# git clone https://github.com/marcomq/batchsend

import asyncnet, asyncdispatch, os, cpuinfo, logging
import nimpy
import threadpool
{.experimental: "parallel".}

type SendCfg = object
  timeoutMs: int
  maxBuffer: int
  waitForever: bool
  abortTransmission: bool
  target: string
  port: int
  sendQueue: Channel[string]
  receiveQueue: Channel[string]

proc initSendCfg(
  timeoutMs = 5_000, 
  maxBuffer = 10_000_000,
  waitForever = false,
  abortTransmission = false,
  target = "localhost",
  port = 8000): SendCfg =
    result.timeoutMs = timeoutMs
    result.maxBuffer = maxBuffer
    result.waitForever = waitForever
    result.abortTransmission = abortTransmission
    result.target = target
    result.port = port
    result.sendQueue.open(maxItems = maxBuffer)
    result.receiveQueue.open(maxItems = maxBuffer)


proc newSendCfg*(
  timeoutMs: int = 5_000, 
  maxBuffer: int = 10_000_000,
  waitForever: bool = false,
  abortTransmission: bool = false,
  target: string = "localhost",
  port: int = 8000 ): ref SendCfg {.exportpy.} =
    result.new
    result[] = initSendCfg(
      timeoutMs, maxBuffer, waitForever, abortTransmission, target, port
    )

var loggingEnabled {.threadVar.}: bool


proc setWaitForever*(self: ref SendCfg, value: bool)  {.exportpy, inline.} = 
  self.waitForever = value

proc setAbortTransmission*(self: ref SendCfg, val: bool) {.exportpy, inline.} = 
  self.abortTransmission = val

proc setMaxBuffer*(self: ref SendCfg, val: int) {.exportpy, inline.} = 
  self.maxBuffer = val

proc setTimeoutMs*(self: ref SendCfg, val: int) {.exportpy, inline.} = 
  self.timeoutMs = val

proc checkEnableLogging() =
  if not loggingEnabled: 
    logging.addHandler(logging.newConsoleLogger())
    loggingEnabled = true

proc pushMessage*(self: ref SendCfg, message: string): bool {.discardable, inline, exportpy.} = 
    ## Adds a message to sending queue. Message will be transmitted in TCP, so
    ## you need to add the full HTTP headers etc... in case that the server 
    ## is a HTTP server. Returns true if message added and
    ## false if queue is full
    return self.sendQueue.trySend(message)
    
proc popResponse*(self: ref SendCfg): string {.exportpy, inline.} = 
    ## Removes and returns a message from sending queue. Returns empty string
    ## if queue is empty. May block until next response  
    ## if multiple threads perform popResponse simultaneously.
    let tried = self.receiveQueue.tryRecv()
    if tried.dataAvailable:
      return tried.msg
    elif self.receiveQueue.peek() == 0: 
      return
    else: 
      return self.receiveQueue.recv()

proc discardResponses*(self: ref SendCfg) {.exportpy, inline.} =
    ## performs popRespnse and discards values until response queue is empty
    while (self.receiveQueue.peek() > 0):
      discard self.receiveQueue.tryRecv()

proc performRequest(self: ptr SendCfg, client: AsyncSocket, message: string): Future[string] {.async.} =
  try:
    var requestComplete = false
    var abortMessage = false
    proc timedOut(sleepFinished: Future[void]) =
      if unlikely(not requestComplete):
        abortMessage = true
        error "timed out"
        result = ""
    await client.send(message)
    let sleepFinished = sleepAsync(self.timeoutMs)
    sleepFinished.addCallback timedOut
    let isPost = true # message.startsWith("POST")
    var msg = await client.recvLine()
    var mayReceiveEmptyLine = false
    block receiveLoop:
      while not abortMessage and not self.abortTransmission:
        # echo msg.toHex()
        if (msg.len == 0 or msg == "\c\L" or msg == "0"): # somehow, Nim reads "0" instead of '\0'
          if not mayReceiveEmptyLine: 
            break receiveLoop
          else: 
            mayReceiveEmptyLine = false
        else: 
          mayReceiveEmptyLine = true
        result = result & msg
        if not isPost:
          requestComplete = true
          break receiveLoop
        elif unlikely(client.isClosed()):
          break receiveLoop
        result = result & "\n" 
        msg = await client.recvLine()
    requestComplete = true
  except:
    result = ""

proc sendUntilChannelEmpty(self: ref SendCfg, client: AsyncSocket): Future[int] {.async.} =
    checkEnableLogging()
    waitFor client.connect(self.target, Port(self.port))
    var received = 0
    # echo "POST http://" & target & ":" & $port & "/ HTTP/1.1\c\LHost: " & target & ":" & $port & "\c\LConnection: keep-alive\c\LContent-Length: 11\c\L\c\LHello World"
    var failCounter = 0
    let messages = addr self.sendQueue
    let responses = addr self.receiveQueue
    let selfPtr = addr self[]
    while not self.abortTransmission:
      var triedMessage = messages[].tryRecv()
      if triedMessage.dataAvailable:
        failCounter = 0
        let response = await performRequest(selfPtr, client, triedMessage.msg)
        if unlikely(response.len == 0):
            error "[ ] ", self.target
            if client.isClosed() and self.waitForever:
              waitFor client.connect(self.target, Port(self.port))
        else:
            # info "[+]", response
            inc(received)
            discard responses[].trySend(response)
      else:
        inc(failCounter)
        if (failCounter mod 10) == 0:
          if (messages[].peek() == 0) and (failCounter > 10_000):
            if self.waitForever:
              failCounter = 0
              sleep(100)
            else:
              break
          else:
            sleep(1)
    debug "Thread Received: " & $received
    result = received


proc sendAllAndWait(self: ref SendCfg): int = 
  let client = newAsyncSocket()
  result = waitFor self.sendUntilChannelEmpty(client)

proc startTransmission*(self: ref SendCfg) {.exportpy.} =
  ## Starts multithreaded sending of queue and blocks, until queue is empty
  checkEnableLogging()
  self.abortTransmission = false
  # var targetCopy = self.target & "" # prevent strange bug that causes crash
  let numberOfProcessors = 
    if countProcessors() == 0: 4 else: countProcessors()
  var nrConnections = newSeq[int](numberOfProcessors)
  debug "starting with " & $nrConnections.len & " connections/threads"
  parallel:
    for i in 0 ..< nrConnections.len:
      nrConnections[i] = spawn self.sendAllAndWait()
  var numberOfSentMessages = 0
  for i in 0 ..< nrConnections.len:
    numberOfSentMessages += nrConnections[i]
  info "Transmitted successfully " & $numberOfSentMessages & " messages"

proc spawnTransmissionThread*(self: ref SendCfg) {.inline, exportpy.} =
  ## Starts multithreaded sending of queue but doesn't block. 
  ## An additional "sync()" would wait until all messages are sent.
  ## You may cancel the transmission by setting `abortTransmission = false`
  # var targetCopy = target & "" # prevent strange bug that causes crash
  spawn self.startTransmission()

proc waitForTransmissionThread*() {.inline, exportpy.} = 
  ## Waits for thransmissionthread to finish in blocking mode.
  sync()

proc main() =
  setLogFilter(logging.lvlDebug)
  let message = "POST / HTTP/1.1\c\LHost: localhost\c\LConnection: keep-alive\c\LContent-Length: 11\c\L\c\LHello World"
  var default = newSendCfg(port=9292)
  spawn default.startTransmission()
  checkEnableLogging()
  debug "feeding 100_000 messages"
  for i in 0 ..< 100_000:
    default.pushMessage(message)
  sync()

when isMainModule:
  when system.appType != "lib":
    main()