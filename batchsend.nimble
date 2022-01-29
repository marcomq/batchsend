version     = "0.3.4"
author      = "Marco Mengelkoch"
description = "Nim / Python library to feed HTTP server quickly with custom messages"
license     = "MIT"
srcDir      = "src"

requires "nim >= 1.2.10", "nimpy >= 0.1.1"

task docs, "create docs":
    exec "nim doc -d:release --threads:on -o:docs/batchsend.html src/batchsend.nim"
