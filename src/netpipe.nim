import posix, nativesockets, net, times, sequtils, random, selectors

randomize()

export Port

const
  MAGIC = uint16(0xFECA)
  PUNCH_MAGIC = uint16(0x0000)

const ackTime = 0.250 # time to wait before sending the packet again
const connTimeout = 10.00 # how long to wait until time out the connection

type
  Address* = object
    ## A host/port of the client
    host*: string
    port*: Port

  Reactor* = ref object
    ## Main networking system that can make or recive connections
    address*: Address
    socket*: Socket
    selector: Selector[int]
    simDropRate: float
    maxInFlight: int
    time: float64

    connecting*: seq[Connection]
    connections*: seq[Connection]
    newConnections*: seq[Connection]
    deadConnections*: seq[Connection]
    packets*: seq[Packet]

  Connection* = ref object
    ## Single connection from this reactor to another reactor
    reactor*: Reactor
    connected*: bool
    address*: Address
    rid*: uint32
    sentParts: seq[Part]
    recvParts: seq[Part]
    sendSequenceNum: int
    recvSequenceNum: int

  Flags* = object
    INIT* {.bitsize: 1.}: bool
    ACK* {.bitsize: 1.}: bool
    COOKIE* {.bitsize: 1.}: bool

  PartHeader* {.packed.} = object
    magic*: uint16
    flags*: Flags
    seqno*: uint32 # which packet seq is it
    rid: uint32 # random number that is this connect
    partNum*: uint16 # which par is it
    numParts*: uint16 # number of parts

  Part* = ref object
    header*: PartHeader
    # sending
    firstTime: float64
    lastTime: float64
    numSent: int
    acked: bool
    ackedTime: float64

    # reciving
    produced: bool
    data*: string

  Packet* = ref object
    ## Full packet
    connection*: Connection
    seqno*: uint32 # which packet seq is it
    secret*: uint32
    data*: string


let
  MAX_PACKET_SIZE = 508
  HEADER_SIZE = sizeof(PartHeader)
  MAX_UDP_PACKET = MAX_PACKET_SIZE - HEADER_SIZE

proc newAddress*(host: string, port: int): Address =
  result.host = host
  result.port = Port(port)


proc `$`*(address: Address): string =
  ## Address to string
  $address.host & ":" & $(address.port.int)


proc `$`*(conn: Connection): string =
  ## Connection to string
  "Connection(" & $conn.address & ")"


proc `$`*(part: Part): string =
  ## Part to string
  "Part(" & $part.header.seqno & ":" & $part.header.partNum & "/" & $part.header.numParts & " ACK:" & $part.acked & ")"


proc `$`*(packet: Packet): string =
  ## Part to string
  "Packet(from: " & $packet.connection.address & " #" & $packet.seqno & ", size:" & $packet.data.len & ")"


proc `[]`*(p: pointer, i: int): pointer =
  cast[pointer](cast[int](p) + i)


proc removeBack[T](s: var seq[T], what: T) =
  ## Remove an element in a seq, by copying the last element
  ## over its pos and shrinking seq by 1
  if s.len == 0: return
  for i in 0..<s.len:
    if s[i] == what:
      s[i] = s[^1]
      s.setLen(s.len - 1)
      return


proc tick*(reactor: Reactor)


proc newReactor*(address: Address): Reactor =
  ## Creates a new reactor with address
  new(result)
  result.address = address
  result.selector = newSelector[int]()
  result.socket = newSocket(Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP, false)
  result.socket.setSockOpt(OptReuseAddr, true)
  result.socket.setSockOpt(OptReusePort, true)
  result.socket.getFd().setBlocking(false)
  result.socket.bindAddr(result.address.port, result.address.host)
  if address.host.len == 0:
    let (_, portLocal) = result.socket.getLocalAddr()
    result.address.port = portLocal
  result.connections = @[]
  result.simDropRate = 0.0 #
  result.maxInFlight = 25000 # don't have more then 250K in flight on the socket

  result.selector.registerHandle(result.socket.getFd, {Event.Read}, 0)

  when not compileOption("threads"):
    result.tick()

proc newReactor*(host: string, port: int): Reactor =
  ## Creates a new reactor with host and port
  newReactor(newAddress(host, port))


proc newReactor*(): Reactor =
  ## Creates a new reactor with system chosen address
  newReactor("", 0)


proc newConnection*(socket: Reactor, address: Address): Connection =
  var conn = Connection()
  conn.reactor = socket
  conn.address = address
  conn.rid = uint32 rand(int uint32.high)
  conn.sentParts = @[]
  conn.recvParts = @[]
  return conn


proc getConn(reactor: Reactor, address: Address): Connection =
  for conn in reactor.connections.mitems:
    if conn.address == address:
      return conn


proc getConn(reactor: Reactor, address: Address, rid: uint32): Connection =
  for conn in reactor.connections.mitems:
    if conn.address == address and conn.rid == rid:
      return conn


proc read*(conn: Connection): Packet =
  if conn.recvParts.len == 0:
    return nil

  let numParts = int conn.recvParts[0].header.numParts
  let seqno = int conn.recvSequenceNum
  if conn.recvParts.len < numParts:
    return nil

  # verify step
  var good = true
  for i in 0..<numParts:
    if not (conn.recvParts[i].header.seqno == uint32(seqno) and
        conn.recvParts[i].header.numParts == uint16(numParts) and
        conn.recvParts[i].header.partNum == uint16(i)):
      good = false
      break

  if not good:
    return nil

  # all good create packet
  var packet = Packet()
  packet.connection = conn
  packet.seqno = uint32 seqno
  packet.data = ""
  for i in 0..<numParts:
    packet.data.add conn.recvParts[i].data

  inc conn.recvSequenceNum
  conn.recvParts.delete(0, numParts-1)

  return packet


proc divideAndSend(reactor: Reactor, conn: Connection, data: string) =
  ## Divides a packet into parts and gets it ready to be sent
  var parts = newSeq[Part]()

  assert data.len != 0

  var partNum: uint16 = 0
  var at = 0
  while at < data.len:
    var part = Part()
    part.header.seqno = uint32 conn.sendSequenceNum
    part.header.partNum = partNum
    let maxAt = min(at + MAX_UDP_PACKET, data.len)
    part.data = data[at ..< maxAt]
    inc partNum
    at = maxAt
    parts.add(part)
  for part in parts.mitems:
    part.header.numParts = uint16 parts.len
    part.header.rid = conn.rid
    part.firstTime = reactor.time
    part.lastTime = reactor.time
    conn.sentParts.add(part)
  inc conn.sendSequenceNum

proc handshake(s: Socket, to: Address, data: pointer, dataLen: int) =
  try:
    s.sendTo(to.host, to.port, data, dataLen)
  except:
    return


proc rawSend(conn: Connection, data: pointer, dataLen: int) =
  ## Low level send to a socket
  if conn.reactor.simDropRate != 0:
    # drop % of packets
    if rand(1.0) <= conn.reactor.simDropRate:
      return
  try:
    conn.reactor.socket.sendTo(conn.address.host, conn.address.port, data, dataLen)
  except:
    return

proc sendNeededParts(reactor: Reactor) =
  var i = 0
  while i < reactor.connections.len:
    var conn = reactor.connections[i]
    inc i
    if not conn.connected: continue

    var inFlight = 0
    for part in conn.sentParts.mitems:

      # make sure we only keep max data in flight
      inFlight += part.data.len
      if inFlight > reactor.maxInFlight:
        break

      # looks for packet that need to be sent or re-sent
      if not part.acked and (part.numSent == 0 or part.lastTime + ackTime < reactor.time):

        if part.numSent > 0 and part.firstTime + connTimeout < reactor.time:
          # we have tried to resent packet but it did not take
          conn.connected = false
          reactor.deadConnections.add(conn)
          reactor.connections.removeBack(conn)
          break

        var
          packetLen = HEADER_SIZE + part.data.len
          packet = alloc0(packetLen)
        part.header.magic = MAGIC
        copyMem(packet, addr part.header, HEADER_SIZE)
        copyMem(packet[HEADER_SIZE], part.data.cstring, part.data.len)
        inc part.numSent
        part.lastTime = reactor.time
        try:
          conn.rawSend(packet, packetLen)
        finally:
          dealloc(packet)


proc sendSpecial(conn: Connection, header: ptr PartHeader) =
  header.magic = MAGIC
  conn.rawSend(header, HEADER_SIZE)


proc deleteAckedParts(reactor: Reactor) =
  for conn in reactor.connections:
    ## look for packets that have been acked already
    var number = 0
    for part in conn.sentParts:
      if not part.acked:
        break
      inc number
    if number > 0:
      conn.sentParts.delete(0, number-1)


proc clientHandshake(reactor: Reactor, address: var Address): uint32 =
  var
    data = newString(HEADER_SIZE)
    bytesRead: int
    header: PartHeader
  reactor.socket.getFd().setBlocking(true)

  header.magic = MAGIC
  header.flags.INIT = true
  reactor.socket.handshake(address, addr header, HEADER_SIZE)

  while true:
    try:
      bytesRead = reactor.socket.recvFrom(data, HEADER_SIZE, address.host, address.port)
      if bytesRead != HEADER_SIZE:
        echo "Invalid protocol: ", $address
        return 0.uint32
      var pHeader = cast[ptr PartHeader](data.cstring)
      if pHeader.flags.ACK:
        if pHeader.flags.INIT:
          echo "step1 ", pHeader[]
          pHeader.flags.INIT = true
          pHeader.flags.ACK = false
          pHeader.flags.COOKIE = true
          reactor.socket.handshake(address, pHeader, HEADER_SIZE)
        elif header.flags.COOKIE:
          echo "step2 ", pHeader[]
          result = header.rid
          reactor.socket.getFd().setBlocking(false)
          break
        else:
          break
    except:
      discard



proc readParts(reactor: Reactor) =
  var
    data = newString(MAX_PACKET_SIZE)
    address = Address()
    conn: Connection
    bytesRead: int
    rfds: TFdSet
    tv: Timeval
  tv.tv_usec = 250.Suseconds

  for i in 0..<1:
    try:
      bytesRead = reactor.socket.recvFrom(data, MAX_PACKET_SIZE, address.host, address.port)
      if bytesRead < HEADER_SIZE:
        echo "Invalid protocol: ", $address
        break
    except:
      break


    var header = cast[ptr PartHeader](data.cstring)

    if header.magic == PUNCH_MAGIC:
      #echo "got punched from", host, port
      continue

    if header.magic != MAGIC:
      break

    # handshake
    if header.flags.INIT:
      if not header.flags.COOKIE:
        echo "step1 ", header[]
        header.flags.ACK = true
        # TODO hash cookie
        header.rid = 1 # rand(int32.high).uint32
        reactor.socket.handshake(address, header, HEADER_SIZE)
        break
      else:
        # TODO verify cookie
        if header.rid != 1:
          break
        echo "step2 ", header[]
        header.flags.INIT = false
        header.flags.ACK = true
        reactor.socket.handshake(address, header, HEADER_SIZE)
        conn = reactor.newConnection(address)
        conn.rid = header.rid
        conn.connected = true
        reactor.connections.add(conn)
        reactor.newConnections.add(conn)

    if conn.isNil:
      break

    var part = Part()
    part.header = header[]

    if bytesRead > HEADER_SIZE:
      part.data = data[HEADER_SIZE..^1]

    # insert packets in the correct order
    part.acked = true
    part.ackedTime = reactor.time
    conn.sendSpecial(addr part.header)

    var pos = 0
    if header.seqno >= uint32(conn.recvSequenceNum):
      for p in conn.recvParts:
        if p.header.seqno > header.seqno:
          break
        elif p.header.seqno == header.seqno:
          if p.header.partNum > header.partNum:
            break
          elif p.header.partNum == header.partNum:
            # duplicate
            pos = -1
            assert p.data == part.data
            break
        inc pos
      if pos != -1:
        conn.recvParts.insert(part, pos)

    if header.flags.ACK:
      for p in conn.sentParts:
        if p.header.seqno == header.seqno and
           p.header.numParts == header.numParts and
           p.header.partNum == header.partNum:
          # found a part that was being acked
          if not p.acked:
            p.acked = true
            p.ackedTime = reactor.time



proc combinePackets(reactor: Reactor) =
  for conn in reactor.connections:
    while true:
      var packet = conn.read()
      if packet != nil:
        reactor.packets.add(packet)
      else:
        break


proc tick*(reactor: Reactor) =
  ## send and recives packets
  var events: array[64, ReadyKey]

  reactor.time = epochTime()
  reactor.newConnections.setLen(0)
  reactor.deadConnections.setLen(0)
  reactor.packets.setLen(0)
  reactor.sendNeededParts()
  reactor.deleteAckedParts()

  reactor.selector.updateHandle(reactor.socket.getFd, {Event.Read})
  let count = reactor.selector.selectInto(100, events)
  for i in 0 ..< count:
    if Event.Read in events[i].events:
       reactor.readParts()
  reactor.combinePackets()


proc connect*(reactor: Reactor, address: Address): Connection =
  ## Starts a new connectino to an address
  var address = address
  if reactor.clientHandshake(address) > 0.uint32:
    result = newConnection(reactor, address)
    result.connected = true
    reactor.connections.add(result)
    reactor.newConnections.add(result)

proc connect*(reactor: Reactor, host: string, port: int): Connection =
  ## Starts a new connectino to an address
  reactor.connect(newAddress(host, port))


proc send*(conn: Connection, data: string) =
  if conn.connected == true:
    conn.reactor.divideAndSend(conn, data)


proc disconnect*(conn: Connection) =
  conn.connected = false
  # TOOD Send disc packet


proc punchThrough*(reactor: Reactor, address: Address) =
  ## Tries to punch through to host/port
  for i in 0..10:
    reactor.socket.sendTo(address.host, address.port, char(0) & char(0) & char(0) & char(0) & "punch through")


proc punchThrough*(reactor: Reactor, host: string, port: int) =
  ## Tries to punch through to host/port
  reactor.punchThrough(newAddress(host, port))
