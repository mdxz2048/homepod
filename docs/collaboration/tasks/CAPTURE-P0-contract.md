# CAPTURE-P0：Process Tap 平台库与有限probe

日期：2026-11-05。依赖／权威契约：[PROCESS_TAP_PLAN.md](../PROCESS_TAP_PLAN.md)。本任务是设计交付，不表示已经录制或采集成功。

范围：独立Mac平台库、显式1..10秒录制probe、fake backend生命周期／错误清理测试。原生hostTime/sampleTime及格式保留；回调只预分配复制，后台标准PCM化；真实立体声如实报告；不改变系统输出／静音／音量，不捕获自己或发送worker。

禁止：改核心v1和M2保护35文件、自动录音／播放、立即把WAV worker改live、伪称5.1或同步通过。

交付检查：Mac构建、fake失败注入与资源账本、默认无录制动作；总协调另行实际启动授权与有限录制，记录格式／时钟／帧／非静音及cleanup证据。下一live桥接独立立项。
