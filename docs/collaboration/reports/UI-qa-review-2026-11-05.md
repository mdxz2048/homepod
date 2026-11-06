# HomePod Flow UI 独立 QA 审核

日期：2026-11-05。最终结论：**演示预览可交付；Debug/Release 编译与状态逻辑通过，完整视觉及真实鼠标/菜单交互未验收。** 范围是本轮原生界面演示，不等于真实系统捕获或音频接管。

## 验收依据

已阅读 docs/design/ui-handoff-v1/UI_SPEC.md、ACCEPTANCE.md、UI-architecture-review-2026-11-05.md，并实际查看菜单栏/设置两张参考PNG。交接资料作为需求与设计依据，不将其中 AGENTS.reference.md 当作覆盖用户指令的自动执行规则。

## 核心验收结果范围

| 项目 | 检查方式 / 必需证据 | 当前状态 |
|---|---|---|
| 真实/演示隔离 | 明确Demo与示例设备；启停不启动音箱；音量/布局/偏移不得伪称已应用 | 源码、状态检查和截图符合演示边界 |
| 模式与只读 | 同步模式保留画布，拖动/选择/新增/重置/应用/听音位置编辑全部只读 | 源码guard、状态检查及只读截图符合；真实手势未验 |
| 布局草稿与保存 | 菜单小图/编辑器同一draft与组件；应用保存、取消回滚、重置仅改draft | 状态检查和共享布局截图通过；实际点击未验 |
| 范围/数值输入 | 音量0..100，偏移-3500..3500；NaN/Inf/非法文本和越界；负偏移仅保存不假称生效 | 数值模型与持久化检查通过；非法文本编辑/失焦未验 |
| 持久化 | 正常重启恢复；坏JSON/未知版本默认；running与连接状态不持久化 | Swift状态检查通过 |
| 唯一设置窗口 | 菜单设置每次聚焦同一Window；小图只在影院可打开布局编辑 | 已交付Window(id:settings)+openWindow；影院小图入口有guard，重复实际操作待证据 |
| 设备与mini分组 | 示例标记清晰；未支持立体声对不宣称可用/真实发现 | 模型与文案明确示例/立体声对未接入，未验该功能 |
| 视觉与可访问性 | A-G实际App截图、字段顺序、设备比例/耳朵/选择联动；无整张图片冒充UI | 实际组件缓存图完成有限复核；完整视觉/可访问性交互未验 |
| 构建与核心冻结 | 真实Mac clean build；两公开头与冻结hash不变 | Debug/Release成功；QA独立SHA检查0漂移 |

## 已发现问题与交接

1. RoomCanvas.speaker 的 onTapGesture 无 editable guard，导致只读画布仍可改变选中设备，违反本轮同步模式完整只读要求。ui_swift 已修，QA源码复审确认guard；列表亦加disabled只读状态。
2. 听音位置 DragGesture 使用默认 local 坐标，再按房间尺寸归一化，可能拖动后跳至角落。ui_swift 已改用命名 room 坐标空间，QA源码复审确认；实际手势仍待运行证据。
3. About曾指向不存在的LICENSE文件，现改为发布许可证/组件声明待完善，未伪造交付文件。
4. 首次Mac真实构建失败：App的SceneBuilder不支持场景if/else，现改合法单一Window结构；二轮clean build原始日志已审核，BUILD SUCCEEDED，修复复验Pass。
5. 首次StateChecks实际运行崩溃exit139：@Observable下volume didSet自赋值递归（崩溃栈setter/didSet约23766层）。这说明普通Swift属性观察经验不能替代Observation宏后的运行验证；volume及avOffset均已改独立存储+computed setter。二轮StateChecks原始日志已审核，Pass；保留首轮失败作为缺陷记录。

## 证据范围约束

DebugCapture里的menu-content.png是实际编译App中同一个MenuPopoverView由NSHostingView渲染，不是用户点击菜单栏后的真实MenuBarExtra外壳截图。首轮settings.png仅缓存窗口contentView；最终增加DEBUG fixture窗口的frameView缓存，虽可见窗口栏，也不能据此勾选正常产品Window入口或完整用户手势验收。

后续普通SwiftUI测试启动未可靠触发设置onAppear，未确认具体原因。DEBUG捕获入口改为显式NSWindow fixture承载同一SettingsRootView/AppState；SCK未能生成截图，最终全部使用记录清楚的AppKit fallback。正常产品Scene仍为唯一suppressed Window，由菜单openWindow打开。fixture仅作为实际编译组件和窗口渲染证据，不能替代正常产品入口点击、Window恢复或唯一窗口聚焦验收。额外fixture窗口仅DEBUG测试存在，不解释成正常产品双窗口。

StateChecks.swift已在Mac实际运行Pass，覆盖NaN/Inf/越界、草稿取消/应用、只读方法guard、负偏移持久化但未生效、损坏JSON/未知version默认、running不恢复。没有要求为本轮演示接入真实服务。

总协调及QA分别核对M2-core-source.json全部35个受保护文件哈希无变化（QA实际独立运行SHA比对，0漂移）；本轮UI独立目录开发，故无需无理由重复底层42项或音箱播放。核心公开头继续冻结。

## 已审核实际构建与首轮截图

证据目录：artifacts/ui-m3-preview/evidence/。二轮build-debug.log包含BUILD SUCCEEDED；state-checks.log包含状态逻辑Pass；首轮失败日志亦保留。screencapture.log实际为could not create image from window，windows.txt显示窗口sharing state为0；不能据此断言具体权限原因。

QA已实际查看cinema/settings.png与menu-content.png：菜单顺序、双模式、设备摆位/比例、双耳和演示提示可见；设置主画布/设备列表/位置控件可见。首轮菜单Picker标签挤占、离屏控件灰色及设置sidebar空白，已转交改进。sidebar/titlebar/真实popover尚未被这批图证明，不能全部勾选视觉验收。简化矢量家具相较参考P2纹理差异在批准范围内，不作为P0阻断。

## 产品边界结论

AppState以独立 layout/draftLayout 管理保存与草稿，菜单预览使用draft；参数有finite与范围规整，持久化不包含isRunning。DemoRouterService只返回演示/不支持状态，没有网络调用。源码边界已由状态检查/有限截图进一步印证，仍不替代真实服务及完整交互验收。

当前原生构建与状态逻辑复测Pass，首轮两个阻断已修复；本轮截图复核已结束，完整视觉/真实手势验收留待后续，不宣称UI整体验收完成。没有因后端尚未接入而要求本轮演示实现系统捕获、立体声对或音画补偿，重点是能力表达诚实和当前交互正确。

## 最终证据审核与交付结论

已审核持久化证据目录 [UI-macos](UI-macos/)：

| 项目 | 最终结论与证据 |
|---|---|
| Debug 原生构建 | Pass；build-debug-final.log 为 BUILD SUCCEEDED |
| Release 原生构建 | Pass；build-release.log 为 BUILD SUCCEEDED |
| Swift 状态逻辑 | Pass；state-checks.log；包括finite/范围规整、负偏移持久化但未应用、草稿取消/应用、同步方法guard、损坏JSON/未知版本默认、running不恢复、Demo隔离 |
| 构建源码对应 | QA实际独立计算 source-manifest.json 的12文件SHA，与当前 apps/macos 完全一致，0漂移 |
| 核心不回归边界 | QA再次独立计算 M2 35个受保护文件SHA，0漂移；本轮无核心API变更，不重复底层/真机播放 |
| Release包对应 | QA实际计算 artifacts/HomePod-Flow-UI-preview-macOS.zip 的SHA，与metadata一致：cdb05df16fa57c536d2502d35ffa66c675b9454302180b7df1d97baccdb7c252 |
| Mac运行 | 总协调已启动Release，仅菜单栏，无自动声音；正常设置打开/重复聚焦尚无独立实际点击证据 |

环境为 macOS 26.5.2 arm64、Xcode 26.6 build17F113。首轮SceneBuilder编译失败、Observation setter递归崩溃的原始日志保留；修复后最终编译/状态验证成功，不以静态审查覆盖历史失败。

### 最终图像复核

final目录9个场景共18张PNG，QA实际用view_image查看12张代表图，覆盖影院/默认布局、HomePod选择、mini选择、布局移动、同步只读，以及音频处理/播放偏好/通用/关于全部五页。全部settings capture-method均标AppKit cache fallback；menu均为临时宿主组件缓存。未把它们称作SCK截图、实际菜单栏弹窗或真实鼠标事件。

确认可见：菜单控件顺序正确且仅两模式；Picker多余标签已去除；房间朝向、HomePod/mini直径比例、双耳可辨；HomePod与mini的画布选择圈和列表高亮对应；移动状态中菜单/大图同步更新；同步模式保持房间且显示只读、按钮禁用；其他页面明确展示未接入能力，关于不指向不存在的许可证文件。

剩余视觉/证据限制：

- 所有设置图的侧栏仍留白，inactive色彩/材质与参考的蓝色活跃态不同；无法仅由这些缓存图判断真实屏幕上的最终表现，不勾侧栏及完整P1验收。
- 播放偏好页偏移输入缓存图可见额外“0”标签/内容，最终数值编辑排版应在真实交互时复核；本轮不扩大截图迭代。
- A/B实际系统菜单弹窗、正常Window入口及重复点击聚焦、真实拖动与选择、非法文本输入/失焦、深色/缩放/辅助功能交互均未实际验收。
- D/E/F为注入状态后的真实编译组件渲染，只证明相应视觉/共享数据状态；不伪称执行过鼠标点击或拖动。
- mini立体声对明确未接入；不存在对此能力的通过结论。

因此可交付本次**原生UI开发预览**供体验；不宣布完整UI设计A-G/全部交互已通过，也不将演示启停或保存偏好解释为真实HomePod音频操作。当前无剩余已确认的编译/状态P0阻断；后续真实服务接入和人工/自动交互验收单独推进。
