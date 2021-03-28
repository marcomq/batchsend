# BurstSend Library 
# Copyright (C) 2021, by Marco Mengelkoch
# Licensed under MIT License, see License file for more details
# git clone https://github.com/marcomq/burstsend

import asyncnet, asyncdispatch, os, cpuinfo, logging
import nimpy
import threadpool
{.experimental: "parallel".}

var timeoutMs* = 5_000
var maxBuffer* = 10_000_000
var target* = "localhost"

var abortTransmission* = false
var sendQueue: Channel[string]
var receiveQueue: Channel[string]
sendQueue.open(maxItems = maxBuffer)
receiveQueue.open(maxItems = maxBuffer)

logging.addHandler(logging.newConsoleLogger())

proc pushMessage*(message: string): bool {.discardable, exportpy.} = 
    return sendQueue.trySend(message)
    
proc popResponse*(): string {.exportpy.} = 
    let tried = receiveQueue.tryRecv()
    if tried.dataAvailable:
      return tried.msg
    elif receiveQueue.peek() == 0: 
      return
    else: 
      return receiveQueue.recv()

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
    while failCounter < 10_000 and not abortTransmission:
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
        if (sendQueue.peek() == 0):
          break
        elif (failCounter mod 100) == 0:
          sleep(1)
    debug "Thread Received: " & $received
    result = received


proc sendAllAndWait(target: string, port: int): int = 
  let client = newAsyncSocket()
  result = waitFor client.sendUntilChannelEmpty(target, port)

proc startTransmission*(target: string, port: int) {.exportpy.} =
  abortTransmission = false
  var targetCopy = target & "" # strange bug that causes crash
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
  var targetCopy = target & "" # strange bug that causes crash
  spawn startTransmission(targetCopy, port)

proc main() =
  setLogFilter(logging.lvlDebug)
  let message = "POST / HTTP/1.1\c\LHost: localhost\c\LConnection: keep-alive\c\LContent-Length: 11\c\L\c\LHello World"
  debug "feeding 1_000_000 messages"
  for i in 0 ..< 1_000_000:
    pushMessage(message)
  startTransmission("localhost", port = 9292)

when isMainModule:
  when system.appType != "lib":
    main()