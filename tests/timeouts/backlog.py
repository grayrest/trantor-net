import socket, time
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); srv.listen(1)          # tiny backlog, never accepted
port = srv.getsockname()[1]
hold = []
for _ in range(400):
    try:
        c = socket.socket(); c.settimeout(0.05); c.connect(("127.0.0.1", port)); hold.append(c)
    except Exception:
        break
print(port, flush=True)
time.sleep(300)
