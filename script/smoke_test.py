#!/usr/bin/env python3
"""Exercise the shipped helper through real pipes without accessing Instagram."""
import json
import os
import pathlib
import select
import subprocess
import sys

helper = pathlib.Path(sys.argv[1])
if not helper.is_file():
    raise SystemExit("Build the app with script/build_and_run.sh --build-only first.")

child = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
read_buffer = b""

def request(identifier, kind, data=None, version=1):
    global read_buffer
    child.stdin.write((json.dumps({"v": version, "id": identifier, "type": kind, "data": data or {}}) + "\n").encode())
    child.stdin.flush()
    while True:
        while b"\n" not in read_buffer:
            ready, _, _ = select.select([child.stdout], [], [], 10)
            if not ready:
                raise AssertionError("Helper response timed out")
            chunk = os.read(child.stdout.fileno(), 65536)
            assert chunk, "Helper exited before replying"
            read_buffer += chunk
        line, read_buffer = read_buffer.split(b"\n", 1)
        frame = json.loads(line)
        assert frame["v"] == 1
        if frame.get("id") == identifier:
            return frame

try:
    assert request("hello", "hello")["data"]["protocol"] == 1
    assert request("restore", "restore", {"session": None})["data"]["authenticated"] is False
    assert request("history", "history", {"threadID": "none"})["error"]["code"] == "login_required"
    assert request("send", "send", {"threadID": "none", "text": "Never sent"})["error"]["code"] == "login_required"
    assert request("media", "send_media", {})["error"]["code"] == "login_required"
    assert request("post", "shared_post", {"url": "https://www.instagram.com/p/BA/"})["error"]["code"] == "login_required"
    assert request("invalid", "unknown")["error"]["code"] == "command"
    assert request("version", "hello", version=99)["error"]["code"] == "version"
    assert request("bye", "shutdown")["data"]["ok"] is True
    child.wait(timeout=7)
    assert child.returncode == 0
    assert child.stderr.read() == b""
finally:
    if child.poll() is None:
        child.kill()
    child.communicate(timeout=5)

orphan = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
orphan.stdin.close()
orphan.wait(timeout=7)
assert orphan.returncode == 0
print("Helper pipe smoke: PASS (handshake, empty restore, auth guards, version rejection, shutdown, parent EOF)")
