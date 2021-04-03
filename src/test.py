import nimporter
import batchsend
import time
# Trying to send 1 million messages. Wait 10 seconds, abort, wait for thread 
# and count number of messages

message = "POST / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\nContent-Length: 11\r\n\r\nHello World"
print("feeding 1000000 messages")
try:
    batchsend.setWaitForever(True)
    for i in range(1000000):
        batchsend.pushMessage(message)
    batchsend.spawnTransmissionThread(port=9292)
    time.sleep(10) # seconds
    batchsend.setAbortTransmission(True)
    batchsend.waitForTransmissionThread()
except:
    print("error during send")