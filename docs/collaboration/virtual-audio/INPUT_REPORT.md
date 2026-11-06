# VirtualAudioInput 第一切片实现报告

日期：2026-11-06。对应 CONTRACT v0.2。状态：总协调已在目标Mac完成第二候选编译与13项静默测试，全部通过。首轮编译的system object常量Int32转换及Swift overlay未导入ZeroTimeStampPeriod两项错误已修正；保留首轮失败与第二轮通过的区别。

第二候选使用极小C target包含公开SDK `CoreAudio/AudioServerPlugIn.h`，向Swift提供ZeroTimeStampPeriod selector；不猜fourcc，也不引入驱动实例、音频IO或私有API。

QA审查后第二候选同时修正journal读取上限：逐段读取至最多16385 bytes，超过16384立即拒绝，而非整个文件先读入才检查。新增超限回归，总计13个测试。跨进程CAS竞态明确保留为helper前硬门槛，现阶段无真实writer/helper不自动接管。

独占新路径：`platforms/macos/VirtualAudioInput/` 与本文。未改现有App、ProcessTapCapture、冻结核心；未SSH、安装、播放、改输出、改权限或提交Git。

## 已实现

- 独立 Swift6/macOS14.2 package，library + `virtual-audio-input` CLI。无参数和`--help`只打印帮助，只有明确`--discover`才读取HAL。没有CLI写属性、切换设备或采集入口。
- InputDescriptor/实际格式/FL-FR及扩展声道标签/provenance/源时钟元数据/permission/calibration模型。设备格式与解码器报告格式分开；发现结果总是tapVerified=false、permission unknown、calibration uncalibrated，不冒充ready。
- `HALVirtualDeviceBackend.discover()`以精确UID查找，校验model、alive、无输入/单输出流、方向/active/起始通道、physical+virtual Float32 interleaved ASBD、44.1/48k离散能力、stereo布局、固定buffer512/period16384、device/safety0、双scope stream latency和hfla同值、revision前后稳定。缺设备typed driver_unavailable，查询失败保留OSStatus。
- 显式hfla写API：运行/范围/expected revision前检，driver最终busy检查，回读frames/rate/revision确认；幂等写不要求revision递增。外部并发修改造成确认不匹配时返回latency_revision_changed。写成功仍不是calibrated。
- 可注入OutputSelectionBackend/LeaseJournal、纯恢复policy、文件journal原子替换及owner+generation匹配。恢复意图写在默认输出修改前；只恢复仍由本lease占有的虚拟输出；手动用户输出优先；原设备丢失需经过验证的fallback；失败保留journal。
- 接管默认缺省 `recoveryHelperAvailable=false`，无helper时直接拒绝；真实capture start固定返回capture_path_unverified。**没有提供真实HAL默认输出setter或恢复helper，故当前没有正式自动接管能力。** 仅fake backend测试注入helper已可用场景。

## 已执行的静默验证

总协调返回的目标Mac实测结果（非本agent远程操作）：

| 检查 | 实际结果 | 能证明的范围 |
|---|---|---|
| 第二候选 `swift test` | 退出0，13 XCTest通过，0失败 | 可构建与注入模型/控制/恢复策略测试；不证明真实默认输出恢复 |
| CLI默认无参数help | 退出0 | 默认不开始发现/采集/修改 |
| CLI显式 `--discover` | 退出1，`driver_unavailable` | 驱动未安装时诚实报告不可用，不伪造ready |

目标Mac为Xcode26.6环境，原始日志由总协调统一收集。现有HomePod Flow App未重签、未更改权限身份。驱动尚未安装，故本轮未证明真实驱动能力查询、通知、latency写入、Tap PCM或音画补偿。

复现命令（本报告更新不再次执行）：

总协调在Mac执行：

```sh
cd platforms/macos/VirtualAudioInput
swift test
swift run virtual-audio-input --help
swift run virtual-audio-input --discover
```

`--discover`在驱动未安装时退出1并报告driver_unavailable是本次实际结果，不记作设备发现成功。help、unit tests均不接触真实音频IO；tests只对临时journal文件操作，不设置系统音频。测试覆盖格式拒绝、未验证状态、busy/stale/out-of-range无写入、driver竞争/外部revision、缺helper门禁、journal先于接管、失败journal不接管、用户覆盖、旧owner隔离、恢复无目标、显式fallback、跨实例journal恢复及超限有界读取。

## 明确未实现/未测

- 未证明该output-only驱动可被device/stream Tap读取，更未取得真实PCM或验证源时间戳含义。没有创建新PCM IPC协议，现有HPCM v1未变。
- 无真实音频start/read/stop数据面；后续门槛是非零左右独立输入和时基语义，不能仅把采集接口名补齐就宣称可用。
- 尚无属性变化监听器、独立崩溃恢复helper、跨进程lease互斥锁、用户切走后又切回的连续观察和正式输出切换实现。当前可注入controller用于状态/顺序验证；不能用于正式自动接管。
- 文件journal是原子替换，不声称已具备断电fsync/跨进程一致性；正式helper前需补互斥、耐久提交、generation交接和对符号链接/路径所有权的审查。
- hfla不存在原子compare-and-set协议，客户端只能写前/后确认；driver拒绝busy，外部写竞争以revision mismatch检出，不承诺防所有同值竞争。
- no installation、签名、TCC、sleep/wake、浏览器采用、声学延迟/同步或多声道实机验收。

只有上述门槛逐项通过，才允许接入正式App自动入口；目前正常菜单与已授权App不重签、不被此原型改变。
