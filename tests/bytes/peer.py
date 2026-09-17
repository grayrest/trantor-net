import socket, sys, threading
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(4)
print(srv.getsockname()[1], flush=True)
def serve(c):
    c.sendall(b"ABCDEFGH")          # one send, read back in two halves
    while True:
        d = c.recv(4096)
        if not d: break
        c.sendall(d)                 # echo, for the delimiter read
    c.close()
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
