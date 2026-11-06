"""Independent live PCM acceptance. Never capture, scan, or play speakers."""
import array
import asyncio
import copy
import json
import os
from pathlib import Path
import sys
import struct
import tempfile
import unittest
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from adapters.live.hub import LiveHub,LiveFailure
from adapters.live.pcm import Frame,PCMValidator,read_frame
from adapters.live.capture import CaptureHost
from adapters.system_worker import SystemWorkerServer

SESSION="AB12CD34-AB12-4D34-AB12-AB12CD34EF56"

def pcm_frame(sequence=0,first=0):
    source={"sourceRate":44100,"sourceChannels":2,"sourceFrameStart":first,
            "sourceFrames":2,"sourceSequence":sequence,"hostTime":123_000_000_000+first,
            "sampleTime":str(-125.5+first),"flags":3,"nowHostTime":123_000_000_010+first,
            "nowSampleTime":str(-125.0+first),"nowFlags":3,
            "timebaseNumerator":1_000_000_000,"timebaseDenominator":44100,"droppedBlocksBefore":0}
    header={"v":1,"id":"start-qa","session":SESSION,"kind":"pcm","sequence":sequence,
            "outputRate":44100,"outputChannels":2,"outputFrameStart":first,"outputFrames":2,
            "source":source,"inputFramesConsumedTotal":first+2,"converterLeadingFrames":0,
            "converterTrailingFrames":0,"primeMethod":"none","converterDelayKnown":False,
            "timestampRelation":"input_block_metadata"}
    return Frame(header,struct.pack("<4f",.25,-.5,.5,-.25))

def wire(frame):
    header=json.dumps(frame.header,allow_nan=False,separators=(",",":")).encode()
    return struct.pack("<4sII",b"HPCM",len(header),len(frame.payload))+header+frame.payload


class LiveFramingTests(unittest.IsolatedAsyncioTestCase):
    async def test_fragmented_and_coalesced_frames_decode_without_reframing(self):
        first=pcm_frame();second=pcm_frame(1,2)
        reader=asyncio.StreamReader()
        async def feed():
            data=wire(first)+wire(second)
            for offset in range(0,len(data),7):
                reader.feed_data(data[offset:offset+7]);await asyncio.sleep(0)
            reader.feed_eof()
        task=asyncio.create_task(feed())
        self.assertEqual(await read_frame(reader),first)
        self.assertEqual(await read_frame(reader),second)
        await task
        with self.assertRaises(LiveFailure):await read_frame(reader)

    async def test_bad_framing_and_any_truncated_or_empty_eof_is_live_failure(self):
        valid=wire(pcm_frame())
        invalid=[b"",valid[:4],valid[:13],valid[:-1],
                 struct.pack("<4sII",b"NOPE",1,0)+b"{}",
                 struct.pack("<4sII",b"HPCM",16385,0),
                 struct.pack("<4sII",b"HPCM",1,65537)]
        for header in [b'{"v":1,"kind":"ready","x":NaN}',
                       b'{"v":1,"v":1,"kind":"ready"}',b'\xff',
                       b'{"v":true,"kind":"ready"}']:
            invalid.append(struct.pack("<4sII",b"HPCM",len(header),0)+header)
        control=Frame({"v":1,"id":"x","session":SESSION,"kind":"ready"},b"x")
        invalid.append(wire(control))
        for data in invalid:
            with self.subTest(prefix=data[:16]):
                reader=asyncio.StreamReader();reader.feed_data(data);reader.feed_eof()
                with self.assertRaises(LiveFailure):await read_frame(reader)

    async def test_validator_preserves_raw_clock_and_allows_converter_metadata_repetition(self):
        validator=PCMValidator(SESSION,"start-qa")
        frame=pcm_frame()
        frame.header["source"]["sourceFrames"]=4
        frame.header["inputFramesConsumedTotal"]=4
        self.assertEqual(list(validator.pcm(frame)),[.25,-.5,.5,-.25])
        self.assertEqual(validator.frames,2)
        self.assertEqual(validator.first_source["hostTime"],123_000_000_000)
        self.assertEqual(validator.first_source["sampleTime"],"-125.5")
        repeated=pcm_frame(1,2)
        repeated.header["source"]=copy.deepcopy(frame.header["source"])
        repeated.header["inputFramesConsumedTotal"]=4
        self.assertEqual(len(validator.pcm(repeated)),4)
        self.assertEqual((validator.frames,validator.sequence),(4,2))
        stale=copy.deepcopy(repeated.header);stale["session"]=SESSION.lower()
        with self.assertRaises(LiveFailure):validator.correlated(stale)
        stale=copy.deepcopy(repeated.header);stale["id"]="old-command"
        with self.assertRaises(LiveFailure):validator.correlated(stale)

    async def test_invalid_pcm_metadata_and_relative_clock_divergence_rejected(self):
        def mutations(frame):
            return [lambda:frame.header.update(outputFrames=True),lambda:frame.header.update(outputRate=48000),
                    lambda:frame.header.update(sequence=2),lambda:frame.header.update(outputFrameStart=5),
                    lambda:frame.header["source"].update(flags=2),
                    lambda:frame.header["source"].update(droppedBlocksBefore=1),
                    lambda:frame.header["source"].update(sampleTime="nan"),
                    lambda:frame.header.update(converterDelayKnown=True)]
        for index in range(8):
            frame=pcm_frame();mutations(frame)[index]()
            with self.subTest(mutation=index),self.assertRaises(LiveFailure):PCMValidator(SESSION,"start-qa").pcm(frame)
        for payload in [b"bad",struct.pack("<4f",float("nan"),0,0,0)]:
            frame=pcm_frame()
            with self.assertRaises(LiveFailure):PCMValidator(SESSION,"start-qa").pcm(Frame(frame.header,payload))
        validator=PCMValidator(SESSION,"start-qa");validator.pcm(pcm_frame())
        changed=pcm_frame(1,2);changed.header["source"]["hostTime"]+=44100
        with self.assertRaises(LiveFailure):validator.pcm(changed)


class QueueOnlyEngine:
    """DI for queue/fault tests only; does not claim native routing coverage."""
    def __init__(self,*args):self.outputs=[];self.closed=False;self.calls=[]
    def add_output(self,key,mapping,output):self.outputs.append(output)
    def prepare(self):
        for output in self.outputs:assert output.prepare(44100,2)==0
    def start(self,epoch,now,lead):self.origin=now+lead;return self.origin
    def submit(self,epoch,first,samples):
        self.calls.append((epoch,first,len(samples)//2))
        block=SimpleNamespace(channels=2,first_frame=first,samples=samples,
                              presentation_ns=self.origin+first*1_000_000_000//44100)
        for output in self.outputs:assert output.enqueue(block)==0
    def close(self):
        self.closed=True
        for output in self.outputs:output.close()


class LiveHubContractTests(unittest.IsolatedAsyncioTestCase):
    def hub(self,**kwargs):
        defaults=dict(input_capacity_frames=32,block_frames=2,output_capacity_blocks=2,
                      stall_timeout=.03,clock_ns=lambda:1_000_000_000,engine_factory=QueueOnlyEngine)
        defaults.update(kwargs)
        hub=LiveHub("queue-only-fixture",{0:[0,0],1:[1,1]},**defaults)
        self.addAsyncCleanup(hub.stop)
        return hub

    async def test_unknown_duration_and_temporary_empty_waits_without_eof(self):
        hub=self.hub()
        self.assertFalse(hasattr(hub,"total_frames"))
        with self.assertRaises(LiveFailure):hub.start(2_000_000_000)
        await hub.push([.1,.2],receipt_ns=2_000_000_000)
        self.assertEqual(hub.start(2_000_000_000),4_000_000_000)
        await asyncio.gather(hub.read(0,1),hub.read(1,1))
        waiting=asyncio.create_task(hub.read(0,1));await asyncio.sleep(.005)
        self.assertFalse(waiting.done(),"temporary starvation must not emit file EOF/padding")
        await hub.push([.3,.4])
        self.assertEqual(len(await waiting),4)
        await hub.read(1,1)

    async def test_partial_input_head_counts_toward_actual_resident_budget(self):
        hub=self.hub(input_capacity_frames=8,output_capacity_blocks=1)
        await hub.push([.1,.2]*6,receipt_ns=2_000_000_000);hub.start(2_000_000_000)
        await hub.read(0,1)
        # Six frames of array storage remain resident, despite two being routed.
        self.assertEqual(sum(len(x)//2 for x in hub.input_queue),6)
        with self.assertRaises(LiveFailure):await hub.push([.3,.4]*4)
        self.assertTrue(hub.report()["group_failed"])

    async def test_input_budget_failure_closes_all_routes_without_silent_drop(self):
        hub=self.hub(input_capacity_frames=8)
        await hub.push([.1,.2]*8,receipt_ns=2_000_000_000)
        with self.assertRaises(LiveFailure):await hub.push([.3,.4])
        self.assertTrue(hub.engine.closed and hub.stopped)
        self.assertFalse(hub.input_queue)
        self.assertTrue(all(not output.open and not output.queue for output in hub.outputs.values()))
        self.assertEqual(hub.report()["input_frames"],8)

    async def test_slow_peer_timeout_fails_group_and_clears_queues(self):
        hub=self.hub(output_capacity_blocks=1,stall_timeout=.01)
        await hub.push([.1,.2]*6,receipt_ns=2_000_000_000);hub.start(2_000_000_000)
        with self.assertRaises((LiveFailure,TimeoutError,asyncio.TimeoutError)):await hub.read(0,4)
        self.assertTrue(hub.report()["group_failed"] and hub.engine.closed)
        self.assertFalse(hub.input_queue)
        self.assertTrue(all(not out.queue for out in hub.outputs.values()))

    async def test_stop_wakes_infinite_input_waiter_without_returning_pcm_eof(self):
        hub=self.hub(stall_timeout=1)
        await hub.push([.1,.2],receipt_ns=2_000_000_000);hub.start(2_000_000_000)
        await asyncio.gather(hub.read(0,1),hub.read(1,1))
        waiting=asyncio.create_task(hub.read(0,1));await asyncio.sleep(.005)
        await hub.stop();await hub.stop()
        with self.assertRaises(LiveFailure):await asyncio.wait_for(waiting,.1)
        self.assertTrue(hub.engine.closed)

    async def test_capture_fault_is_not_natural_completion(self):
        hub=self.hub(stall_timeout=1)
        await hub.push([.1,.2],receipt_ns=2_000_000_000);hub.start(2_000_000_000)
        await asyncio.gather(hub.read(0,1),hub.read(1,1))
        waiting=asyncio.create_task(hub.read(1,1));await asyncio.sleep(.005)
        await hub.fail(LiveFailure("capture input terminated unexpectedly"))
        with self.assertRaises(LiveFailure):await waiting
        self.assertTrue(hub.report()["group_failed"])
        self.assertIs(hub.report()["acoustic_sync_verified"],False)


class LiveHubNativeTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_native_continuous_blocks_and_distinct_routes_share_media_origin(self):
        library=os.environ.get("FLOW_CORE_LIBRARY")
        self.assertTrue(library,"FLOW_CORE_LIBRARY required: DI queue tests cannot prove native integration")
        hub=LiveHub(library,{0:[0,0],1:[1,1]},input_capacity_frames=352,
                    block_frames=7,output_capacity_blocks=4,clock_ns=lambda:1_000_000_000)
        self.addAsyncCleanup(hub.stop)
        await hub.push(array.array("f",[.25,-.5]*17),receipt_ns=2_000_000_000)
        origin=hub.start(2_000_000_000)
        async def left():return await hub.read(0,7)+await hub.read(0,10)
        for index in range(100):
            if index:await hub.push(array.array("f",[.25,-.5]*17))
            left_bytes,right_bytes=await asyncio.gather(left(),hub.read(1,17))
            self.assertEqual((len(left_bytes),len(right_bytes)),(68,68))
            self.assertNotEqual(left_bytes,right_bytes)
        report=hub.report()
        self.assertTrue(report["native_core_used"])
        self.assertEqual(report["native_submitted_frames"],1700)
        self.assertGreater(report["native_submit_calls"],100)
        self.assertEqual(report["clock_anchor"],"python_first_pcm_receipt_not_native_host_time")
        for output in report["outputs"]:
            self.assertEqual(output["native_frames"],1700)
            self.assertEqual(output["consumed_frames"],1700)
            self.assertEqual(output["native_pcm_sha256"],output["consumed_pcm_sha256"])
            self.assertEqual(output["first_presentation_ns"],origin)
            self.assertLessEqual(output["queue_peak_frames"],output["queue_capacity_frames"])
        self.assertFalse(hub.stopped,"no fabricated finite endpoint may end the stream")


class CaptureLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def pump(self,header,stopping=False):
        failures=[]
        async def fail(error):failures.append(error)
        capture=CaptureHost(sys.executable,SESSION,SimpleNamespace(fail=fail))
        loop=asyncio.get_running_loop()
        capture.ready,capture.stopped_reply=loop.create_future(),loop.create_future()
        capture.stopping=stopping
        capture.process=SimpleNamespace(stdout=asyncio.StreamReader())
        header.update(v=1,session=SESSION,id=capture.stop_id if stopping else capture.start_id)
        capture.process.stdout.feed_data(wire(Frame(header,b"")))
        capture.process.stdout.feed_eof()
        await capture._pump()
        for future in (capture.ready,capture.stopped_reply):
            if future.done():future.exception()
        return capture,failures

    async def test_unrequested_stopped_and_ready_then_eof_fail_live_group(self):
        capture,failures=await self.pump({"kind":"stopped","cleanupComplete":True})
        self.assertEqual(len(failures),1)
        self.assertIsInstance(capture.stopped_reply.exception(),LiveFailure)
        capture,failures=await self.pump({"kind":"ready","outputRate":44100,
                                        "outputChannels":2,"sourceFormat":{}})
        self.assertEqual(len(failures),1)
        self.assertIsInstance(capture.stopped_reply.exception(),LiveFailure)
        self.assertIsNone(capture.ready.exception())

    async def test_stop_ack_requires_honest_converter_tail_and_cleanup_evidence(self):
        complete={"kind":"stopped","cleanupComplete":True,"drainComplete":False,
                  "discardedConverterTail":True}
        for missing in ("drainComplete","discardedConverterTail","cleanupComplete"):
            header=dict(complete);del header[missing]
            capture,_=await self.pump(header,True)
            with self.subTest(missing=missing):
                self.assertIsInstance(capture.stopped_reply.exception(),LiveFailure)
        capture,failures=await self.pump(dict(complete),True)
        self.assertFalse(failures)
        self.assertEqual(capture.stopped_reply.result()["discardedConverterTail"],True)

    async def test_hpcm_stop_requires_both_clean_ack_and_actual_host_exit(self):
        # In-memory subprocess boundary only: never starts an executable or HAL.
        for acknowledged,exit_code in ((True,0),(False,0),(True,7)):
            with self.subTest(acknowledged=acknowledged,exit_code=exit_code):
                async def fail(error):raise AssertionError("controller stop must not fault hub")
                capture=CaptureHost(sys.executable,SESSION,SimpleNamespace(fail=fail))
                loop=asyncio.get_running_loop()
                capture.ready,capture.stopped_reply=loop.create_future(),loop.create_future()
                reader=asyncio.StreamReader();commands=[]
                class Process:
                    stdout=reader
                    returncode=None
                    async def wait(self):self.returncode=exit_code;return exit_code
                process=Process()
                def write(data):
                    command=json.loads(data);commands.append(command)
                    self.assertEqual(command["command"],"stop")
                    header={"v":1,"kind":"stopped","id":command["id"],"session":SESSION,
                            "cleanupComplete":acknowledged,"drainComplete":False,
                            "discardedConverterTail":True}
                    reader.feed_data(wire(Frame(header,b"")));reader.feed_eof()
                async def drain():pass
                process.stdin=SimpleNamespace(write=write,drain=drain,close=lambda:None)
                capture.process=process;capture.pump_task=asyncio.create_task(capture._pump())
                self.assertEqual(await capture.stop(),acknowledged and exit_code==0)
                self.assertEqual(len(commands),1)
                self.assertEqual(capture.report()["capture_cleanup_complete"],acknowledged and exit_code==0)
                self.assertTrue(capture.report()["capture_host_exited"])
                self.assertIs(capture.report()["acoustic_sync_verified"],False)

    async def test_terminal_error_cleanup_is_separate_from_capture_success(self):
        for acknowledged,exit_code,correlated in ((True,3,True),(True,0,True),
                                                  (False,3,True),(True,3,False)):
            with self.subTest(acknowledged=acknowledged,exit_code=exit_code,correlated=correlated):
                failures=[]
                async def fail(error):failures.append(error)
                capture=CaptureHost(sys.executable,SESSION,SimpleNamespace(fail=fail))
                loop=asyncio.get_running_loop()
                capture.ready,capture.stopped_reply=loop.create_future(),loop.create_future()
                reader=asyncio.StreamReader()
                class Process:
                    stdout=reader
                    returncode=exit_code
                    async def wait(self):return exit_code
                def closed_write(data):raise BrokenPipeError("terminal fixture already exited")
                async def drain():pass
                process=Process()
                process.stdin=SimpleNamespace(write=closed_write,drain=drain,close=lambda:None)
                capture.process=process
                header={"v":1,"kind":"error","id":capture.start_id,"session":SESSION if correlated else "stale",
                        "code":"capture_failed","message":"fixture failure","cleanupComplete":acknowledged}
                reader.feed_data(wire(Frame(header,b"")));reader.feed_eof()
                capture.pump_task=asyncio.create_task(capture._pump());await capture.pump_task
                self.assertEqual(len(failures),1)
                self.assertIsInstance(capture.ready.exception(),LiveFailure)
                self.assertIsInstance(capture.stopped_reply.exception(),LiveFailure)
                self.assertEqual(await capture.stop(),acknowledged and exit_code==3 and correlated)
                report=capture.report()
                self.assertEqual(report["capture_blocks"],0)
                self.assertIs(report["acoustic_sync_verified"],False)
                self.assertEqual(report["capture_last_error"],"LiveFailure")


class SystemWorkerLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory=tempfile.TemporaryDirectory();self.addCleanup(self.directory.cleanup)
        self.library=Path(self.directory.name)/"never-loaded-library";self.library.write_bytes(b"fixture")
        self.events=[]

    async def send(self,server,rid,command,params=None):
        line=json.dumps({"v":1,"id":rid,"command":command,"params":params or {}}).encode()+b"\n"
        await server.handle_line(line)

    def params(self):
        return {"session":SESSION,"library":str(self.library),"capture_host":sys.executable,
                "routes":[{"output_id":0,"channels":[0,1],"host":"offline-never-contacted"}]}

    async def test_hello_is_passive_and_natural_runner_return_is_failure(self):
        calls=[]
        async def runner(params,report):
            calls.append(params);report.update(input_closed=True,hub_stopped=True,cleanup_complete=True)
        async def forbidden_scan(params):raise AssertionError("implicit scan")
        server=SystemWorkerServer(self.events.append,runner=runner,scanner=forbidden_scan)
        await self.send(server,"hello","hello")
        self.assertFalse(calls)
        self.assertEqual([e["event"] for e in self.events],["result"])
        await self.send(server,"start","start",self.params())
        if server.active:await asyncio.wait_for(server.active.task,.2)
        self.assertEqual(len(calls),1)
        self.assertTrue(any(e["event"]=="error" and e["payload"]["code"]=="operation_failed" for e in self.events))
        self.assertFalse(any(e["payload"].get("state")=="completed" for e in self.events))
        self.assertFalse(server.poisoned)

    async def test_explicit_stop_confirms_cleanup_and_unclean_stop_poisons(self):
        for clean in (True,False):
            with self.subTest(clean=clean):
                events=[];entered=asyncio.Event()
                async def runner(params,report):
                    entered.set()
                    try:await asyncio.Event().wait()
                    finally:report.update(input_closed=clean,hub_stopped=clean,cleanup_complete=clean)
                server=SystemWorkerServer(events.append,runner=runner,stop_timeout=.2)
                await self.send(server,"start","start",self.params());await entered.wait()
                await self.send(server,"stop","stop",{"session":SESSION})
                reply=next(e for e in events if e["id"]=="stop")
                self.assertEqual(reply["event"],"result" if clean else "error")
                self.assertEqual(server.poisoned,not clean)
                self.assertIsNone(server.active)


if __name__=="__main__":unittest.main(verbosity=2)
