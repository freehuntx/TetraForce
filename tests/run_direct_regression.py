"""Check desktop TCP gameplay and cleanup with three real Godot instances."""

import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


def main():
    root = Path(__file__).resolve().parent.parent
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    command = [
        os.environ.get("GODOT_BIN", "godot"), "--headless", "--path", str(root),
        "res://tests/direct_regression.tscn", "--", f"--port={port}",
    ]
    processes = []
    failed = False
    with tempfile.TemporaryDirectory(prefix="tetraforce-direct-") as temp:
        try:
            for index, role in enumerate(("host", "client", "client")):
                log = open(Path(temp) / f"{index}-{role}.log", "w+")
                process = subprocess.Popen(
                    command + [f"--role={role}"], cwd=root,
                    stdout=log, stderr=subprocess.STDOUT,
                )
                processes.append((process, log))
                time.sleep(1.0 if role == "host" else 0.3)
            for process, _ in processes:
                process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            failed = True
            print("Direct regression runner timed out")
        finally:
            for process, log in processes:
                if process.poll() is None:
                    process.kill()
                process.wait()
                log.seek(0)
                output = log.read()
                print(output, end="")
                failed |= process.returncode != 0 or "ERROR:" in output
                log.close()
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
