# T016：接口不变的有界持续流

日期：2026-11-05。实现角色：底层Agent；后续交接/执行由总协调接手。状态：实现与执行验证完成，独立终审待补。

## 交付

新增 `adapters/airplay_pyatv/streaming.py`：按需ToneReader/PCM WavReader、BoundedHub、逐路StreamingSource、StreamingPatches与stream_play/stream_dry_run。CLI新增显式 `stream`，`--dry-run`完全离线；有声运行需targets，默认15%。原play/dry-run保持可用。

没有修改两个公共头、C ABI九个符号或回调/错误码/状态语义。使用已有Engine.submit逐块通过真实native路由，全路有容量才读取下个输入块。队列暂空与EOF分开，部分消费首块按驻留完整PCM计入上限。慢消费者超时、迟到、源故障、取消或stop使全组退出并唤醒等待者。复用M1时间映射、ALAC、全帧/padding检查及清理。

## 复现

在Mac `core-m2-validation/source`，使用现有venv及 `../build/core/libflow_bridge.dylib`：

```sh
python -m adapters.airplay_pyatv stream --dry-run --library ../build/core/libflow_bridge.dylib --seconds 60 --report ../stream-dry-run.json
```

以下为有声测试，只在需要设备测试时运行，IP以发现结果为准：

```sh
python -m adapters.airplay_pyatv stream --library ../build/core/libflow_bridge.dylib --seconds 60 --channels 2 --target 0=192.168.0.104 --target 1=192.168.0.115 --volume 15 --report ../two-device-stream-60s.json
```

当前Mac地址由108变100，SSH按原主机密钥验证后恢复，文件目录不变。

## 结果和边界

Mac构建、CTest2/2、Python42/42零跳过、冻结头C消费者、旧客户端加载新库、60秒逻辑流dry-run均通过。两台真实60秒发送完成，各2646000帧、7518次native提交；每路PCM消费哈希一致、内容不同、共同时间线；队列峰值704/1408帧。同一进程两次3秒播放也完成，每次补丁恢复，无遗留异步任务。证据见 [M2报告](../reports/M2-stream-acceptance-2026-11-05.md)及reports/M2-macos。

这是有限时长的增量读取链路（reader最多3600秒），不是系统捕获或无限输入。队列峰值不是全进程RSS；未测小时级稳定、量化漂移或断线自动重连。真机重启是自然EOF后重启，未实测中途取消/拔电恢复。

底层及验收Agent最后触发usage limit，未完成最后交接/原始结果复核；总协调接手执行，独立终审保留待补。
