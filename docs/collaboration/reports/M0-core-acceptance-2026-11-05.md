# M0 核心独立验收记录

日期：2026-11-05。执行者：独立验收 Agent；Mac 构建操作由总协调执行并回传日志。

## 基线与范围

项目初始没有已提交的项目基线，原型以 `baselines/M0-original-source.json` 的 SHA-256 和字节长度锁定。C++ 集成源码以持久化清单 `baselines/M0-core-source.json` 的 9 个文件哈希锁定，验收 Agent 已逐项对比当时集成文件，0 个不一致。后续 M1 修改不改变此历史验收范围。关键哈希：

- core/include/flow/core.hpp：`cc80791029982e4fd0d3cd920b7f1bcf50cdb4d63542035209b1e12354fac64c`
- core/src/core.cpp：`1abee0bddee26a5f03fa0a29cc5cc499c98380ad4368fd5f7493c7fa34c5c4d2`
- tests/core_contract_tests.cpp：`fd52bd738c3c689f8a15ff39af026e2a1ebc68fbfc1b1824c1847105a1a80ce8`

本轮采用注入时钟和内存模拟输出验证 C++17 行为。没有网络发现或实际音箱播放；成功 enqueue 只表示接收，不表示声学播放。

## 已执行结果

Windows 命令：`.venv/Scripts/python.exe tests/verify_prototype.py`

环境：Windows 10 build 19045，CPython 3.10.0（64-bit AMD64），使用项目现有 .venv；无新增依赖。

结果：3/3 Pass，退出码 0；首次耗时约 0.182 秒，集成代码落盘后复跑约 0.205 秒，仍全部通过。

- 原型及历史报告共 10 个基线文件的内容哈希、长度全部不变。
- 根目录 Python 源码全部 AST 语法检查通过。
- sync_probe/alac_adapter 安全导入通过，未调用 main/run/discovery 或播放。

Windows 环境没有可用原生编译器，未安装新依赖。核心 C++ 编译/执行由总协调使用既有 Mac 工具链进行，独立验收 Agent 审核了[原始构建日志](M0-macos-validation.log)，逐组结果与本地最新用例一致。

Mac 环境：Apple clang 21.0.0（clang-2100.1.1.101），target arm64-apple-darwin25.5.0，Xcode-26.6.0.app，CMake 3.27.8。构建为 Debug。

| 检查 | 实际结果 |
|---|---|
| CMake configure | exit 0 |
| CMake build：核心静态库、例子、独立测试 | exit 0 |
| CTest | 1/1 target Pass，0 failed，约 0.52 秒 |
| 直接执行独立测试 | 21/21 行为组 Pass，exit 0 |
| 离线示例 | exit 0，三路内容不同且共同 presentation_ns=1500000000；队列满后 WouldBlock 和全组 Faulted |

未执行 sanitizers、性能压力、Windows/Linux 原生构建；不据此推定这些项目通过。

## 核心交付用例

21 个离线行为组覆盖：1/3/5 路独立内容、重复通道顺序、数据所有权、共同 origin 与帧时间；格式/路由/能力检查；部分 prepare 清理；lead 和块末尾时间溢出；非法块不推进且可重试；epoch/重复/缺帧拒绝；部分接收后的 WouldBlock 全组 fail-stop；传输异常；stop/重启/析构；重复 output 实例和 null clock。

## 当前结论

原型保护：Pass。M0 核心离线契约：Pass，21 个行为组全部通过，未发现阻断缺陷。整体产品：Not Tested，未据此声称核心 AirPlay 链路已完成。满足进入 M1 真实 AirPlay 适配的前置条件。

真实 HomePod 多路出声、录音定量误差、长时间漂移、Mac 实时捕获和自动恢复均未在本轮执行。其他平台只具备源码边界设计，Windows/Linux 原生运行尚未验证。M0 的 C++ API 是源码契约，不是稳定 C ABI 或实时回调安全接口。
