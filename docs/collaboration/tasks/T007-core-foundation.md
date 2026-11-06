# T007：核心库离线基础

负责人：底层开发 Agent。日期：2026-11-05。

状态：实现已交付；协调 Agent 在 Mac 完成构建、21组契约测试和离线例子运行，全部通过，QA报告复核中。

## 本轮交付

- `core/src/core.cpp`：C++17 PlaybackEngine、注入时钟、N 输出逐通道路由、共同未来起点、整数帧时间换算、生命周期和失败清理。
- 根目录及 core 的 `CMakeLists.txt`：无第三方依赖的静态库及离线例子，自动纳入验收 Agent 的 tests 工程。
- `examples/offline_demo.cpp`：纯内存三输出，内容不同、媒体时间一致；有界模拟队列容量2，第三次提交背压触发全组关闭。
- `core/README.md`：构建/直接 clang++ 命令、所有权、状态、限制与证据边界。

公共头文件由架构 Agent 维护，tests 由独立验收 Agent 维护，历史 Python 原型未修改。未触发网络、音箱播放或远程 Mac 修改。

## 实现决策

- prepare 在任何后端操作前检查路由、设备ID/实例唯一性、能力；部分prepare失败关闭所有attempted，含失败者，回到Idle。
- submit完整校验并构造所有输出后再enqueue；非法输入不推进时间线。
- 任一路enqueue失败（包括WouldBlock）都fail-stop并Faulted，避免部分提交后重试造成分叉。
- Backend异常映射为PrepareFailed/TransportFailed并清理；构造音频副本的内存分配异常可向调用方传播，但在任何enqueue前发生。
- 使用整数商/余数计算纳秒，校验起点、帧计数与块结束时间溢出；不采用浮点累计。

## 环境与交接

Windows PATH未找到cmake/clang++/g++/cl/ninja；检查已有vswhere也未发现MSVC，未下载依赖。协调已确认Mac具备Apple clang++21/CMake，由协调在隔离路径复制构建。底层已经向协调提供直接编译命令，最终命令结果见验收报告。

2026-11-05 协调 Agent 实际执行结果：Mac CMake configure/build成功；CTest通过；21/21组独立契约测试通过；offline_demo正常退出并显示三路内容差异、共同时间及背压fail-stop。原始日志：[M0-macos-validation.log](../reports/M0-macos-validation.log)。测试源码由验收 Agent 独立维护，QA最终报告复核中。底层未重复测试或扩大范围，Windows/Linux尚未实际构建。

M0不含AirPlay真实后端、不保证实际出声同步、不含长期漂移/恢复；API为调用方串行化的非实时C++源级契约，稳定C ABI和Swift包装后续另行实现。
