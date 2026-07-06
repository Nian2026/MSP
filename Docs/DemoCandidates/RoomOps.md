# RoomOps

Status: Candidate Demo Concept

## 一句话

RoomOps 是一个 iOS 空间工作台候选 demo：用户用 iPhone 捕获真实房间，Agent 通过 Model Shell Protocol 在一个受控 workspace 里读取空间数据、执行空间命令、生成布局方案和导出包。

它的目标不是再做一个文档整理产品，而是展示 MSP 如何把 App 专有设备能力暴露成 agent-safe commands。

## 为什么不是 Readex 能做掉的事

Readex 已经能很好地处理文档、文件、资料整理和写作工作流。证据包、活动包、素材包这类 demo，本质上仍然是把材料放进 workspace，再让 Agent 读文件、写文件、生成结果，容易被 Readex 覆盖。

RoomOps 的边界不同：它依赖 iPhone 的真实设备能力，例如相机、AR、LiDAR、RoomPlan、传感器、权限弹窗和实时扫描 UI。Readex 可以处理扫描后的文件，但它不应该负责真实空间采集、测量和设备能力编排本身。

RoomOps 证明的是：MSP 不只是知识工作区的 shell，也可以成为任何垂直 App 暴露专有能力的安全命令层。

## 惊艳体验

用户打开 App，对房间扫一圈。扫描结束后，workspace 里出现一组真实空间文件：

```text
/captures/room.usdz
/captures/photos/
/floorplan.json
/measurements.json
/objects.json
/issues.md
```

然后用户直接问：

```text
这间房能不能放下一张 1.5 米床、一张书桌和一个衣柜？给我两个布局方案。
```

Agent 不是只在聊天里猜，而是通过 MSP 执行受控命令：

```text
room inspect
object list
measure distance wall-a wall-b
layout propose --bed 150x200 --desk 120x60 --wardrobe 80x55
floorplan annotate
export package
```

最后 workspace 里生成：

```text
/reports/fit-check.md
/layouts/layout-a.svg
/layouts/layout-b.svg
/shopping-list.md
/move-steps.md
/export/roomops-package.zip
```

用户右滑打开 workspace，可以看到 Agent 真的基于空间数据创建了文件、执行了命令、留下了证据，而不是只给出一段建议。

## MSP 展示点

- 数据皆文件：空间扫描、照片、测量、物体列表、布局方案都落在 workspace 里。
- 操作皆命令：扫描、测量、识别、布局、标注、导出都被抽象成命令。
- 权限皆规则：相机、RoomPlan、文件写入、导出等能力由 App 明确授权。
- 执行皆证据：Agent 为什么说“放得下”或“放不下”，可以追踪到测量文件、命令调用和输出结果。

## MVP 用户流程

1. 用户创建一个房间项目。
2. App 引导用户扫描空间。
3. 扫描结果写入 MSP workspace。
4. 用户通过聊天提出布局或测量需求。
5. Agent 调用 RoomOps commands 读取空间数据并生成方案。
6. 用户右滑查看 workspace 文件。
7. 用户导出布局方案包。

## Workspace 形状

```text
/
  captures/
    room.usdz
    photos/
  floorplan.json
  measurements.json
  objects.json
  layouts/
    layout-a.svg
    layout-b.svg
  reports/
    fit-check.md
  shopping-list.md
  move-steps.md
  export/
    roomops-package.zip
```

## 命令形状

```text
room scan
room inspect
object list
measure distance <from> <to>
layout propose [options]
floorplan annotate [options]
export package
```

这些命令不需要一开始全部实现。第一版可以先用静态 fixture 或一次真实扫描数据跑通完整 agent loop，重点证明 App 专有能力如何进入 MSP 命令层。

## 非目标

- 不做 Readex 式文档整理。
- 不做普通 to-do list 或计划拆解。
- 不做泛聊天助手。
- 不追求第一版成为完整室内设计软件。
- 不把外部真实 shell 暴露给 Agent。

## 评估标准

- 普通用户能在 30 秒内理解它和普通聊天 App 的区别。
- 开发者能看懂如何把 App 专有能力包装成 MSP command。
- 右滑 workspace 后，用户能看到真实输入、中间文件、最终结果。
- 工具调用 timeline 能解释 Agent 的每一步判断依据。
- 整个流程不依赖真实系统 shell，仍然像一个可操作的 Linux 风格工作区。
