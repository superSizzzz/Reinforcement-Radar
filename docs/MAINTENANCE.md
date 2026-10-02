# 维护指南

## 最重要的前提：特征码是版本锁

本 mod 用 **9 条 RVA 特征码**校验 `game.dll` 的原生代码，确认固定偏移仍然指向原来的东西。游戏一更新，这些特征码极可能失配。

**失效方式是安静的**：面板隐藏，日志写明哪几条失败、差在第几字节。不会用错数据画出一个骗人的倒计时。

```
# VERIFY FAILED: 3 of 9 guards failed: #2 rva 0x8f4f83 differs at byte 12
                (found 8b4c24 expected 8b5424) | #7 rva 0x12f1daa unreadable | ...
```

## 特征码无法离线校验

`game.dll` 的**代码段在文件里是压缩的**——首个节名为空，9 条签名在文件中全部找不到。只有运行时才展开。

因此：

- **构建期无法验证**：对文件比对必然失败
- **沙箱无法验证**：沙箱用源码里的 hex 构造假内存，属于循环验证，必然通过
- **只能靠游戏运行时**：日志里的 `VERIFY` 段是唯一的真相

这条限制解释了一个真实事故：特征码手抄时漏掉一个 hex 字符，语法检查、构建校验、沙箱测试**全部通过**，只有实机日志报了错。`scripts/gen_signatures.py` 的存在就是为此——从参考实现机械复制，人手不碰那 1KB 的 hex。

## 游戏更新后的重新适配

1. **取新特征码**：从参考实现（`automaton_reinforcement_cd`）的最新版本取得 rva/hex
2. **重新生成**：`python -B scripts/gen_signatures.py`（会逐条报告 keep / FIX / NEW）
3. **更新 PE 指纹**：读新 `game.dll` 的 `TimeDateStamp` 与 `SizeOfImage`，写入 `src/reinforcement.lua` 的 `PROFILE.game_dll`，以及 `scripts/archive.py` 的 `GAME_DLL_TIMESTAMP` / `GAME_DLL_IMAGE_SIZE`

```bash
python -B scripts/build.py --skip-game-check   # 指纹未更新时先跳过校验构建
```

4. **实机验证**：部署后看日志的 `VERIFY` 段是否为 `9 / 9`

## 日志怎么读

`%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\ReinforcementRadar.log`

**正常启动**：

```
# VERIFY OK
#   game.dll base    = 140727409246208
#   pe timestamp    = 1790161983
#   pe image_size   = 74727424
#   signatures ok   = 9 / 9
# HUD layout: screen=2560x1334 scale=1.235 panel=212x49 at 2317,724
```

**没有日志文件** → mod 根本没被加载。检查 Bingus Shared Loader 的日志里有没有这一行：

```
mods/hd2mods/reinforcement_radar: loaded
```

如果没有，多半是打包问题（入口被编译、资源名哈希不匹配），而不是代码问题。

**状态块**只在状态变化时立即记录，稳态每 5 秒一条心跳。关键是 `TRANSITION` 行：

```
status=COOLDOWN   seconds=189   raw_remaining=179.918503   rate=0.953408
derived=ceil(179.918503/0.953408)=189
```

`derived` 行是刻意打印的，让秒数算式可以直接核验。

## 一个反复出现的教训

开发过程中，有三类问题都表现为"看起来对但实际错"，值得记下：

**为让测试通过而改生产代码。** 沙箱失败时怀疑了被测代码而非测试替身，把正确的 `tonumber(ffi.cast('uintptr_t', h))` 改成了 `pcall(tonumber, h)`，引入了真实故障。**测试替身不可信时，该怀疑测试。**

**坐标系假设未经验证。** y 轴方向靠推理得出了相反结论，靠实机截图才发现。

**静默失效。** 这个 mod 系统的失败模式是"悄悄消失"而非"报错"——入口编译、声明格式偏差、哈希不匹配，结果都是 mod 默默不加载。所以排查永远从日志里有没有自己那一行开始。
