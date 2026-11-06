# T003 M0 公共契约与架构审核

负责人：技术架构 Agent。日期：2026-11-05。

目标：最小可实现 C++17 核心公共契约，无 UI、无音箱播放。

交付：core/include/flow/core.hpp、CONTRACTS.md、ARCHITECTURE.md。

决定：N路通道复制、float32 interleaved、epoch+连续帧、共同未来起点、注入 Clock/Output、prepare失败释放全部已尝试输出、发送背压fail-stop。C ABI、AirPlay桥接和漂移恢复后续。

协作：公共头已通知底层和验收；双方按同一头开展实现和独立测试。架构审查及最终构建结果待补。

架构审查：已读 core/src/core.cpp 当前实现。确认全部路由先校验、Output 别名/重复 ID 拒绝、整数时间按商余数换算与溢出检查、所有路由块先构造再提交、prepare 尝试者全清理、enqueue 失败全组 Faulted，未发现公共语义阻断问题。独立测试和跨平台构建结果由验收/协调记录，不能以此代码审查替代。

当前状态：契约与实现架构审查完成；M0 构建/验收以 TASKS 和验收报告最终结果为准。
