"""Explicit offline integration: real worker/native stop and EOF, no network."""
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import uuid
import wave


def main():
    project, library, fixture, evidence = map(Path, sys.argv[1:])
    evidence.mkdir(parents=True, exist_ok=True)
    long_wav = evidence.parent / "native-cancel-fixture.wav"
    with wave.open(str(fixture), "rb") as source:
        params, pcm = source.getparams(), source.readframes(source.getnframes())
    with wave.open(str(long_wav), "wb") as target:
        target.setparams(params)
        for _ in range(60):
            target.writeframesraw(pcm)
    all_runs = []
    for end in ("stop", "eof"):
        child = subprocess.Popen([sys.executable, "-u", "-m", "adapters.worker"],
                                 cwd=project, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        events = queue.Queue()
        observed = []

        def collect():
            for line in child.stdout:
                events.put(json.loads(line))

        reader = threading.Thread(target=collect, daemon=True)
        reader.start()

        def send(identifier, command, values):
            child.stdin.write((json.dumps(dict(v=1, id=identifier, command=command, params=values)) + "\n").encode())
            child.stdin.flush()

        def until(predicate):
            for _ in range(30):
                event = events.get(timeout=10)
                observed.append(event)
                if predicate(event):
                    return event
            raise AssertionError("No matching terminal response")

        try:
            session = str(uuid.uuid4())
            send("native-start", "start", dict(session=session, library=str(library),
                 wav=str(long_wav), execution="offline", routes=[dict(output_id=i, channels=[i, i]) for i in range(3)]))
            until(lambda event: event["id"] == "native-start" and event["event"] in ("accepted", "error"))
            assert observed[-1]["event"] == "accepted", observed
            if end == "stop":
                send("native-stop", "stop", dict(session=session))
                until(lambda event: event["id"] == "native-stop" and event["event"] in ("result", "error"))
                assert observed[-1]["event"] == "result", observed
                assert observed[-1]["payload"]["cleanup_complete"] is True
                send("shutdown", "shutdown", {})
                until(lambda event: event["id"] == "shutdown" and event["event"] == "result")
            else:
                child.stdin.close()
                until(lambda event: event["id"] == "native-start" and event["event"] in ("result", "error"))
            assert child.wait(timeout=5) == 0
            terminal = next(event for event in observed if event["id"] == "native-start" and event["event"] == "result")
            assert terminal["payload"]["state"] == "stopped", observed
            report = terminal["payload"]["report"]
            assert report["native_core_used"] is True
            assert report["network_used"] is False
            assert report["cleanup_complete"] and report["input_closed"] and report["hub_stopped"]
            assert report["input_frames_read"] < 44100 * 60, "Must stop mid-input"
            all_runs.append(dict(end=end, status="passed", events=observed,
                                 stderr=child.stderr.read().decode("utf-8", "replace")))
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            for handle in (child.stdin, child.stdout, child.stderr):
                handle.close()
            reader.join(timeout=1)
    (evidence / "native-stop-eof.json").write_text(json.dumps(all_runs, indent=2), encoding="utf-8")
    print("PASS: real native mid-input stop and EOF; cleaned and exited 0; no network/audio")


if __name__ == "__main__":
    main()
