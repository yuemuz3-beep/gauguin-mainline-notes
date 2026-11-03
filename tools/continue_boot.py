import socket
import time

HOST = "172.16.42.1"


def port_open(port, timeout=2):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect((HOST, port))
        return True
    except Exception:
        return False
    finally:
        s.close()


# 1) 通过调试 shell 继续启动
print("[*] 发送 pmos_continue_boot ...")
try:
    s = socket.socket()
    s.settimeout(5)
    s.connect((HOST, 23))
    time.sleep(1.0)
    s.sendall(b"pmos_continue_boot\n")
    time.sleep(2.0)
    try:
        print(s.recv(4096).decode("utf-8", "replace")[:400])
    except Exception:
        pass
    s.close()
except Exception as e:
    print("    无法连接调试 shell:", e)

# 2) 轮询 22 端口
print("[*] 轮询 172.16.42.1:22 ...")
start = time.time()
opened = False
while time.time() - start < 180:
    if port_open(22):
        opened = True
        break
    time.sleep(3)

print()
if opened:
    print("[+] 22 端口已开放（用时 %.0f 秒）—— 可以 ssh 了" % (time.time() - start))
else:
    print("[-] 180 秒内 22 未开放")

print("[*] 顺带看看 ping 和 23：")
print("    ping 通否:", end=" ")
import subprocess
r = subprocess.run(["ping", "-n", "2", HOST], capture_output=True, text=True)
print("是" if "TTL=" in r.stdout else "否")
print("    23 端口:", port_open(23))
