"""Exercise Freelay multiplayer and lobby switching with a local Mosquitto broker.

Requires Godot and Mosquitto with WebSocket support on PATH.
"""

import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def run_appearance_regression(root, port, processes):
    lobby = "appearance-" + uuid.uuid4().hex
    logs = []
    group = []
    for role in ("host", "leaver", "native", "browser"):
        log = tempfile.TemporaryFile(mode="w+")
        logs.append(log)
        process = subprocess.Popen(
            [os.environ.get("GODOT_BIN", "godot"), "--headless",
             "--path", str(root), "res://tests/freelay_appearance_regression.tscn",
             "--", f"--role={role}", f"--lobby={lobby}",
             f"--broker=ws://127.0.0.1:{port}/mqtt"],
            cwd=root, stdout=log, stderr=subprocess.STDOUT, text=True,
        )
        processes.append(process)
        group.append(process)
        if role == "host":
            time.sleep(5)
    failed = False
    for process, log in zip(group, logs):
        process.wait(timeout=55)
        log.seek(0)
        text = log.read()
        log.close()
        print(text, end="")
        failed |= process.returncode != 0 or "ERROR:" in text
    return failed


def run_migration_regression(root, port, processes):
    failed = False
    for scenario, count, rtc in (
        ("graceful", 2, "false"),
        ("graceful", 3, "true"),
        ("crash", 3, "false"),
        ("repeated", 4, "true"),
        ("candidate-loss", 5, "false"),
        ("host-connection-loss", 3, "false"),
        ("no-quorum", 2, "false"),
    ):
        selection = next((arg.split("=", 1)[1] for arg in sys.argv
                          if arg.startswith("--migration-scenario=")), None)
        if selection is not None and scenario != selection:
            continue
        lobby = "migration-" + uuid.uuid4().hex
        group = []
        outputs = []
        monitors = []
        killed = set()
        kill_ready = []
        kill_lock = threading.Lock()
        for index in range(count):
            role = "host" if index == 0 else "join"
            process = subprocess.Popen(
                [os.environ.get("GODOT_BIN", "godot"), "--headless",
                 "--path", str(root), "res://tests/freelay_migration_regression.tscn",
                 "--", f"--role={role}", f"--scenario={scenario}",
                 f"--name=Migration-{index}", f"--players={count}", f"--lobby={lobby}", f"--rtc={rtc}",
                 f"--broker=ws://127.0.0.1:{port}/mqtt"],
                cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            processes.append(process)
            group.append(process)
            output = []
            outputs.append(output)

            def monitor(p=process, lines=output):
                assert p.stdout is not None
                for line in p.stdout:
                    lines.append(line)
                    if "MIGRATION_KILL_READY" in line:
                        with kill_lock:
                            kill_ready.append(p)
                            if scenario != "candidate-loss" or len(kill_ready) == 2:
                                for ready in kill_ready:
                                    if ready.pid not in killed:
                                        killed.add(ready.pid)
                                        ready.kill()

            thread = threading.Thread(target=monitor, daemon=True)
            thread.start()
            monitors.append(thread)
            if index == 0:
                time.sleep(5)
        for process, output, monitor_thread in zip(group, outputs, monitors):
            process.wait(timeout=75)
            monitor_thread.join(timeout=5)
            text = "".join(output)
            print(text, end="")
            errors = []
            # libdatachannel logs a native send failure when SIGKILL races an
            # SCTP send; Freelay then falls back to MQTT. These are expected
            # only in abrupt-loss tests, not GDScript or migration failures.
            native_loss_errors = (
                "ERROR: rtc::impl::SctpTransport::trySendMessage@687: SCTP sending failed, errno=104",
                "ERROR: Sending failed, errno=25",
                "ERROR: Method/function failed. Returning: FAILED",
            )
            for line_index, line in enumerate(output):
                if "ERROR:" not in line:
                    continue
                native = (rtc == "true" and scenario in ("crash", "repeated")
                          and line.strip() in native_loss_errors
                          and line_index + 1 < len(output)
                          and "src/WebRTCLib" in output[line_index + 1])
                if not native:
                    errors.append(line)
            failed |= bool(errors) or (process.pid not in killed and process.returncode != 0)
        expected_kills = (2 if scenario == "candidate-loss" else
                          1 if scenario in ("crash", "repeated", "no-quorum") else 0)
        failed |= len(killed) != expected_kills
    return failed


def main():
    root = Path(__file__).resolve().parent.parent
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    processes = []
    with tempfile.TemporaryDirectory(prefix="tetra-freelay-") as temporary:
        config = Path(temporary) / "mosquitto.conf"
        config.write_text(
            f"listener {port} 127.0.0.1\nprotocol websockets\n"
            "allow_anonymous true\npersistence false\n"
        )
        broker = subprocess.Popen(
            [os.environ.get("MOSQUITTO_BIN", "mosquitto"), "-c", str(config)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            time.sleep(0.5)
            if broker.poll() is not None:
                print(broker.communicate()[0])
                return 1
            failed = False
            if "--appearance-only" in sys.argv:
                return int(run_appearance_regression(root, port, processes))
            if "--migration-only" in sys.argv:
                return int(run_migration_regression(root, port, processes))
            # Exercise relay-only play, native WebRTC, and automatic host selection
            # across release-tag, commit-hash, and local-build version labels.
            for roles, rtc in (
                (("host", "join", "join"), "false"),
                (("host", "join", "join"), "true"),
                (("auto", "auto", "auto"), "true"),
            ):
                lobby = "regression-" + uuid.uuid4().hex
                processes = []
                logs = []
                for index, role in enumerate(roles):
                    log = tempfile.TemporaryFile(mode="w+")
                    logs.append(log)
                    process = subprocess.Popen(
                        [os.environ.get("GODOT_BIN", "godot"), "--headless",
                          "--path", str(root), "res://tests/freelay_regression.tscn",
                          "--", f"--role={role}", f"--lobby={lobby}", f"--rtc={rtc}",
                          f"--build-version={('v1.0.0', '0123456789abcdef', 'custom build')[index]}",
                          f"--broker=ws://127.0.0.1:{port}/mqtt"],
                        cwd=root, stdout=log,
                        stderr=subprocess.STDOUT, text=True,
                    )
                    processes.append(process)
                    if roles[0] == "host" and index == 0:
                        time.sleep(5)
                for process, log in zip(processes, logs):
                    process.wait(timeout=45)
                    log.seek(0)
                    output = log.read()
                    log.close()
                    print(output, end="")
                    failed |= process.returncode != 0 or "ERROR:" in output
            # Keep both hosts running while one client repeatedly leaves/rejoins.
            lobby = "switching-" + uuid.uuid4().hex
            processes = []
            logs = []
            for index, role in enumerate(("host-a", "host-b", "steady", "switcher")):
                log = tempfile.TemporaryFile(mode="w+")
                logs.append(log)
                process = subprocess.Popen(
                    [os.environ.get("GODOT_BIN", "godot"), "--headless",
                     "--path", str(root), "res://tests/freelay_switching_regression.tscn",
                     "--", f"--role={role}", f"--lobby={lobby}",
                     f"--broker=ws://127.0.0.1:{port}/mqtt"],
                    cwd=root, stdout=log, stderr=subprocess.STDOUT, text=True,
                )
                processes.append(process)
                if index == 1:
                    time.sleep(5)
            for process, log in zip(processes, logs):
                process.wait(timeout=85)
                log.seek(0)
                text = log.read()
                log.close()
                print(text, end="")
                failed |= process.returncode != 0 or "ERROR:" in text
            failed |= run_appearance_regression(root, port, processes)
            failed |= run_migration_regression(root, port, processes)
            mqtt_result = subprocess.run(
                [os.environ.get("GODOT_BIN", "godot"), "--headless",
                 "--path", str(root), "res://tests/mqtt_lifecycle_regression.tscn"],
                cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, timeout=20, check=False,
            )
            print(mqtt_result.stdout, end="")
            failed |= mqtt_result.returncode != 0 or "ERROR:" in mqtt_result.stdout
            process = subprocess.Popen(
                [os.environ.get("GODOT_BIN", "godot"), "--headless",
                 "--path", str(root), "res://tests/freelay_failure_regression.tscn",
                 "--", f"--broker=ws://127.0.0.1:{port}/mqtt"],
                cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            processes.append(process)
            output = []

            def monitor_broker_loss():
                # Popen was configured with stdout=PIPE above.
                assert process.stdout is not None
                for line in process.stdout:
                    output.append(line)
                    if "BROKER_LOSS_READY" in line:
                        broker.terminate()

            monitor = threading.Thread(target=monitor_broker_loss, daemon=True)
            monitor.start()
            process.wait(timeout=35)
            monitor.join(timeout=5)
            text = "".join(output)
            print(text, end="")
            failed |= process.returncode != 0 or "ERROR:" in text
            return int(failed)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            broker.terminate()
            broker.communicate(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
