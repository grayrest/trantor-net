# Two peers on one port, told apart by the first byte the client sends:
#   S — split: "abc", then "def|rest" 1.2s later, after a 400ms read has
#       timed out holding "abc".
#   T — trickle: one byte every 300ms, forever, so no gap is as long as a
#       500ms budget but the whole read is far longer.
#   L — limit: "abcdefgh|" at once, for a read_until! whose limit is too small.
#   E — end: "xyz", then close, for a read_exactly! that asks for more.
import socket, threading, time
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); srv.listen(16)
print(srv.getsockname()[1], flush=True)
def serve(c):
    try:
        kind = c.recv(1)
        if kind == b"S":
            c.sendall(b"abc"); time.sleep(1.2); c.sendall(b"def|rest")
        elif kind == b"T":
            while True:
                c.sendall(b"x"); time.sleep(0.3)
        elif kind == b"L":
            c.sendall(b"abcdefgh|")
        elif kind == b"E":
            c.sendall(b"xyz"); time.sleep(0.2); c.close(); return
        time.sleep(30)
    except OSError:
        pass
while True:
    c, _ = srv.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
