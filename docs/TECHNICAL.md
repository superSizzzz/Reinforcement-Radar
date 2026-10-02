# 技术说明

## 架构

```
src/read_api.lua       只读内存层
src/reinforcement.lua  PE 校验 + 特征码校验 + 冷却状态机
src/hud.lua            自建 Stingray screen GUI
src/install.lua        入口：守卫、日志、update 钩子、采样节流
src/diag.lua           诊断模块（game.dll 查找链）
```

`install.lua` 把每一帧包进 `pcall`，并把 `update` 的返回值原样转发。任何一个模块出错都只会隐藏面板并记录，不会传到游戏主循环。

## 构建

构建产物是**双资源**归档：

| 资源 | 内容 | 为什么 |
| --- | --- | --- |
| `mods/hd2mods/reinforcement_radar` | 纯文本，一行声明 + require 转发 | 加载器靠扫描资源体前 256 字节的 `-- HD2-Addon:` 注释发现 addon；**编译会剥掉注释**，入口一旦被编译，mod 会静默消失（不是报错） |
| `mods/hd2mods/reinforcement_radar_impl` | 编译后的字节码 | 实际实现 |

```bash
python -B scripts/build.py           # 读取版（含 HUD）
python -B scripts/build.py --diag    # 诊断版
python -B scripts/gen_signatures.py  # 从参考实现重新生成特征码表
```

构建期会执行 readback 校验：把归档重新读出来，确认入口真以声明开头、实现真是字节码。这类"静默失效"必须由构建拒绝。

## 只读保证

构建期执行副作用 API 黑名单——源码里出现 `WriteProcessMemory`、`VirtualProtect`、`VirtualAlloc`、`VirtualFree`、`CreateRemoteThread`、`LoadLibrary`、`CreateProcess`、`Network.`、`RPC.` 任意一个即拒绝构建。

读取层只声明四个 API：`GetModuleHandleA`、`GetCurrentProcess`、`ReadProcessMemory`、`GetTickCount64`。

## 坐标系

Stingray screen GUI 的 **y 轴从屏幕底部向上**，x 轴从左向右。这个非对称性必须记住：

```lua
-- "距顶部 42%" 的实际算法
local y = screen_h * (1 - LAYOUT.below_objectives) - panel_h
```

减去 `panel_h` 是因为 y 指向面板的**下边缘**。

这个结论来自实机截图：初期版本按"y 从顶部"计算，x 轴位置完全正确（右边距 1.2% 分毫不差），但面板被画到了屏幕右下角。

## 字体

固定使用 `core/performance_hud/debug`——这是 mod 层可用的字体，所有已知的 HD2 Lua mod 都用它。

**不要在正式版本里做字体探测。** 曾有一版为了寻找更圆润的字体，在启动时用候选字体名逐个创建临时文本对象（屏幕外、随即销毁）来判定可用性，**结果是游戏崩溃**。探测属于一次性诊断行为，应当放进诊断构建按需运行，绝不能放在每次启动都执行的路径上。

另外记一笔：`Application.can_get('font', name)` 不覆盖字体资源类型，实测只用它查到过一个字体——据此得出"游戏只有一个字体"是错误结论，接口本身就不适用。

## 状态机

状态由原生共享冷却推出，字段与判定沿用已验证的参考实现：

```
m + 0xad0  float   归一化冷却比例（同步给客户端）
m + 0x94   float   原生剩余秒数（仅权威端）
m + 0xa0   u32     待处理增援队列长度
m + 0xc4 + i*0x104 队列项类型（0 = 普通增援）
pace + 0x934  u32  阻塞计数
pace + 0x924  float 冷却速率
```

判定顺序：任务实例缺席 → `UNAVAILABLE`；队列有普通请求 → `PENDING`；有阻塞或速率为 0 → `PAUSED`；`raw > 0` → `COOLDOWN`；否则 `READY`。非权威端只能读到归一化比例，无法给出秒数。

冷却在增援进行期间**被冻结**（`PAUSED`，`raw` 卡住不动），这就是它在那个阶段隐藏的原因。

## rate 的语义未查明

`seconds = ceil(raw_remaining / rate)` 中的 `rate` 是缩放系数，观测到过 0.9、0.9534、0.9635 等值，随条件变化，成因未确认。

HUD 直接使用游戏算好的 `seconds`，**不自行换算**，因此 `rate` 的具体语义不影响显示正确性。
