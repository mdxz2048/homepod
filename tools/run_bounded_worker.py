"""Bound the lifetime and shell-call count of a local, headless worker."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time


def stop_tree(process):
    if os.name == 'nt':
        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       creationflags=subprocess.CREATE_NO_WINDOW, check=False)
    else:
        process.kill()
    process.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--task', required=True)
    parser.add_argument('--log', required=True)
    parser.add_argument('--timeout', type=int, default=480)
    parser.add_argument('--max-exec-calls', type=int, default=14)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or args.timeout <= 0 or args.max_exec_calls <= 0:
        parser.error('a command and positive limits are required')
    log_path = Path(args.log)
    deadline = time.monotonic() + args.timeout
    with open(args.task, 'rb') as task, log_path.open('wb') as log:
        process = subprocess.Popen(command, stdin=task, stdout=log, stderr=log,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        try:
            while process.poll() is None:
                time.sleep(1)
                calls = sum(line.strip() == b'exec' for line in log_path.read_bytes().splitlines())
                reason = ('runtime limit' if time.monotonic() >= deadline else
                          'shell-call limit' if calls > args.max_exec_calls else None)
                if reason and process.poll() is None:
                    stop_tree(process)
                    print(f'Worker stopped: {reason}; partial results require coordinator review.', file=sys.stderr)
                    return 124
            return process.returncode
        except BaseException:
            if process.poll() is None:
                stop_tree(process)
            raise


if __name__ == '__main__':
    sys.exit(main())
