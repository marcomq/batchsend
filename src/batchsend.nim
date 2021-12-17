# batchsend Library 
# Copyright (C) 2021, by Marco Mengelkoch
# Licensed under MIT License, see License file for more details
# git clone https://github.com/marcomq/batchsend

import asyncnet, net, asyncdispatch, os, cpuinfo, logging, strutils
import nimpy
import threadpool
{.experimental: "parallel".}     
type  
  SendCfg = ref object of PyNimObjectExperimental
    timeoutMs: int
    maxBuffer: int
    waitForever: bool
    abortTransmission: ptr bool
    target: string
    port: int
    useSsl: bool
    sendQueue: ptr Channel[string]
    receiveQueue: ptr Channel[string]

proc newSendCfg*(
  timeoutMs: int = 5_000, 
  maxBuffer: int = 10_000_000,
  waitForever: bool = false,
  abortTransmission: bool = false,
  target: string = "localhost",
  port: int = 8000,
  useSsl: bool = false ): SendCfg {.exportpy.} =
    result.new
    result.timeoutMs = timeoutMs
    result.maxBuffer = maxBuffer
    result.waitForever = waitForever
    result.abortTransmission = cast[ptr bool](
      allocShared0(sizeof(bool))
    )
    result.abortTransmission[] = abortTransmission
    result.target = target
    result.port = port
    result.useSsl = useSsl
    result.sendQueue = cast[ptr Channel[string]](
      allocShared0(sizeof(Channel[string]))
    )
    result.receiveQueue = cast[ptr Channel[string]](
      allocShared0(sizeof(Channel[string]))
    )
    result.sendQueue[].open(maxItems = maxBuffer)
    result.receiveQueue[].open(maxItems = maxBuffer)

var loggingEnabled {.threadVar.}: bool

proc checkEnableLogging() =
  if not loggingEnabled: 
    logging.addHandler(logging.newConsoleLogger())
    loggingEnabled = true

proc setAbortTransmission*(self: SendCfg, val: bool) {.exportpy, inline.} = 
  self[].abortTransmission[] = val
  checkEnableLogging()

proc pushMessage*(self: SendCfg, message: string): bool {.exportpy, discardable, inline.} = 
    ## Adds a message to sending queue. Message will be transmitted in TCP, so
    ## you need to add the full HTTP headers etc... in case that the server 
    ## is a HTTP server. Returns true if message added and
    ## false if queue is full
    return self.sendQueue[].trySend(message)
    
proc popResponse*(self: SendCfg): string {.exportpy, inline.} = 
    ## Removes and returns a message from sending queue. Returns empty string
    ## if queue is empty. May block until next response  
    ## if multiple threads perform popResponse simultaneously.
    let tried = self.receiveQueue[].tryRecv()
    if tried.dataAvailable:
      return tried.msg
    elif self.receiveQueue[].peek() == 0: 
      return
    else: 
      return self.receiveQueue[].recv()

proc discardResponses*(self: SendCfg) {.inline.} =
    ## performs popRespnse and discards values until response queue is empty
    while (self.receiveQueue[].peek() > 0):
      discard self.receiveQueue[].tryRecv()

proc performRequest(self: SendCfg, client: AsyncSocket, message: string): Future[string] {.async.} =
  try:
    var requestComplete = false
    var abortMessage = false
    proc timedOut(sleepFinished: Future[void]) =
      if unlikely(not requestComplete):
        abortMessage = true
        error "timed out"
        result = ""
    let sleepFinished = sleepAsync(self.timeoutMs)
    sleepFinished.addCallback timedOut
    let isPost = message.startsWith("POST")
    asyncCheck client.send(message)
    var msg = await client.recvLine()
    var mayReceiveEmptyLine = false
    block receiveLoop:
      while not abortMessage and not self.abortTransmission[]:
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
        let lowerMsg = msg.toLower()
        if lowerMsg.startsWith("content-length:"):
          let contentLength = lowerMsg.replace("content-length:", "").replace(" ", "")
          msg = await client.recv(contentLength.parseInt())
          result = result & msg & "\n"
          break receiveLoop
        else: 
          msg = await client.recvLine()

    requestComplete = true
  except:
    result = ""

proc sendUntilChannelEmpty(self: SendCfg): Future[int] {.async.} =
    checkEnableLogging()
    let client = newAsyncSocket()
    when defined ssl:
      var ctx = newContext(verifyMode = CVerifyNone)
      if self.useSsl:
        wrapSocket(ctx, client)
    try: 
      await client.connect(self.target, Port(self.port))
    except:
      error "Couldn't connect to socket"
      return 0
    var received = 0
    # echo "POST http://" & target & ":" & $port & "/ HTTP/1.1\c\LHost: " & target & ":" & $port & "\c\LConnection: keep-alive\c\LContent-Length: 11\c\L\c\LHello World"
    var failCounter = 0
    while not self.abortTransmission[]:
      var triedMessage = self.sendQueue[].tryRecv()
      if triedMessage.dataAvailable:
        failCounter = 0
        # measureStart
        let response = await performRequest(self, client, triedMessage.msg)
        if unlikely(response.len == 0):
            # measureEnd
            error "[ ] ", self.target
            if client.isClosed() and self.waitForever:
              waitFor client.connect(self.target, Port(self.port))
        else:
            # measureEnd
            # info "[+]", response
            inc(received)
            discard self.receiveQueue[].trySend(response)
      else:
        inc(failCounter)
        if (failCounter mod 100) == 0:
          if (self.sendQueue[].peek() == 0) and (failCounter > 10_000):
            if self.waitForever:
              failCounter = 0
              sleep(100)
            else:
              break
          else:
            sleep(1)
    debug "Responses for thread: " & $received
    result = received


proc sendAllAndWait(self: SendCfg): int = 
  result = waitFor self.sendUntilChannelEmpty()

proc startTransmission*(self: SendCfg) {.exportpy.} =
  ## Starts multithreaded sending of queue and blocks, until queue is empty
  checkEnableLogging()
  self.abortTransmission[] = false
  # var targetCopy = self.target & "" # prevent strange bug that causes crash
  let numberOfProcessors = 
    if countProcessors() == 0: 4 else: countProcessors()
  var nrConnections = newSeq[int](numberOfProcessors)
  debug "starting with " & $nrConnections.len & " connections/threads"
  assert(numberOfProcessors == nrConnections.len)
  parallel:
    for i in 0 ..< nrConnections.len:
      nrConnections[i] = spawn self.sendAllAndWait()
  var numberOfSentMessages = 0
  for i in 0 ..< nrConnections.len:
    numberOfSentMessages += nrConnections[i]
  info "Transmitted " & $numberOfSentMessages & " messages"

proc spawnTransmissionThread*(self: SendCfg) {.exportpy, inline.} =
  ## Starts multithreaded sending of queue but doesn't block. 
  ## An additional "sync()" would wait until all messages are sent.
  ## You may cancel the transmission by setting `abortTransmission = false`
  # var targetCopy = target & "" # prevent strange bug that causes crash
  spawn self.startTransmission()

proc waitForSpawnedThreads*() {.exportpy, inline.} = 
  ## Waits for thransmissionthread to finish in blocking mode.
  sync()

proc main() =
  setLogFilter(logging.lvlDebug)
  checkEnableLogging()
  let message = "POST / HTTP/1.1\c\LHost: localhost\c\LConnection: keep-alive\c\LContent-Length: 11\c\L\c\LHello World"
  var default = newSendCfg(port=9292)
  info "spawning"
  spawn default.startTransmission()
  debug "feeding 1_000_000 messages"
  for i in 0 ..< 1_000_000:
    default.pushMessage(message)
  sync()

when isMainModule:
  when system.appType != "lib":
    main()