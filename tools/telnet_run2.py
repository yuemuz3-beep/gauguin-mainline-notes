import socket
import time

HOST, PORT = "172.16.42.1", 23

CMDS = [
    "echo ===INITLOG===",
    "tail -40 /pmOS_init.log",
    "echo ===MOUNTROOT===",
    "mkdir -p /newroot && mount -o ro /dev/sda35 /newroot && echo MOUNT_OK || echo MOUNT_FAIL",
    "echo ===OSRELEASE===",
    "cat /newroot/etc/os-release 2>/dev/null | head -5",
    "echo ===SYSTEMD_WANTS===",
    "ls /newroot/etc/systemd/system/multi-user.target.wants/ 2>/dev/null | head -30",
    "echo ===RUNLEVELS===",
    "ls /newroot/etc/runlevels/default/ 2>/dev/null | head -30",
    "echo ===SSH_FILES===",
    "ls /newroot/usr/lib/systemd/system/ 2>/dev/null | grep -i ssh",
    "ls /newroot/etc/systemd/system/ 2>/dev/null | grep -i ssh",
    "ls /newroot/usr/sbin/sshd /newroot/usr/bin/ssh* 2>/dev/null",
    "echo ===FSTAB===",
    "cat /newroot/etc/fstab 2>/dev/null",
    "echo ===HOME===",
    "ls -la /newroot/home/ 2>/dev/null",
    "echo ===DONE2===",
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
        out.append(drain(3.5))
    s.close()
    text = "".join(out)
    # 去掉 telnet 的终端查询/ANSI 噪声
    text = text.replace("\x1b[6n", "").replace("~ # ", "\n~ # ")
    print(text)


main()
