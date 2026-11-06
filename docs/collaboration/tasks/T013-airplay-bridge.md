# T013：原生核心 C ABI 与有限 AirPlay 桥接

负责人：底层开发 Agent。日期：2026-11-05。

状态：实现已交付；协调已在Mac完成构建、原生契约与全部32项Python测试及真实CLI dry-run，均通过，QA复核中。真实设备验证受阻，未播音。禁止把历史原型试听当成本轮通过。

## 文件与职责

- `core/src/bridge.cpp`：ABI v1句柄、三回调、host时钟、异常边界、错误码与诊断。
- 根与core的CMake：`flow_bridge`共享库，C语言独立消费测试。
- `bindings/python/flow_core.py`：ctypes声明、回调保活、数值范围校验、有界CaptureOutput。
- `adapters/airplay_pyatv/render.py`：所有样本经C++分路，复制native输出，有限BE PCM预渲染。
- `source.py`：仅消费native路由内容的pyatv AudioSource。
- `session.py`：统一patch所有权、ALAC、准备屏障、延迟映射、过期拒绝、显式音量、清理和发送报告。
- `cli.py`/`__main__.py`：dry-run（完全离线）、scan（显式发现）、play（显式播音）；默认15%音量。
- `timing.py`和公共ABI头由架构Agent独立维护；tests由验收Agent维护。

## 分阶段交接

1. 原生ABI与Python binding先交付。协调已在Mac实际configure/build/CTest通过，包括既有M0 21组及真实C consumer。
2. renderer/AudioSource与完整sender已交付。协调可按adapter README复制并运行dry-run、独立Python测试。Python本机compileall和CLI帮助已检查。
3. 真机部分必须单独记录新桥接播放、清理和录音证据；当前网络可达性仍由协调排查，底层未触发网络、音箱或远程操作。

## 协调实际验证结果与复现

2026-11-05 协调 Agent 在Mac执行最终CMake configure/build成功，CTest 2/2通过（M0 21组与C语言ABI consumer）；32项Python测试全部通过、0跳过；真实CLI dry-run通过。三路native输出PCM哈希不同，各自AudioSource完整消费后的哈希与对应native输出相同。27个文件manifest无漂移。证据目录：[M1-macos](../reports/M1-macos/)。这些执行结果由协调提供，底层未自行远程运行；QA最终报告复核中。

仓库根目录复现（需已有依赖及本机C++工具链）：

```sh
cmake -S . -B build -DFLOW_BUILD_TESTS=ON
cmake --build build
ctest --test-dir build --output-on-failure
FLOW_CORE_LIBRARY="$PWD/build/core/libflow_bridge.dylib" python -m unittest tests.test_native_binding tests.test_airplay_timing tests.test_airplay_bridge tests.test_airplay_session -v
python -m adapters.airplay_pyatv dry-run --library build/core/libflow_bridge.dylib --seconds 3 --report artifacts/m1-dry-run.json
```

动态库路径上述为macOS，Windows/Linux需替换。真实CLI scan/play显式命令见adapter README。当前Mac到音箱连接报socket errno65，且小黑未发现，所以新桥接未发起实际播放，也未产生本轮声学同步证据。

## 重要语义

数据链：输入PCM -> C ABI -> C++ PlaybackEngine -> N路回调 -> 有限native内容副本 -> 自定义AudioSource -> ALAC -> pyatv原发送循环。未调用旧sync_probe或旧adapter。

全部接收端进入屏障后才生成有效新计划。core预计播放origin扣除协议latency得到send origin，共享同一个NTP映射；准备/渲染过期拒绝整组，不跳过guard。结束同时检查AudioSource全部帧及latency padding。异常取消任务/连接、关闭sources、有限等待、恢复所有patch；不完整清理显式失败。

默认有限8秒lead，最长30秒音频，最多8输出且总样本有界；实际发送仅44100Hz signed16 stereo，输入WAV无隐式降混/重采样。模型为串行非实时，不含漂移、重连或音画控制。CABI兼容目标Windows/macOS/Linux，实际构建平台需按报告如实列出。
