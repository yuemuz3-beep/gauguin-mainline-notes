import socket
import sys
import time

HOST, PORT = "172.16.42.1", 23

CMDS = [
    "cat /proc/cmdline",
    "echo ---PROC_PARTITIONS---",
    "cat /proc/partitions",
    "echo ---BLKID---",
    "blkid",
    "echo ---DEV---",
    "ls /dev/disk/by-uuid/ 2>/dev/null || echo no-by-uuid",
    "echo ---MOUNTS---",
    "cat /proc/mounts",
    "echo ---DMESG_TAIL---",
    "dmesg | tail -60",
    "echo ---DONE---",
]


def main():
    s = socket.socket()
    s.settimeout(5)
    s.connect((HOST, PORT))
    time.sleep(1.5)

    def drain(t=2.0):
        s.settimeout(t)
        buf = b""
        while True:
            try:
                d = s.recv(4096)
            except socket.timeout:
                break
            if not d:
                break
            buf += d
        return buf.decode("utf-8", "replace")

    out = [drain(), ]
    for c in CMDS:
        s.sendall((c + "\n").encode())
        time.sleep(0.8)
        out.append(drain(3.0))
    s.close()
    print("".join(out))


if __name__ == "__main__":
    main()
