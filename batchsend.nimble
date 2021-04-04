version     = "0.2.0"
author      = "Marco Mengelkoch"
description = "Nim / Python library to feed HTTP server quickly with custom messages"
license     = "MIT"
bin         = @["batchsend"]
srcDir      = "src"

requires "nim >= 1.0.0", "nimpy >= 0.1.1"

task docs, "create docs":
    exec "nim doc -d:release --threads:on -o:docs/batchsend.html src/batchsend.nim"
