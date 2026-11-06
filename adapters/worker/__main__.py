"""python -u -m adapters.worker: stdin/stdout UTF-8 NDJSON, stderr diagnostics."""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import sys
import threading

from .protocol import MAX_LINE_BYTES
from .server import WorkerServer


class InputPump:
    """Daemon reader, so shutdown does not wait for an open stdin pipe."""
    def __init__(self, stream, loop, queue):
        self.stream, self.loop, self.queue = stream, loop, queue
        self.closed = threading.Event()

    def _put(self, item):
        if self.closed.is_set():
            return False
        future = asyncio.run_coroutine_threadsafe(self.queue.put(item), self.loop)
        try:
            future.result()
            return not self.closed.is_set()
        except BaseException:
            return False

    def run(self):
        try:
            while not self.closed.is_set():
                line = self.stream.readline(MAX_LINE_BYTES + 1)
                if not line:
                    self._put(None)
                    return
                if len(line) > MAX_LINE_BYTES:
                    # Drain this one oversized message without retaining it.
                    while not line.endswith(b"\n"):
                        line = self.stream.readline(MAX_LINE_BYTES + 1)
                        if not line:
                            break
                    if not self._put(b"!"):
                        return
                    continue
                if not self._put(line):
                    return
        except BaseException:
            self._put(None)


async def serve(stdin, stdout):
    def emit(event):
        try:
            encoded = (json.dumps(event, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode("utf-8")
            if len(encoded) > MAX_LINE_BYTES:
                event = {"v": 1, "id": event["id"], "event": "error", "session": event["session"],
                         "payload": {"code": "operation_failed", "message": "worker response exceeds 64 KiB"}}
                encoded = (json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
            stdout.write(encoded)
            stdout.flush()
        except BrokenPipeError:
            # A disconnected supervising app cannot receive further events.
            raise

    queue = asyncio.Queue(maxsize=16)
    pump = InputPump(stdin, asyncio.get_running_loop(), queue)
    thread = threading.Thread(target=pump.run, name="flow-worker-stdin", daemon=True)
    thread.start()
    server = WorkerServer(emit)
    try:
        while not server.shutting_down:
            line = await queue.get()
            if line is None:
                break
            await server.handle_line(line)
        return await server.eof()
    finally:
        pump.closed.set()


def main():
    protocol_stdout = sys.stdout.buffer
    protocol_stdin = sys.stdin.buffer
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    # All library prints go to diagnostics; emit retains the original binary pipe.
    with contextlib.redirect_stdout(sys.stderr):
        try:
            code = loop.run_until_complete(serve(protocol_stdin, protocol_stdout))
        except (BrokenPipeError, KeyboardInterrupt):
            code = 2
        except BaseException as exc:
            print(f"worker stopped ({type(exc).__name__})", file=sys.stderr, flush=True)
            code = 2
    if code:
        # An uncertain worker is disposable; never enter another session or wait
        # forever for an uncooperative task during interpreter shutdown.
        protocol_stdout.flush()
        os._exit(code)
    # There is no default-executor stdin reader to wait for. Session cleanup has
    # already completed; cancel only remaining protocol-pump scheduling work.
    pending = asyncio.all_tasks(loop)
    if pending:
        for task in pending:
            task.cancel()
        _done, remaining = loop.run_until_complete(asyncio.wait(pending, timeout=.25))
        if remaining:
            protocol_stdout.flush()
            os._exit(2)
    loop.run_until_complete(loop.shutdown_asyncgens())
    loop.close()
    # The stdin daemon may still own CPython's BufferedReader lock while the
    # parent deliberately keeps its pipe open. All session/loop cleanup above
    # has completed; bypass interpreter finalization, which can otherwise abort
    # on that unrelated reader lock (observed on macOS Python 3.12).
    protocol_stdout.flush()
    sys.stderr.flush()
    os._exit(0)


if __name__ == "__main__":
    raise SystemExit(main())
