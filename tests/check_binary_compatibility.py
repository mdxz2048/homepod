"""Run an existing, unchanged C client against a replacement dylib (macOS)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old-consumer",type=Path,required=True)
    parser.add_argument("--old-consumer-sha256",required=True)
    parser.add_argument("--new-library",type=Path,required=True)
    parser.add_argument("--report",type=Path,required=True)
    args=parser.parse_args(argv)
    report={"passed":False,"binary_recompiled":False,"platform":sys.platform}
    try:
        if sys.platform!="darwin":raise RuntimeError("this dyld execution gate requires macOS; unsupported is not Pass")
        client=args.old_consumer.resolve(strict=True);library=args.new_library.resolve(strict=True)
        before=digest(client)
        if before!=args.old_consumer_sha256.lower():raise RuntimeError("old consumer hash does not match pre-saved binary")
        report.update(old_consumer=str(client),old_consumer_sha256=before,new_library=str(library),
                      new_library_sha256=digest(library))
        linked=subprocess.run(["otool","-L",str(client)],capture_output=True,text=True,check=True)
        if library.name not in linked.stdout:raise RuntimeError("old consumer does not link the expected library basename")
        env=os.environ.copy();env["DYLD_LIBRARY_PATH"]=str(library.parent);env["DYLD_PRINT_LIBRARIES"]="1"
        result=subprocess.run([str(client)],env=env,capture_output=True,text=True,timeout=30)
        report.update(returncode=result.returncode,stdout=result.stdout,dyld_stderr=result.stderr,
                      otool_dependencies=linked.stdout)
        if result.returncode:raise RuntimeError("old consumer failed against replacement library")
        loaded_lines=[line for line in result.stderr.splitlines() if str(library) in line]
        if not loaded_lines:raise RuntimeError("dyld evidence does not prove replacement library loaded")
        if digest(client)!=before:raise RuntimeError("old executable changed during gate")
        report.update(passed=True,actual_replacement_load=loaded_lines)
    except Exception as error:
        report["error"]=f"{type(error).__name__}: {error}"
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report["passed"] else 1


if __name__=="__main__":raise SystemExit(main())
