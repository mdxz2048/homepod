"""Independent receiver-volume contract tests; no network or audio IO."""
import asyncio
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from adapters.live.volume import LiveVolumeControl,VolumeNotReady
from adapters.system_worker import SystemWorkerServer,parse_system_request
from adapters.worker.protocol import ProtocolError

SID="C83F2483-A5EB-498A-A478-ACD581BD3323"

def request(rid,command,params=None):
    return (json.dumps({"v":1,"id":rid,"command":command,"params":params or {}},allow_nan=True)+"\n").encode()


class Receiver:
    def __init__(self,gate=None,failure=None):
        self.audio=self;self.values=[];self.gate=gate;self.failure=failure
    async def set_volume(self,value):
        self.values.append(value)
        if self.gate:await self.gate.wait()
        if self.failure:raise self.failure


class LiveVolumeAcceptance(unittest.IsolatedAsyncioTestCase):
    async def test_finite_range_and_readiness_have_no_receiver_side_effect(self):
        group=LiveVolumeControl();receiver=Receiver();group.bind([receiver])
        for value in (True,None,"15",-.1,100.1,10**400,float("nan"),float("inf")):
            with self.subTest(value=value),self.assertRaises(ValueError):await group.set_volume(value)
        with self.assertRaises(VolumeNotReady):await group.set_volume(15)
        group.ready=True
        for value in (0,15.5,100):self.assertEqual(await group.set_volume(value),1)
        group.close()
        with self.assertRaises(VolumeNotReady):await group.set_volume(15)
        with self.assertRaises(VolumeNotReady):group.bind([Receiver()])
        self.assertEqual(receiver.values,[0,15.5,100])

    async def test_ack_waits_for_every_receiver_and_commands_do_not_overlap(self):
        gate=asyncio.Event();left,right=Receiver(),Receiver(gate)
        group=LiveVolumeControl();group.bind([left,right]);group.ready=True
        first=asyncio.create_task(group.set_volume(25))
        for _ in range(10):await asyncio.sleep(0)
        second=asyncio.create_task(group.set_volume(30))
        for _ in range(10):await asyncio.sleep(0)
        self.assertFalse(first.done());self.assertEqual(left.values,[25]);self.assertEqual(right.values,[25])
        gate.set();self.assertEqual(await first,2);self.assertEqual(await second,2)
        self.assertEqual(left.values,[25,30]);self.assertEqual(right.values,[25,30])

    async def test_closing_during_inflight_update_never_returns_success(self):
        gate=asyncio.Event();receiver=Receiver(gate)
        group=LiveVolumeControl();group.bind([receiver]);group.ready=True
        update=asyncio.create_task(group.set_volume(15))
        while not receiver.values:await asyncio.sleep(0)
        group.close();gate.set()
        with self.assertRaises(VolumeNotReady):await update

    async def test_receiver_timeout_is_bounded_and_partial_ack_is_not_success(self):
        gate=asyncio.Event();receiver=Receiver(gate);other=Receiver()
        group=LiveVolumeControl();group.bind([receiver,other]);group.ready=True
        with self.assertRaises(RuntimeError):await asyncio.wait_for(group.set_volume(15),4.5)
        self.assertEqual(other.values,[15])
        group.close()


class WorkerVolumeAcceptance(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory=tempfile.TemporaryDirectory();self.addCleanup(self.directory.cleanup)
        self.library=Path(self.directory.name)/"not-loaded";self.library.write_bytes(b"fixture")
        self.events=[];self.receivers=[Receiver(),Receiver()];self.ready=True;self.clean=True
        self.entered=asyncio.Event()
        async def runner(params,report):
            control=params["_volume_control"];control.bind(self.receivers);control.ready=self.ready
            self.entered.set()
            try:await asyncio.Event().wait()
            finally:
                control.close()
                report.update(input_closed=self.clean,hub_stopped=self.clean,cleanup_complete=self.clean)
        async def scanner(params):raise AssertionError("implicit scanning")
        self.server=SystemWorkerServer(self.events.append,runner=runner,scanner=scanner,stop_timeout=.2)
        self.addAsyncCleanup(self.server.eof)

    async def send(self,rid,command,params=None):await self.server.handle_line(request(rid,command,params))
    async def start(self):
        await self.send("start","start",{"session":SID,"library":str(self.library),"capture_host":sys.executable,
            "routes":[{"output_id":0,"channels":[0,1],"host":"offline-never-contacted"}]})
        await asyncio.wait_for(self.entered.wait(),.2)
    def reply(self,rid):return next(e for e in self.events if e["id"]==rid)

    async def test_parser_and_hello_are_passive_and_reject_invalid_volume(self):
        await self.send("hello","hello")
        self.assertTrue(self.reply("hello")["payload"]["capabilities"]["realtime_volume"])
        self.assertFalse(self.entered.is_set());self.assertFalse(any(r.values for r in self.receivers))
        for value in (True,None,"15",-1,101,10**400,float("nan"),float("inf")):
            with self.subTest(value=value),self.assertRaises(ProtocolError):
                parse_system_request(request("invalid","set_volume",{"session":SID,"volume":value}))
        await self.send("idle","set_volume",{"session":SID,"volume":15})
        self.assertEqual(self.reply("idle")["payload"]["code"],"stale_session")

    async def test_not_ready_and_stale_session_never_touch_group(self):
        self.ready=False;await self.start()
        await self.send("preparing","set_volume",{"session":SID,"volume":15})
        self.assertEqual(self.reply("preparing")["payload"]["code"],"not_ready")
        await self.send("stale","set_volume",{"session":"00000000-0000-4000-8000-000000000001","volume":15})
        self.assertEqual(self.reply("stale")["payload"]["code"],"stale_session")
        self.assertFalse(any(r.values for r in self.receivers))
        self.assertIsNotNone(self.server.active)

    async def test_whole_group_ack_updates_matching_session_only(self):
        await self.start()
        for index,value in enumerate((0,15,30)):
            await self.send(str(index),"set_volume",{"session":SID,"volume":value})
            reply=self.reply(str(index));self.assertEqual(reply["event"],"result")
            self.assertEqual(reply["session"],SID)
            self.assertEqual(reply["payload"],{"state":"volume_applied","volume_percent":value,"applied_outputs":2})
        self.assertTrue(all(r.values==[0,15,30] for r in self.receivers))
        self.assertEqual(self.server.active.report["volume_updates"],3)

    async def test_partial_failure_stops_group_and_does_not_ack_applied(self):
        self.receivers[1].failure=RuntimeError("receiver failure")
        await self.start();await self.send("partial","set_volume",{"session":SID,"volume":25})
        reply=self.reply("partial")
        self.assertEqual(reply["event"],"error");self.assertEqual(reply["payload"]["code"],"volume_failed")
        self.assertTrue(reply["payload"]["cleanup_complete"])
        self.assertIsNone(self.server.active)
        self.assertFalse(any(e["payload"].get("state")=="volume_applied" for e in self.events))

    async def test_partial_failure_without_clean_teardown_poisons_worker(self):
        self.clean=False;self.receivers[0].failure=RuntimeError("receiver failure")
        await self.start();await self.send("partial","set_volume",{"session":SID,"volume":25})
        self.assertFalse(self.reply("partial")["payload"]["cleanup_complete"])
        self.assertTrue(self.server.poisoned)


if __name__=="__main__":unittest.main(verbosity=2)
