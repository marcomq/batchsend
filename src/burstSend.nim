# BurstSend Library 
# Copyright (C) 2021, by Marco Mengelkoch
# Licensed under MIT License, see License file for more details
# git clone https://github.com/marcomq/burstsend

import asyncnet, asyncdispatch, os, cpuinfo, logging, nimpy
import threadpool
{.experimental: "parallel".}

var timeoutMs* = 5_000
var maxBuffer* = 10_000_000
var target* = "localhost"
var targetPort* = 8000

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
        echo "timed out"
        result = ""
    await client.send(message)
    let sleepFinished = sleepAsync(timeoutMs)
    sleepFinished.addCallback timedOut

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
        result = result & "\n" & msg
        if unlikely(client.isClosed()):
          break receiveLoop
        msg = await client.recvLine()
    requestComplete = true
  except:
    result = ""

proc sendUntilChannelEmpty(client: AsyncSocket, url: string, port: int) {.async.} =
    waitFor client.connect(url, Port(port))
    var received = 0
     # message = "POST http://" & url & ":" & $port & "/ HTTP/1.1\c\LHost: " & url & ":" & $port & "\c\LConnection: keep-alive\c\LContent-Length: 11\c\L\c\LHello World"
    var failCounter = 0
    while failCounter < 10_000 and not abortTransmission:
      var triedMessage = sendQueue.tryRecv()
      if triedMessage.dataAvailable:
        failCounter = 0
        let response = await client.performRequest(triedMessage.msg)
        if unlikely(response.len == 0):
            echo "[ ] ", url
            # client.close()
            # waitFor client.connect(url, Port(port))
        else:
            # echo "[+]", response
            inc(received)
            discard receiveQueue.trySend(response)
      else:
        inc(failCounter)
        if (sendQueue.peek() == 0):
          break
        elif (failCounter mod 100) == 0:
          sleep(1)
    echo received


proc sendAllAndWait(url: string, port: int) =
  let client = newAsyncSocket()
  waitFor client.sendUntilChannelEmpty(url, port)

proc startTransmission*() {.exportpy.} =
  abortTransmission = false
  let numberOfProcessors = 
    if countProcessors() == 0: 4 else: countProcessors()
  debug "starting with " & $numberOfProcessors & " connections/threads"
  parallel:
    for i in 0 ..< numberOfProcessors:
      spawn sendAllAndWait(target, port = 9292)
  debug "Ran successfully"

proc main() =
  setLogFilter(logging.lvlDebug)
  let message = "POST / HTTP/1.1\c\LHost: localhost\c\LConnection: keep-alive\c\LContent-Length: 11\c\L\c\LHello World"
  debug "feeding 1_000_000 messages"
  for i in 0 ..< 1_000_000:
    pushMessage(message)
  startTransmission()

when isMainModule:
  when system.appType != "lib":
    main()