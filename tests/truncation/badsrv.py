import gzip, os, socket, struct, threading, time
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(8)
print(srv.getsockname()[1], flush=True)
def serve(c):
    try:
        req = c.recv(65536).decode("latin1")
        path = req.split(" ")[1] if " " in req else "/"
        if path.startswith("/lie"):        # declares 1000, sends 10, closes
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n0123456789")
        elif path.startswith("/chunk"):    # chunked, cut before the terminator
            c.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n")
        elif path.startswith("/stall"):    # headers and part of the body, then nothing
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n012")
            time.sleep(5)
        elif path.startswith("/gzlie"):     # gzip, declares the whole body, sends part
            # Random bytes do not compress, so 40 bytes really is part of it.
            body = gzip.compress(os.urandom(4000))
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: %d\r\n\r\n" % len(body) + body[:40])
        elif path.startswith("/gztrunc"):   # the whole body arrives, but the gzip in it is cut
            body = gzip.compress(os.urandom(4000))[:40]
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        elif path.startswith("/tricklehead"):  # the status line and headers a byte every 300ms
            for b in b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok":
                c.sendall(bytes([b])); time.sleep(0.3)
        elif path.startswith("/reset"):    # part of the body, then a RST, not a FIN
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n012")
            time.sleep(0.2)
            c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        else:
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ncomplete")
    except Exception:
        pass
    c.close()
while True:
    c, _ = srv.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
