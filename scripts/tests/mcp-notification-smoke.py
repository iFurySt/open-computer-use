#!/usr/bin/env python3
"""Exercise a real native MCP stdio process without desktop access.

Usage: python3 scripts/tests/mcp-notification-smoke.py <native executable>
Set OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY=1 for direct macOS transport;
omit it with an authorized bundle executable to also cover the app-agent proxy.
"""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading


def main():
    executable = str(Path(sys.argv[1]).resolve())
    process = subprocess.Popen([executable, "mcp"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding="utf-8", env=os.environ.copy())
    responses = queue.Queue()
    stderr = []

    def read_output():
        for line in process.stdout:
            responses.put(json.loads(line))
        responses.put(None)

    def read_errors():
        for line in process.stderr:
            stderr.append(line)

    threading.Thread(target=read_output, daemon=True).start()
    threading.Thread(target=read_errors, daemon=True).start()

    def send(payload):
        process.stdin.write(json.dumps({"jsonrpc": "2.0", **payload}) + "\n")
        process.stdin.flush()

    def expect(identifier):
        response = responses.get(timeout=20)
        assert response is not None and response.get("id") == identifier, response
        assert "result" in response and "error" not in response, response
        return response

    try:
        send({"id": "init", "method": "initialize", "params": {}})
        expect("init")
        for method in ("notifications/initialized", "notifications/cancelled", "roots/list_changed", "unknown", "tools/call"):
            send({"method": method, "params": {"requestId": "unknown"}})
        send({"id": "tools", "method": "tools/list"})
        assert expect("tools")["result"]["tools"]
        for index in range(10):
            identifier = f"ping-中文-{index}"
            send({"id": identifier, "method": "ping"})
            expect(identifier)
            send({"method": "notifications/cancelled", "params": {"requestId": identifier}})
        send({"method": "notifications/turn-ended"})
        send({"id": "after-cleanup", "method": "ping"})
        expect("after-cleanup")
        process.stdin.close()
        assert process.wait(timeout=20) == 0, "".join(stderr)[-2000:]
        assert responses.get(timeout=5) is None, "Unexpected notification response"
        print("PASS: real stdio initialize, notifications, tools, Unicode IDs, late cancellation, cleanup and EOF")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
