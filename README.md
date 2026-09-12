# MPV-Bilibili

基于 [uosc](https://github.com/tomasklaen/uosc) **5.13.0** 的改进的 mpv 项目

在保留 uosc 原有交互逻辑的基础上，做了大量代码精简与重构

> ⚠️ 本项目是对 uosc 的**二次修改版**，并非官方发行。uosc 原版请前往 [tomasklaen/uosc](https://github.com/tomasklaen/uosc)

---

## 主要特性

### 中文界面

- 仿照哔哩哔哩播放视频样式
- 控件、tooltip、菜单项已汉化

### 弹幕集成

- 修改自 [uosc_danmaku](https://github.com/Tony15/MPV-uosc_danmaku) ，可在 控制栏 中直接打开**弹幕设置面板**
- 主面板提供 4 个常用滑块：
  - 显示区域（0.25 ~ 1.0）
  - 不透明度（0.15 ~ 1.0）
  - 弹幕字号（50% ~ 170%）
  - 弹幕速度（极快 / 较快 / 适中 / 较慢 / 极慢）
- 高级面板提供：
  - 弹幕字体选择（下拉列表，支持 5 项滚动）
  - 粗体开关
  - 描边类型：重墨 / 描边 / 45°投影
  - 一键恢复默认设置
- 支持 `alt+l` 快速加载 .xml / .json 弹幕文件

### 选集面板

- 列表展示当前播放列表中的所有集数。
- **打开时自动滚动到当前正在播放的集数**，并让当前集居中显示
- 当前集有蓝色播放图标 + "播放"标签高亮

### 播放模式面板

一个开关面板，集中管理：
- 自动切集
- 单集循环
- 乱序播放

### 倍速面板

- 预设 6 档常见倍速：`2.0x / 1.5x / 1.25x / 1.0x / 0.75x / 0.5x`
- 当前倍速高亮显示。
- 悬停按钮时直接显示当前倍速值

### 音轨 / 字幕面板

- 列表显示全部音轨 / 字幕轨
- 每行右侧显示语言、编解码、声道数、采样率、默认 / 强制等属性
- 底部提供"加载音轨" / "加载字幕"入口
- 当前活动轨道高亮，带播放图标

### 音量 / 静音 / 全屏提示

- 音量变化时，屏幕中央出现白色圆角提示框，显示图标 + 百分比。
- 静音开关时，出现黑底白字提示。
- 进入全屏时，顶部弹出"若要退出全屏，请按 Esc"提示。
- 鼠标移动到屏幕顶部，出现退出全屏的圆形按钮。

### 其他

- 缩略图悬停预览（依赖 [thumb_engine](https://github.com/po5/thumbfast)）。
- 支持 YouTube heatmap（章节热度图）。
- 支持章节分段显示（openings / endings / ads）


## License

本项目基于 [uosc](https://github.com/tomasklaen/uosc)（MIT License）修改而来

原版 uosc 版权归 tomasklaen 所有，本项目的修改部分同样以 MIT License 发布


## 致谢

[uosc](https://github.com/tomasklaen/uosc) — 原版界面脚本

[uosc_danmaku](https://github.com/Tony15/MPV-uosc_danmaku) — 弹幕脚本

thumb_engine参考两部分，[【1】](https://github.com/po5/thumbfast)、[【2】](https://github.com/hooke007/mpv_PlayKit) — 缩略图引擎

所有 mpv 社区贡献者