# HomePod Spatial — Agent 高保真 UI 交付包 v1.0

**唯一批准的视觉基准**：`references/00_APPROVED_FULL_REFERENCE.png`。左侧是菜单栏弹窗，右侧是由「设置」打开的**独立原生窗口**，其默认页为「空间布局」。

## 给编码 Agent 的入口

1. 先读 `AGENTS.md`，按 `UI_SPEC.md` 实现。
2. 始终同时打开 `references/00_APPROVED_FULL_REFERENCE.png` 与裁切参照。**不能用之前对话里的其他效果图替代**。
3. 在现有 SwiftUI macOS 工程中实现；不要擅自重做品牌、布局、命名或功能。
4. 用 `ACCEPTANCE.md` 验收，实际截图与参考对比；未达标时继续修改。
5. 如无真实 HomePod/音频后端，先完成 **Mock UI**，明示模拟状态，绝不能以模拟连接充当真实连接。

## 文件

- `references/00_APPROVED_FULL_REFERENCE.png` — 原始最终批准效果图
- `references/01_MENUBAR_REFERENCE.png` — 菜单栏局部参考
- `references/02_SETTINGS_LAYOUT_REFERENCE.png` — 设置／空间布局窗口局部参考
- `AGENTS.md` — 可直接给 Agent 的执行要求
- `UI_SPEC.md` — 组件、布局、状态和视觉约束
- `ACCEPTANCE.md` — 实现与截图验收清单

**注意**：这些是 AI 生成的效果图，既不是 SwiftUI 可直接使用的源码，也不是经过像素精确标注的设计文件。背景、光效、设备图像有可能不符合真实 macOS 布局。应保持结构、内容和比例高度一致，并优先使用真实 SwiftUI 控件；不能承诺 100% 像素一致。
