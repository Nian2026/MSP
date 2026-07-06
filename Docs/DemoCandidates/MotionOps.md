# MotionOps

Status: Candidate Demo Concept

## 一句话

MotionOps 是一个 iOS 动作复盘工作台候选 demo：用户用 iPhone 拍摄健身、舞蹈、投篮、高尔夫挥杆等动作，App 把视频、人体姿态点、关键帧和时间轴写入 MSP workspace，Agent 通过受控命令分析动作、标注问题、生成训练建议和复盘包。

它的目标是展示 MSP 如何承载真实世界的动作数据和时间序列，而不是再做一个文档整理或聊天建议产品。

## 为什么不是 Readex 能做掉的事

Readex 可以处理视频文件、字幕、截图和文字材料，但 MotionOps 的核心不是“读一个视频然后总结”。它依赖 App 专有能力：相机录制、AVFoundation、Vision 人体姿态识别、CoreMotion 传感器数据、Apple Watch 数据、关键帧抽取、时间轴对齐和可视化标注。

这些能力属于垂直 App 的运行时，而不是通用文档工作区。MSP 在这里展示的是：开发者可以把动作识别、姿态提取、帧标注、训练计划生成等能力包装成 agent-safe commands，让 Agent 像操作文件和命令一样操作动作数据。

## 惊艳体验

用户打开 App，拍一段 10 秒投篮视频。拍摄结束后，workspace 里出现：

```text
/raw/shot.mov
/pose/landmarks.json
/timeline/segments.json
/frames/keyframe-001.png
/frames/keyframe-002.png
/metrics/angles.json
```

然后用户直接问：

```text
为什么我出手不稳定？帮我标出来，并给我一个练习计划。
```

Agent 不是只给泛泛建议，而是通过 MSP 执行受控命令：

```text
motion import-video /raw/shot.mov
pose extract /raw/shot.mov
motion segment --action shot
pose compare --reference basketball-shot
frame annotate --issues
drill generate --focus release-stability
export review
```

最后 workspace 里生成：

```text
/annotations/release-angle.svg
/annotations/body-alignment.svg
/reports/review.md
/drills/practice-plan.md
/export/motion-review.zip
```

用户能看到 Agent 的判断依据：关键帧、姿态点、角度指标、时间轴片段和标注文件，而不是只看到一段无法验证的建议。

## MSP 展示点

- 数据皆文件：视频、姿态点、关键帧、角度指标、时间轴片段、训练计划都落在 workspace 里。
- 操作皆命令：录制、导入、姿态提取、动作分段、标注、对比、导出都被抽象成命令。
- 权限皆规则：相机、相册、传感器、Apple Watch 数据和文件导出都由 App 明确授权。
- 执行皆证据：Agent 为什么指出某个动作问题，可以追踪到帧、姿态数据、指标和命令输出。

## MVP 用户流程

1. 用户创建一次动作复盘。
2. App 引导用户拍摄或导入一段短视频。
3. App 抽取关键帧和姿态数据，写入 MSP workspace。
4. 用户通过聊天提出动作分析需求。
5. Agent 调用 MotionOps commands 分析动作并生成标注。
6. 用户右滑查看 workspace 文件和中间产物。
7. 用户导出复盘包或训练计划。

## Workspace 形状

```text
/
  raw/
    shot.mov
  pose/
    landmarks.json
  timeline/
    segments.json
  frames/
    keyframe-001.png
    keyframe-002.png
  metrics/
    angles.json
  annotations/
    release-angle.svg
    body-alignment.svg
  reports/
    review.md
  drills/
    practice-plan.md
  export/
    motion-review.zip
```

## 命令形状

```text
motion import-video <path>
pose extract <video>
motion segment [options]
pose compare [options]
frame annotate [options]
drill generate [options]
export review
```

第一版可以先用固定视频 fixture 和离线生成的姿态数据跑通 agent loop，不必一开始完成实时动作识别。重点是证明动作数据可以进入 MSP workspace，并由 Agent 通过命令操作。

## 非目标

- 不做泛健身聊天助手。
- 不做普通训练计划或打卡 App。
- 不做 Readex 式视频总结。
- 不追求第一版达到专业运动医学或教练级准确度。
- 不把真实系统 shell 或任意视频处理二进制直接暴露给 Agent。

## 评估标准

- 普通用户能立刻理解“拍一下，让 AI 复盘我的动作”的价值。
- 开发者能看懂如何把 Vision、AVFoundation、CoreMotion 等 App 能力包装成 MSP command。
- 右滑 workspace 后，用户能看到视频、姿态数据、关键帧、指标、标注和报告。
- 工具调用 timeline 能解释 Agent 的每一步动作分析依据。
- 整个流程不依赖真实系统 shell，仍然像一个可操作的 Linux 风格工作区。
