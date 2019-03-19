import netpipe, times
from os import sleep

var client = newReactor()
var c2s = client.connect("127.0.0.1", 1999)


var
  time: Time
  data = newString(sizeof(Time))
  last = getTime()

while true:
  client.tick()

  time = getTime()
  var delta = time - last
  #echo delta.milliseconds
  if delta.milliseconds()  > 500:
    last = time
    copyMem(data.cstring, addr time, sizeof(Time))
    c2s.send(data)


  for packet in client.packets:
    var t: Time
    copyMem(addr t, packet.data.cstring, sizeof(Time))
    var dur = getTime() - t
    echo "time=", dur.milliseconds(), "ms, ", dur.microseconds(), "μs"


