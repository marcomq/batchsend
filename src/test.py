import nimporter
import batchsend
import time
# Trying to send 1 million messages. Wait 10 seconds, abort, wait for thread 
# and count number of messages

message = "POST / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\nContent-Length: 11\r\n\r\nHello World"
try:
    cfg = batchsend.newSendCfg(port=9292, waitForever=False)
    print("feeding 1000000 messages")
    for i in range(1000000):
        cfg.pushMessage(message)
    cfg.spawnTransmissionThread()
    time.sleep(3) # seconds
    cfg.setAbortTransmission(True)
    batchsend.waitForSpawnedThreads()
except:
    print("error during send")