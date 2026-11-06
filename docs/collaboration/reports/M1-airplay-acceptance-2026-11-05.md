# M1 桥接独立验收记录

日期：2026-11-05。状态：软件桥接离线切片 Pass；M1 整体验收未通过，真机与声学验证待完成。

本轮目标是验证版本化原生接口、Python ctypes、实际 C++ 分路与 AirPlay 自定义源的完整连接。只运行旧原型不能证明该链路通过。原生/离线测试由总协调在现有 Mac 工具链执行，验收 Agent 独立审核日志及源文件哈希。

## 时序独立审计

依据项目本地 pyatv==0.18.0 源码：

- protocols/raop/protocols/__init__.py：rtptime=head_ts-(start_ts-latency)，默认 latency=66150 帧，44100 Hz 时为 1.5 秒。
- protocols/raop/stream_client.py ControlClient._sync_task：将 RTP 的 rtptime-latency 与 ts2ntp(head_ts) 绑定，并携带 rtptime。
- StreamClient._send_packet：首包使用 context.rtptime，发送后按帧数增加 head_ts。
- StreamClient.send_audio：reset 之后先启动 control、record、flush，随后进入 _stream_data；桥接需要推迟 control sync，等全部准备并统一映射后再释放。

由此推导：core presentation origin 若为预期首帧呈现时间，send_origin=core_origin-latency_ns；冻结单调时钟/NTP锚点，start_ts=head_ts=ntp2ts(NTP(send_origin),rate)，首包 RTP=latency。此处属于协议计划审计，不是声学时间测量。

计划验证：统一计划、映射精度与同组一致、迟到/能力不足拒绝；C++输出实际被AudioSource消费；CABI与完整清理；无隐式播放。

## 执行结果

原生 C ABI 测试：tests/bridge_c_contract.c，覆盖原生 C 类型/版本/null、route 内存复制、不同内容、共同时间、epoch、启停、部分准备失败、背压。最终 Mac 构建及运行原始日志已独立审核：[validation.log](M1-macos/validation.log)。

Python 用例已冻结：native binding 11 项、时序 6 项、native->source 串联 3 项、session/CLI 12 项、原型保护 3 项，共 35 项。涉及动态库者使用 FLOW_CORE_LIBRARY 指向真实编译产物；fake 仅代替网络和时钟，不替代 C++ 路由。

Windows 独立执行：时序 6 项全部 Pass（使用本地实际 pyatv StreamContext 与 timing 反向验证首包/后续 RTP）；原型保护 3 项通过；非 native 的 scoped patch、部分安装恢复、barrier timeout、latency 不同拒绝、同步 close 异常、取消、CLI 失败状态等项通过。

最终 Mac 实际结果：

| 检查 | 独立审核结果 |
|---|---|
| CMake Debug build | 核心静态库、C ABI dylib、原生 C 消费者、原 M0 例子及测试均成功，exit 0 |
| CTest verbose | 2/2 target Pass；原 M0 21/21 行为组未退化，C 消费者 Pass |
| Python unittest discover test_*.py | 32/32 Pass，0 skip，约 0.048 秒，加载实际 libflow_bridge.dylib |
| CLI 实际 dry-run | 一秒三路，各 44100 帧，126 个 native routed blocks，exit 0，network_used=false |
| 数据完整性 | 三路 PCM 哈希不同；各自经 CoreAudioSource 消费后的哈希与 native 输出完全相等 |
| 源包一致性 | 当前 27 文件、Mac source-manifest.json、持久化 baselines/M1-core-source.json 三方哈希逐项一致，0 漂移 |

环境：Apple clang 21.0.0（clang-2100.1.1.101），arm64-apple-darwin25.5.0，Xcode-26.6.0.app，项目既有 Mac Python venv。原型保护脚本名为 verify_prototype.py，不包含在 Mac 的 test_*.py 32 项发现结果中；另在 Windows 执行 3/3 通过，合计 35 项 Python 检查但不称为 Mac 35 项。

可复现命令（项目根目录，FLOW_CORE_LIBRARY 指向实际动态库）：

```sh
cmake -S . -B build/m1 -DFLOW_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build/m1
ctest --test-dir build/m1 -V
FLOW_CORE_LIBRARY="$PWD/build/m1/core/libflow_bridge.dylib" .venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
.venv/bin/python -m adapters.airplay_pyatv dry-run --library build/m1/core/libflow_bridge.dylib --seconds 1
```

原始 dry-run JSON：[dry-run.json](M1-macos/dry-run.json)。本轮持久化源包基线：[M1-core-source.json](../baselines/M1-core-source.json)。

## 发现与修复

| 缺陷 | 影响 | 修复及复测 |
|---|---|---|
| Engine 构造前期失败时 _handle 未设，析构发生 unraisable AttributeError | 库路径/参数错误产生二次异常 | owner 提前初始化 _handle；Windows 独立构造失败用例 Pass |
| Python 多 ID 绑定同输出对象绕过独立实例约束 | 输出状态及清理语义歧义 | owner 拒绝别名；最终 Mac 加载真实动态库用例 Pass |
| 异步 connection.close task 抛错仍报 cleanup_complete=True | 故障清理报告失真 | 独立用例先实际 Fail，owner 区分 close tasks 并记录异常，Windows 独立复测 Pass |

清理测试覆盖主动取消、源与连接关闭、异常诚实报告；不宣称已验证现实网络或永久不响应的系统调用。代码增加尾部 padding_sent>=latency 成功条件，真机尾部完整呈现尚未验证。

## 未验证范围

本轮尚未量化实际出声同步、设备内部延迟或漂移。未通过真机录音前不能宣布同步通过；跨平台源码边界不等于 Windows/Linux 已执行验证。无自动系统捕获或 UI 验收。

总协调报告 Mac 局域网 socket 出现 errno 65，且未发现小黑，实际接收端连通条件未满足。此为待解决的环境条件，不能用离线用例代替三台真机、原生 AirPlay 发包及声学验收。验收 Agent 未自行播放音箱。当前仅可确认软件桥接已接通并满足离线契约；下一步必须补真实三台不同内容、重复启动/停止、尾部完整播放与录音测量。
