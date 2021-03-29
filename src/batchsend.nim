# batchsend Library 
# Copyright (C) 2021, by Marco Mengelkoch
# Licensed under MIT License, see License file for more details
# git clone https://github.com/marcomq/batchsend

import asyncnet, asyncdispatch, os, cpuinfo, logging
import nimpy
import threadpool
{.experimental: "parallel".}

var timeoutMs* = 5_000
var maxBuffer* = 10_000_000

var abortTransmission* = false
var sendQueue: Channel[string]
var receiveQueue: Channel[string]
sendQueue.open(maxItems = maxBuffer)
receiveQueue.open(maxItems = maxBuffer)
var loggingEnabled {.threadVar.}: bool

proc checkEnableLogging() =
  if not loggingEnabled: 
    logging.addHandler(logging.newConsoleLogger())
    loggingEnabled = true

proc pushMessage*(message: string): bool {.discardable, inline, exportpy.} = 
    ## Adds a message to sending queue. Message will be transmitted in TCP, so
    ## you need to add the full HTTP headers etc... in case that the server 
    ## is a HTTP server. Returns true if message added and
    ## false if queue is full
    return sendQueue.trySend(message)
    
proc popResponse*(): string {.exportpy, inline.} = 
    ## Removes and returns a message from sending queue. Returns empty string
    ## if queue is empty. May block until next response  
    ## if multiple threads perform popResponse simultaneously.
    let tried = receiveQueue.tryRecv()
    if tried.dataAvailable:
      return tried.msg
    elif receiveQueue.peek() == 0: 
      return
    else: 
      return receiveQueue.recv()

proc discardResponses*() {.exportpy, inline.} =
    ## performs popRespnse and discards values until response queue is empty
    while (receiveQueue.peek() > 0):
      discard receiveQueue.tryRecv()

proc performRequest(client: AsyncSocket, message: string): Future[string] {.async.} =
  try:
    var requestComplete = false
    var abortMessage = false
    proc timedOut(sleepFinished: Future[void]) =
      if unlikely(not requestComplete):
        abortMessage = true
        error "timed out"
        result = ""
    await client.send(message)
    let sleepFinished = sleepAsync(timeoutMs)
    sleepFinished.addCallback timedOut
    let isPost = true # message.startsWith("POST")
    var msg = await client.recvLine()
    var mayReceiveEmptyLine = false
    block receiveLoop:
      while not abortMessage and not abortTransmission:
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

proc sendUntilChannelEmpty(client: AsyncSocket, target: string, port: int): Future[int] {.async.} =
    waitFor client.connect(target, Port(port))
    var received = 0
    # echo "POST http://" & target & ":" & $port & "/ HTTP/1.1\c\LHost: " & target & ":" & $port & "\c\LConnection: keep-alive\c\LContent-Length: 11\c\L\c\LHello World"
    var failCounter = 0
    while not abortTransmission:
      var triedMessage = sendQueue.tryRecv()
      if triedMessage.dataAvailable:
        failCounter = 0
        let response = await client.performRequest(triedMessage.msg)
        if unlikely(response.len == 0):
            error "[ ] ", target
            # client.close()
            # waitFor client.connect(target, Port(port))
        else:
            # info "[+]", response
            inc(received)
            discard receiveQueue.trySend(response)
      else:
        inc(failCounter)
        if (failCounter mod 100) == 0:
          if (sendQueue.peek() == 0) and (failCounter > 10_000):
            break
          else:
            sleep(1)
    debug "Thread Received: " & $received
    result = received


proc sendAllAndWait(target: string, port: int): int = 
  let client = newAsyncSocket()
  result = waitFor client.sendUntilChannelEmpty(target, port)

proc startTransmission*(target: string, port: int) {.exportpy.} =
  ## Starts multithreaded sending of queue and blocks, until queue is empty
  checkEnableLogging()
  abortTransmission = false
  var targetCopy = target & "" # prevent strange bug that causes crash
  let numberOfProcessors = 
    if countProcessors() == 0: 4 else: countProcessors()
  var nrMessages = newSeq[int](numberOfProcessors)
  debug "starting with " & $nrMessages.len & " connections/threads"
  parallel:
    for i in 0 ..< nrMessages.len:
      nrMessages[i] = spawn sendAllAndWait(targetCopy, port)
  var numberOfSentMessages = 0
  for i in 0 ..< nrMessages.len:
    numberOfSentMessages += nrMessages[i]
  info "Transmitted successfully " & $numberOfSentMessages & " messages"

proc spawnTransmissionThread*(target:string = "localhost", port: int = 8000) {.inline, exportpy.} =
  ## Starts multithreaded sending of queue but doesn't block. 
  ## An additional "sync()" would wait until all messages are sent.
  ## You may cancel the transmission by setting `abortTransmission = false`
  var targetCopy = target & "" # prevent strange bug that causes crash
  spawn startTransmission(targetCopy, port)

proc waitForTransmissionThread*() {.inline, exportpy.} = 
  ## Waits for thransmissionthread to finish in blocking mode.
  sync()

proc main() =
  setLogFilter(logging.lvlDebug)
  let message = "POST / HTTP/1.1\c\LHost: localhost\c\LConnection: keep-alive\c\LContent-Length: 11\c\L\c\LHello World"
  spawnTransmissionThread("localhost", port = 9292)
  debug "feeding 1_000_000 messages"
  for i in 0 ..< 1_000_000:
    pushMessage(message)
  waitForTransmissionThread()
    
checkEnableLogging()

when isMainModule:
  when system.appType != "lib":
    main()