# LLM 总结阶段：语义/性能踩坑清单

> 改 `summarize_transcript.sh` 或 LLM 总结逻辑前**必读**。本 skill 跑 60 分钟播客踩过的所有坑。

## 坑 1：架构错误 — 让 LLM 重写 Part A 不可用

**症状**：64KB transcript 输入，LLM 跑了 8+ 分钟没完成，最后被 SIGPIPE 截断。

**原因**：

- 完整 Part A = 完整逐字稿 = ~50K tokens 重写
- 完整 Part B = 5-8 主题分组 + Q&A + 金句 = ~3-5K tokens
- LLM 输出速度 ~60-80ms/token → 50K+5K tokens = **55K × 70ms = 3850s = 64 分钟**

**正确做法**（两步而非一步）：

1. `format_transcript.py`（纯 Python）已经做了说话人标注 + 时间戳 + 分段 → 这就是 Part A
2. `summarize_transcript.sh` 让 LLM **只输出 Part B**，~2K tokens → ~2 分钟

如果必须 LLM 修正 Part A 错误，在格式化输出上**编辑**而非重写。

## 坑 2：必须禁用 thinking

**症状**：LLM 调了 121s，usage 显示 `output_tokens=4000`（撞顶），但响应是 0 字符。退出码 0，HTTP 200。响应 `content[]` 里 `type=thinking` 占满预算，`type=text` 0 字符。

**原因**：部分 LLM 默认开启 extended thinking，把 max_tokens 全部分给 thinking 块。

**修复**：在 Anthropic 协议 payload 里加 `'thinking': {'type': 'disabled'}`：

```python
payload = {
    'model': 'MiniMax-M3',
    'max_tokens': 4000,
    'thinking': {'type': 'disabled'},   # ← 关键
    'messages': [{'role': 'user', 'content': content}],
}
```

> 切到其他 LLM 时也要先确认是否默认开 thinking，**payload 必须显式禁掉**。

## 坑 3：surrogate pair 字符导致 UnicodeEncodeError

**症状**：`hermes chat -q "..."` 报 `UnicodeEncodeError: 'utf-8' codec can't encode character '\udce5' ...`

**原因**：transcript 里有 UTF-16 surrogate 范围的字符（ASR 错识别产生），CLI 参数解析不宽容。

**修复**：用 Python 清洗 stdin bytes：

```bash
INPUT_CONTENT=$(cat "$INPUT_MD" | head -c 50000 | python3 <<'PYEOF'
import sys
data = sys.stdin.buffer.read().decode('utf-8', errors='replace')
data = data.encode('utf-8', errors='replace').decode('utf-8', errors='replace')
print(data, end='')
PYEOF
)
```

## 坑 4：必须包 `timeout`

**症状**：LLM 调用有时会无限等（API 排队、网络卡、模型思考中），脚本挂着永远不退。

**修复**：

```bash
curl --max-time 300 ...
```

## 坑 5：终端中文标题被 token 替换

**症状**：`--title "硅谷101｜CES 2026 特别篇"` 直接写命令行，"谷" 字被某层 token 替换成 `_val`。

**修复**：用 shell 变量包一层：

```bash
TITLE='硅谷101｜CES 2026 特别篇：人形机器人肉身困局'
lark-cli wiki +node-create --title "$TITLE" --obj-type docx
```

## 端到端实测数据

| 输入大小 | 实际耗时 | 产出 | 评价 |
|---|---|---|---|
| 808 chars (4 句 mock) | 66s | 完整 Part A+Part B (5.4K chars) | 完美 |
| 30K chars (真实 28 分钟切片) | **71s** | 完整 Part B (7.7K chars) | 完美 |
| 64K chars (整期 60 分钟) | 8+ 分钟 (SIGPIPE 中断) | 只完成 Part A 开头 | 不可用（**旧架构，已废止**） |

**结论**：**两步架构（format = Part A, LLM = Part B only）+ 禁用 thinking** 的组合下，真实 60 分钟播客 ~75s 完成 Part B 总结，飞书落地 ~2.5 分钟端到端跑通。
