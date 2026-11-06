# T004：M0 独立核心验收

负责人：验收 Agent。状态：Verified（M0 离线核心通过，已审核真实构建日志及源码清单）。日期：2026-11-05。

输入：PRODUCT.md CORE-001..006、core/include/flow/core.hpp v0.1 M0 契约、架构 Agent 的 fail-stop 语义。

写入范围：tests/、ACCEPTANCE.md、本任务、reports/。不修改实现、公共头文件、根构建或任务总表。发现契约失败先通知 core_dev/architect，由 owner 修复后独立复测。

交付：21 组 C++17 无依赖离线行为测试；3 项 Python 原型保护检查；验收基线及报告。构建集成通过 tests/CMakeLists.txt，链接 flow::core，由总协调在现有 Mac 工具链执行。

完成标准：核心构建/执行证据返回并审核、原型保护通过、失败项完成修复或明确记为 Fail、真实声学和其他未执行项如实标记 Not Tested。禁止未授权音箱播放、远程安装依赖或修改 Mac 配置。

命令：

```powershell
.venv/Scripts/python.exe tests/verify_prototype.py
```

```sh
cmake -S . -B build/m0 -DFLOW_BUILD_TESTS=ON
cmake --build build/m0
ctest --test-dir build/m0 --output-on-failure
./build/m0/tests/flow_core_contract_tests
```

无 CMake 的独立编译入口：

```sh
clang++ -std=c++17 -Icore/include core/src/core.cpp tests/core_contract_tests.cpp -o /tmp/flow-core-contract-tests
/tmp/flow-core-contract-tests
```
