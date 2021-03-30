# batchsend
![License](https://img.shields.io/github/license/marcomq/batchsend)


Nim / Python library to feed HTTP server quickly with custom messages

Currently uses AsyncSocket as this module is faster than AsyncHttpClient
Notice that the library uses threads that might not catch all network errors
You cannot catch those when using the python library - the application might
crash in such a case.

## Docs

Documentation is [here](http://htmlpreview.github.io/?https://github.com/marcomq/batchsend/blob/main/docs/batchsend.html)
