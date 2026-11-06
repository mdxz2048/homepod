"""Explicit GUI-child live routing acceptance. No file input or PCM recording.

Starts the actual NDJSON worker, plays quiet built-in Mac sounds into system
audio, then stops and restarts the complete receiver group. Default invocation
never runs this module; an operator must provide all runtime paths and targets.
"""
import argparse
import asyncio
import contextlib
import json
from pathlib import Path
import signal
import sys
import time
import uuid


async def check(args):
    # App termination requests owned cleanup rather than orphaning a sender.
    task = asyncio.current_task()
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, task.cancel)
    report = {"test": "system_audio_to_homepods", "volume_percent": 15,
              "acoustic_sync_verified": False, "cycles": [], "events": [], "errors": []}
    worker = await asyncio.create_subprocess_exec(args.python, "-u", "-m", "adapters.system_worker",
        cwd=args.project, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE)
    queue = asyncio.Queue(maxsize=256)
    sound_stop = asyncio.Event()
    sound_task = None
    current_session = None
    stderr_tail = bytearray()

    async def read_events():
        try:
            while line := await worker.stdout.readline():
                event = json.loads(line)
                report["events"].append({"received_ns": time.monotonic_ns(), **event})
                await queue.put(event)
        finally:
            with contextlib.suppress(asyncio.QueueFull):
                queue.put_nowait(None)

    async def read_errors():
        while chunk := await worker.stderr.read(4096):
            stderr_tail.extend(chunk)
            del stderr_tail[:-16384]

    reader = asyncio.create_task(read_events())
    errors = asyncio.create_task(read_errors())

    async def send(command, params=None):
        rid = str(uuid.uuid4())
        worker.stdin.write((json.dumps({"v": 1, "id": rid, "command": command,
            "params": params or {}}, separators=(",", ":")) + "\n").encode())
        await asyncio.wait_for(worker.stdin.drain(), 5)
        return rid

    async def until(predicate, timeout=30):
        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            event = await asyncio.wait_for(queue.get(), max(.01, deadline - asyncio.get_running_loop().time()))
            if event is None:
                raise RuntimeError("worker exited before expected confirmation")
            if event["event"] == "error":
                raise RuntimeError("worker error: " + json.dumps(event["payload"]))
            if predicate(event):
                return event

    async def result(rid, timeout=30):
        return await until(lambda event: event["id"] == rid and event["event"] == "result", timeout)

    async def sound():
        runs = 0
        while not sound_stop.is_set():
            child = await asyncio.create_subprocess_exec("/usr/bin/afplay", "-v", "0.15",
                "/System/Library/Sounds/Glass.aiff")
            try:
                await asyncio.wait_for(child.wait(), 4)
                if child.returncode != 0:
                    raise RuntimeError("local system test sound failed")
                runs += 1
            finally:
                if child.returncode is None:
                    child.terminate()
                    try:
                        await asyncio.wait_for(child.wait(), 2)
                    except asyncio.TimeoutError:
                        child.kill()
                        await asyncio.wait_for(child.wait(), 2)
            try:
                await asyncio.wait_for(sound_stop.wait(), .5)
            except asyncio.TimeoutError:
                pass
        return runs

    try:
        await result(await send("hello"))
        scan = await result(await send("scan", {"hosts": args.hosts.split(","), "timeout_seconds": 8}))
        devices = scan["payload"]["devices"]
        report["devices"] = devices
        found = {device["address"] for device in devices}
        if not set(args.hosts.split(",")).issubset(found):
            raise RuntimeError("not all selected receivers are available")
        routes = [{"output_id": index + 1, "host": host, "channels": [0, 1]}
                  for index, host in enumerate(args.hosts.split(","))]
        for index in range(2):
            current_session = str(uuid.uuid4())
            cycle = {"session": current_session, "requested_seconds": args.seconds if index == 0 else 10}
            report["cycles"].append(cycle)
            start = await send("start", {"session": current_session, "library": args.library,
                "capture_host": args.capture, "routes": routes, "volume": 15,
                "mode": "synchronized", "exclude_pids": args.exclude_pid})
            # Sound also supplies a non-silent system stream during capture setup.
            sound_stop.clear()
            sound_task = asyncio.create_task(sound())
            await until(lambda event: event["id"] == start and event["event"] == "state"
                and event["payload"].get("state") == "streaming", 120)
            cycle["streaming_ns"] = time.monotonic_ns()
            if args.check_volume:
                cycle["volume_checks"] = []
                for percent in (25, 0, 15):
                    reply = await result(await send("set_volume", {"session": current_session,
                        "volume": percent}), 8)
                    payload = reply["payload"]
                    if (payload.get("state") != "volume_applied" or payload.get("volume_percent") != percent
                            or payload.get("applied_outputs") != len(routes)):
                        raise RuntimeError("volume acknowledgement did not cover the receiver group")
                    cycle["volume_checks"].append(payload)
                    try:
                        await until(lambda _: False, 3)
                    except asyncio.TimeoutError:
                        pass
            try:
                # Any unsolicited event/error is inspected during the full interval.
                await until(lambda _: False, cycle["requested_seconds"])
            except asyncio.TimeoutError:
                pass
            cycle["stop_requested_ns"] = time.monotonic_ns()
            stop = await send("stop", {"session": current_session})
            terminal = await result(start, 20)
            stopped = await result(stop, 20)
            cycle["terminal"] = terminal["payload"]
            cycle["stop"] = stopped["payload"]
            cycle["stop_confirmed_ns"] = time.monotonic_ns()
            current_session = None
            sound_stop.set()
            cycle["local_sound_runs"] = await asyncio.wait_for(sound_task, 6)
            sound_task = None
            if not terminal["payload"].get("cleanup_complete") or not stopped["payload"].get("cleanup_complete"):
                raise RuntimeError("group cleanup was not confirmed")
            await asyncio.sleep(2)
        await result(await send("shutdown"))
        worker.stdin.close()
        await asyncio.wait_for(worker.wait(), 5)
        report["worker_exit_code"] = worker.returncode
        report["control_path_verified"] = worker.returncode == 0
    except BaseException as exc:
        report["errors"].append({"type": type(exc).__name__, "message": str(exc)})
    finally:
        sound_stop.set()
        if sound_task:
            try:
                await asyncio.wait_for(asyncio.shield(sound_task), 6)
            except BaseException:
                sound_task.cancel()
                with contextlib.suppress(BaseException):
                    await asyncio.wait_for(sound_task, 5)
        if worker.returncode is None:
            try:
                if current_session:
                    await result(await send("stop", {"session": current_session}), 20)
                await result(await send("shutdown"), 15)
                worker.stdin.close()
                await asyncio.wait_for(worker.wait(), 5)
            except BaseException:
                worker.terminate()
                try:
                    await asyncio.wait_for(worker.wait(), 5)
                except asyncio.TimeoutError:
                    worker.kill()
                    await asyncio.wait_for(worker.wait(), 3)
                report["forced_worker_exit"] = True
        done, pending = await asyncio.wait({reader, errors}, timeout=3)
        for pending_task in pending:
            pending_task.cancel()
        if pending:
            await asyncio.wait(pending, timeout=1)
        report["worker_stderr_tail"] = stderr_tail.decode(errors="replace")
    print(json.dumps(report, indent=2))
    return 0 if report.get("control_path_verified") and not report["errors"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("python", "project", "library", "capture", "hosts"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--seconds", type=int, default=30, choices=range(10, 121))
    parser.add_argument("--exclude-pid", type=int, action="append", default=[])
    parser.add_argument("--check-volume", action="store_true")
    sys.exit(asyncio.run(check(parser.parse_args())))
