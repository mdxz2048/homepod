# T015 核心接口冻结

负责人：架构Agent，日期2026-11-05。

已交付docs/api/v1：原样bridge.h/core.hpp、manifest.json、兼容策略README。未修改live头文件或实现。App边界为C ABI v1；C++仅源码兼容；固定9符号、0..8错误码、3回调及所有权/时间/线程/fail-stop/启停语义。

旧客户端资产由root保存，QA编写只换新动态库不重编客户端的门禁；总协调已实际执行通过，dyld确认加载M2新库，旧binary SHA不变。QA额度限制使独立终审待补，不能以重编全部测试代替二进制兼容。

已向core_dev审查持续路由设计：容量预检先于读取和submit、单eventloop串行、EOF与暂空分离、尾帧精确、队列等待总超时、过期块拒绝、取消唤醒全路与有界清理。代码交付后继续审查。

架构审查记录：已读streaming.py，确认单native Engine持续submit、全路容量预检、独立有界队列、reader EOF与暂空分离、精确尾帧和播放deadline检查。已给出取消锁等待边界、reader.close异常下仍通知全组的修补建议。源码/live头SHA与快照一致；9个符号已记录。网络集成与旧binary运行结果由协调/验收落证，不能由此静态审查代替。
