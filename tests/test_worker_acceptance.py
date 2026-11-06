"""Independent T018 protocol/lifecycle checks. No scanning or speaker playback."""
import asyncio
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
import wave

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from adapters.worker.server import WorkerServer


def request(identifier,command,params=None):
    return json.dumps({"v":1,"id":identifier,"command":command,"params":params or {}},allow_nan=False).encode()+b"\n"


class WorkerProcessAcceptance(unittest.TestCase):
    def worker(self,payload):
        return subprocess.run([sys.executable,"-u","-m","adapters.worker"],cwd=ROOT,
                              input=payload,capture_output=True,timeout=8)

    def events(self,result):
        lines=result.stdout.splitlines(keepends=True)
        self.assertTrue(all(line.endswith(b"\n") and len(line)<=65536 for line in lines))
        return [json.loads(line) for line in lines]

    def test_shutdown_exits_cleanly_while_parent_keeps_stdin_open(self):
        child=subprocess.Popen([sys.executable,"-u","-m","adapters.worker"],cwd=ROOT,
                               stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            child.stdin.write(request("qa-shutdown","shutdown"));child.stdin.flush()
            self.assertEqual(child.wait(timeout=5),0)
            events=[json.loads(line) for line in child.stdout.read().splitlines()]
            self.assertEqual(len(events),1)
            self.assertEqual(events[0]["payload"]["state"],"shutdown")
            self.assertTrue(events[0]["payload"]["cleanup_complete"])
            self.assertNotIn(b"Fatal Python error",child.stderr.read())
        finally:
            if child.poll() is None:child.kill();child.wait()
            child.stdin.close();child.stdout.close();child.stderr.close()

    def test_partial_final_line_at_eof_never_executes_command(self):
        result=self.worker(request("qa-no-lf","hello").rstrip(b"\n"))
        self.assertFalse(any(e["id"]=="qa-no-lf" and e["event"]=="result" for e in self.events(result)))

    def test_oversized_and_bad_utf8_lines_drain_then_hello_recovers(self):
        result=self.worker(b"x"*70000+b"\n"+b"\xff\n"+request("qa-ok","hello"))
        self.assertEqual(result.returncode,0,result.stderr)
        events=self.events(result)
        self.assertEqual(sum(e["event"]=="error" for e in events),2)
        good=[e for e in events if e["id"]=="qa-ok"]
        self.assertEqual(len(good),1)
        self.assertFalse(good[0]["payload"]["capabilities"]["capture"])
        self.assertFalse(any(e["event"] in ("accepted","state") for e in events))

    def test_duplicate_id_is_unassociated_and_cannot_reexecute(self):
        result=self.worker(request("qa-dup","hello")+request("qa-dup","hello"))
        self.assertEqual(result.returncode,0,result.stderr)
        events=self.events(result)
        self.assertEqual(sum(e["id"]=="qa-dup" and e["event"]=="result" for e in events),1)
        duplicate=next(e for e in events if e["event"]=="error")
        self.assertIsNone(duplicate["id"]);self.assertIsNone(duplicate["session"])
        self.assertEqual(duplicate["payload"]["code"],"duplicate_id")
        self.assertEqual(duplicate["payload"]["offending_id"],"qa-dup")

    def test_hello_import_does_not_load_native_or_emit_playback_states(self):
        result=self.worker(request("qa-passive","hello"))
        self.assertEqual(result.returncode,0,result.stderr)
        events=self.events(result)
        self.assertEqual([e["event"] for e in events],["result"])
        self.assertFalse(events[0]["payload"]["capabilities"]["av_offset"])


class WorkerLifecycleAcceptance(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root=Path(self.directory.name)
        self.wav=root/"sample.wav";self.library=root/"fake-native-library"
        self.library.write_bytes(b"offline lifecycle test fixture, never loaded")
        with wave.open(str(self.wav),"wb") as wav:
            wav.setparams((2,2,44100,0,"NONE","not compressed"));wav.writeframes(b"\0"*1764)
        self.events=[]

    def params(self,session=None):
        return {"session":session or str(uuid.uuid4()).upper(),"library":str(self.library),"wav":str(self.wav),
                "execution":"offline","routes":[{"output_id":0,"channels":[0,1]}]}

    async def send(self,server,identifier,command,params=None):
        await server.handle_line(request(identifier,command,params))

    async def settle(self,server):
        if server.active and server.active.task:await asyncio.wait_for(server.active.task,.5)

    async def test_local_file_or_route_failure_is_rejected_before_accepted(self):
        called=[]
        async def runner(params,report):called.append(params)
        server=WorkerServer(self.events.append,runner=runner)
        params=self.params();params["wav"]=str(Path(self.directory.name)/"missing.wav")
        await self.send(server,"missing","start",params);await self.settle(server)
        invalid_route=self.params();invalid_route["routes"][0]["channels"]=[0,2]
        await self.send(server,"bad-route","start",invalid_route);await self.settle(server)
        self.assertFalse(any(e["event"]=="accepted" for e in self.events))
        self.assertFalse(called)

    async def test_active_session_stop_is_ordered_and_stale_stop_cannot_touch_it(self):
        cleaned=asyncio.Event()
        async def runner(params,report):
            try:await asyncio.Event().wait()
            finally:
                report.update(cleanup_complete=True,input_closed=True,hub_stopped=True,acoustic_sync_verified=False)
                cleaned.set()
        server=WorkerServer(self.events.append,runner=runner)
        params=self.params();session=params["session"]
        await self.send(server,"start-a","start",params)
        await self.send(server,"stale","stop",{"session":str(uuid.uuid4())})
        self.assertFalse(cleaned.is_set())
        self.assertEqual(self.events[-1]["payload"]["code"],"stale_session")
        await self.send(server,"stop-a","stop",{"session":session})
        self.assertTrue(cleaned.is_set());self.assertIsNone(server.active)
        terminals=[e for e in self.events if e["event"] in ("result","error") and e["id"] in ("start-a","stop-a")]
        self.assertEqual([e["id"] for e in terminals],["start-a","stop-a"])
        self.assertTrue(all(e["session"]==session for e in terminals))
        self.assertTrue(all(e["payload"]["cleanup_complete"] for e in terminals))
        await self.send(server,"stop-again","stop",{"session":session})
        self.assertTrue(self.events[-1]["payload"]["already_stopped"])

    async def test_uncertain_cleanup_poisons_worker_and_refuses_next_start(self):
        async def runner(params,report):report.update(cleanup_complete=False,input_closed=True,hub_stopped=True)
        server=WorkerServer(self.events.append,runner=runner)
        await self.send(server,"first","start",self.params());await self.settle(server)
        self.assertTrue(server.poisoned)
        self.assertEqual(self.events[-1]["payload"]["code"],"cleanup_failed")
        await self.send(server,"second","start",self.params())
        self.assertEqual(self.events[-1]["payload"]["code"],"worker_poisoned")
        self.assertEqual(sum(e["event"]=="accepted" for e in self.events),1)

    async def test_ended_session_uuid_cannot_be_reused(self):
        async def runner(params,report):report.update(cleanup_complete=True,input_closed=True,hub_stopped=True)
        server=WorkerServer(self.events.append,runner=runner)
        params=self.params()
        await self.send(server,"first","start",params);await self.settle(server)
        await self.send(server,"reuse","start",params);await self.settle(server)
        self.assertFalse(any(e["id"]=="reuse" and e["event"]=="accepted" for e in self.events))
        self.assertTrue(any(e["id"]=="reuse" and e["event"]=="error" for e in self.events))

    async def test_eof_cancels_active_session_without_fabricated_shutdown_id(self):
        async def runner(params,report):
            try:await asyncio.Event().wait()
            finally:report.update(cleanup_complete=True,input_closed=True,hub_stopped=True)
        server=WorkerServer(self.events.append,runner=runner)
        await self.send(server,"start-eof","start",self.params())
        self.assertEqual(await server.eof(),0)
        self.assertIsNone(server.active)
        self.assertTrue(all(e["id"]=="start-eof" for e in self.events))
        self.assertEqual(self.events[-1]["payload"]["state"],"stopped")

    async def test_slow_cancel_poison_cannot_report_clean_stop_or_restart(self):
        release=asyncio.Event()
        async def runner(params,report):
            try:
                try:await asyncio.Event().wait()
                except asyncio.CancelledError:await release.wait()
            finally:report.update(cleanup_complete=True,input_closed=True,hub_stopped=True)
        server=WorkerServer(self.events.append,runner=runner,stop_timeout=.01)
        params=self.params()
        await self.send(server,"slow-start","start",params)
        try:
            await self.send(server,"slow-stop","stop",{"session":params["session"]})
            self.assertTrue(server.poisoned)
            self.assertEqual(self.events[-1]["payload"]["code"],"cleanup_failed")
            await self.send(server,"restart","start",self.params())
            self.assertEqual(self.events[-1]["payload"]["code"],"worker_poisoned")
        finally:
            release.set();await self.settle(server)


if __name__=="__main__":unittest.main(verbosity=2)
