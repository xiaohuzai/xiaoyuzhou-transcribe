# xiaoyuzhou-transcribe

> 小宇宙 (XiaoyuzhouFM) 播客一键转写 + AI 总结 → 本地 markdown。

把任何小宇宙播客链接变成带说话人标注的完整转写 + 主题分组结构化总结的 markdown 文件。
你自己决定 markdown 接下来去哪（粘 Notion / Obsidian / Word / 飞书 web / git 入库 / 任何下游）。

## 设计原则

skill 是**提示 + 工具**，不是完整 pipeline 脚本：

| 步骤 | 谁做 | 怎么干 |
|------|------|--------|
| Step 1: ASR 转写 | bash 工具 | `transcribe_async.sh` 调 DashScope 异步 API |
| Step 2: 格式化 | python 工具 | `format_transcript.py` 说话人 + 时间戳 + 分段 |
| Step 3: LLM 总结 | **agent (你)** | 用 `references/ai-summary-prompt.md` 拿 prompt 模板，**调用你自己的 LLM** |

**本 skill 不替你调 LLM**。任何 agent 都能用，不绑定任何 LLM 平台。

## 跨 Agent 兼容

SKILL.md 是事实标准格式——Hermes Agent / Claude Code / Cursor / Codex / Aider 都能用。

| Agent | 安装路径 / 命令 |
|-------|----------------|
| **Hermes Agent** | `hermes skills install https://raw.githubusercontent.com/xiaohuzai/xiaoyuzhou-transcribe/main/SKILL.md` |
| **Claude Code** | `git clone https://github.com/xiaohuzai/xiaoyuzhou-transcribe.git ~/.claude/skills/xiaoyuzhou-transcribe` |
| **Cursor** | `git clone https://github.com/xiaohuzai/xiaoyuzhou-transcribe.git ~/.cursor/skills/xiaoyuzhou-transcribe` |
| **OpenAI Codex** | `git clone https://github.com/xiaohuzai/xiaoyuzhou-transcribe.git ~/.codex/skills/xiaoyuzhou-transcribe` |
| **手动 (任何 agent)** | `git clone https://github.com/xiaohuzai/xiaoyuzhou-transcribe.git` — 把 SKILL.md 路径告诉你的 agent |

## 快速开始

```bash
# 1. 跑机械部分 (Step 1+2)
bash scripts/pipeline.sh "https://www.xiaoyuzhoufm.com/episode/xxx"

# 输出: /tmp/xy_pipeline_<ts>/transcript_formatted.md (Part A)

# 2. 你的 agent 读 Part A + references/ai-summary-prompt.md
# 3. agent 用自己的 LLM 生成 Part B
# 4. 拼装 Part A + Part B → transcript.md
# 5. 粘到任何 markdown 接收器 (Notion / Obsidian / Word / git / ...)
```

**端到端**: 60 分钟播客，机械部分 ~70 秒（ASR）+ <1 秒（格式化），LLM 总结看你模型速度。

## 核心特性

- **DashScope 异步 ASR** — 传音频公网 URL 给云端处理，不下载到本地、支持 8 小时长音频、不消耗 CPU
- **说话人检测** — 关键词表匹配，识别常见播客嘉宾（参考 `speakers/silicon101.json`）
- **AI 结构化总结** — 主题分组 + 章节时间线 + 关键金句 + Q&A（agent 自己的 LLM 生成）
- **跨 agent 兼容** — SKILL.md 标准格式，Hermes / Claude / Cursor / Codex / Aider 都用
- **零 lark-cli / 飞书 SDK / Notion API** — 输出是纯 markdown，agent 自己决定下游

## 依赖

**机械部分**（任何 agent 都能跑）：

```bash
# 系统
curl, jq

# Python ≥ 3.8 (format_transcript.py 仅用标准库)

# 凭据: DASHSCOPE_API_KEY
# 三种来源任选:
#   1. 环境变量
export DASHSCOPE_API_KEY="..."

#   2. 配置文件 (推荐, 跨 agent)
mkdir -p ~/.config/xiaoyuzhou-transcribe
echo "DASHSCOPE_API_KEY=..." > ~/.config/xiaoyuzhou-transcribe/.env

#   3. Hermes Agent 兼容
echo "DASHSCOPE_API_KEY=..." >> ~/.hermes/.env
# 申请: https://dashscope.console.aliyun.com/apiKey
```

**LLM 总结**（agent 自己的）— 不限制，Anthropic / OpenAI / Gemini / 本地模型都支持。

## 文档

- [SKILL.md](SKILL.md) — 完整使用文档
- [references/dashscope-async-filetrans.md](references/dashscope-async-filetrans.md) — ASR 协议
- [references/ai-summary-prompt.md](references/ai-summary-prompt.md) — 给 LLM 的 prompt 模板
- [references/speaker-detection-strategies.md](references/speaker-detection-strategies.md) — 说话人识别

## 许可

MIT
