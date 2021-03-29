import nimporter, bulkSend

message = "POST / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\nContent-Length: 11\r\n\r\nHello World"
print("feeding 1000000 messages")
for i in range(1000000):
    bulkSend.pushMessage(message)
bulkSend.startTransmission()