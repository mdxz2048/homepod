# 独立影院处理库：Mac 原生补验

日期：2026-11-06。范围：已有processing库源码的Mac原生编译/离线行为及Python ctypes绑定，不包含实际音箱或产品影院集成。

将当前processing源码与tests/processing_checks.cpp、processing_binding_checks.py单独传入Mac staged source，执行Release配置、构建、CTest及FLOW_PROCESSING_LIBRARY指向实际libflow_processing.dylib的Python检查，退出码均0。

- CTest：processing_behavior 1/1通过（内部sync/矩阵/增益/校验等行为组；检查使用显式异常，不因Release NDEBUG失效）。
- Python：test_cinema_matrix_routes、test_preflight_reject_does_not_consume、test_ramp_and_block_invariance、test_safe_default_and_close，4/4通过，无native跳过。

原始构建/测试日志和本轮C/C++/CMake/检查源码SHA清单：T021-macos/processing-evidence.zip。未改变冻结核心35文件，未安装/重签App、未采集/出声、未更改默认输出。

结论仅为独立库可在Mac构建并通过这些行为检查。产品实际播放仍是同L/R同步分发，影院模式尚未接入；不能把库检查提升为已完成影院效果或原生5.1。
