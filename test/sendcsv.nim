# batchsend Library 
# Copyright (C) 2021, by Marco Mengelkoch
# Licensed under MIT License, see License file for more details
# git clone https://github.com/marcomq/batchsend

## reads csv file and sends it as xml to server
## Important: Doesn't do perform XML or csv escapes!

import parsecsv
from os import paramStr, paramCount
from streams import newFileStream
import ../src/batchsend

proc sendCsv(csvFile: string) =
  var httpHeader = "POST / HTTP/1.1\c\LHost: localhost\c\LConnection: keep-alive\c\LContent-Length: "
  var s = newFileStream(csvFile, fmRead)
  if s == nil:
    raise newException(CatchableError, "Cannot open the file" & csvFile)

  var parser: CsvParser
  open(parser, s, paramStr(1))
  parser.readHeaderRow()
  if parser.headers.len == 0:
    raise newException(CatchableError, "Cannot read csv header")
  let transmitter = batchsend.newSendCfg(port=9292)
  transmitter.spawnTransmissionThread()

  while readRow(parser):
    var message: string
    var i = 0
    for val in items(parser.row):
      if i < parser.headers.len:
        message &= "<" & parser.headers[i] & ">" & val & "</" & parser.headers[i] & ">"
        inc(i)
    let httpMessage = httpHeader & $message.len & "\c\L\c\L" & message
    transmitter.pushMessage(httpMessage)
  close(parser)
  batchsend.waitForSpawnedThreads()

proc main() =
  try:
    if paramCount() >= 1:
      sendCsv(paramStr(1))
    else:
      raise newException(CatchableError, "You need to put a file as command line parameter") 
  except:
    echo "Error: " & getCurrentExceptionMsg()

when isMainModule:
  when system.appType != "lib":
    main()