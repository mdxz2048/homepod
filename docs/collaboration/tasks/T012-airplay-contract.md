# T012 M1 AirPlay 桥接契约

负责人：架构Agent；日期2026-11-05。

交付：新增core/include/flow/bridge.h，补充CONTRACTS/ARCHITECTURE；M0头不变。

已与core_dev/qa/root对齐：C ABI+ctypes真正经过native路由；宿主注入mono时钟；首音频RTP=latency，core播放origin减latency才是发送origin；defer sync并等待共同barrier；late整组拒绝；big-endian PCM；完成padding后清理；不宣称声学验证。

状态：公共契约已交付，待实现审查与离线/真机证据。

已新增并交付 adapters/airplay_pyatv/timing.py（经core_dev确认独占），包含latency扣除、冻结NTP映射、与pyatv一致的ntp2ts截断、ready/release截止检查。Windows本地公式smoke通过；独立测试由QA维护。

已审bridge.cpp、bindings/python/flow_core.py、render.py和source.py：native路由输出确实复制到AudioSource；回调所有权和有限批次边界符合窄切片。完整sender时序与失败清理待文件交付后审核。

完整session.py已审：RAOP全部到齐后重新真实native渲染和选时；冻结anchor、扣除latency、defer同步、共享release检查符合契约；网络任务结束后恢复patch。提出两项修补：完成时验证尾padding达到latency；清理取消任务时设置有限超时，避免RTSP teardown挂死。最终是否落实及运行结果由底层/验收记录。
