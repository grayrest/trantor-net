import socket, sys
s = socket.socket(); s.settimeout(1.0)
try:
    s.connect(("127.0.0.1", int(sys.argv[1]))); sys.exit(1)   # connected => not saturated
except Exception:
    sys.exit(0)
