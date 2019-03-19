import netpipe, cpuinfo


proc eventLoop(param: int) {.gcsafe.} =
  var server = newReactor("127.0.0.1", 1999)
  # main loop
  while true:
    server.tick()
    for connection in server.newConnections:
      echo "[new] ", connection.address
    for connection in server.deadConnections:
      echo "[dead] ", connection.address
    for packet in server.packets:
      packet.connection.send(packet.data)


echo "Listenting for UDP on 127.0.0.1:1999"

when compileOption("threads"):
  let cores = countProcessors()
  var threads = newSeq[Thread[int]](cores)
  for i in 0 ..< cores:
    createThread[int](threads[i], eventLoop, 0)
  joinThreads(threads)
else:
  eventLoop(0)
