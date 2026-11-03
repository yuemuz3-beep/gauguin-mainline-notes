import socket
import time

HOST, PORT = "172.16.42.1", 23

CMDS = [
    "echo ===BEFORE===",
    "cat /newroot/etc/fstab",
    "echo ===FIX===",
    "mount -o remount,rw /newroot && echo RW_OK || echo RW_FAIL",
    "cp /newroot/etc/fstab /newroot/etc/fstab.bak && echo BACKUP_OK",
    "sed -i '\\|^UUID=8257c854|d' /newroot/etc/fstab && echo SED_OK",
    "echo ===AFTER===",
    "cat /newroot/etc/fstab",
    "sync",
    "umount /newroot && echo UMOUNT_OK || echo UMOUNT_FAIL",
    "echo ===DONE3===",
]


def main():
    s = socket.socket()
    s.settimeout(5)
    s.connect((HOST, PORT))
    time.sleep(1.2)

    def drain(t=2.0):
        s.settimeout(t)
        buf = b""
        while True:
            try:
                d = s.recv(8192)
            except socket.timeout:
                break
            if not d:
                break
            buf += d
        return buf.decode("utf-8", "replace")

    out = [drain()]
    for c in CMDS:
        s.sendall((c + "\n").encode())
        time.sleep(0.7)
        out.append(drain(3.0))
    s.close()
    text = "".join(out).replace("\x1b[6n", "").replace("~ # ", "\n~ # ")
    print(text)


main()
