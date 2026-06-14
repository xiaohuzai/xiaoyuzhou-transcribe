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

### 1. 系统工具

```bash
# Linux/macOS
which curl jq python3   # 都应该输出路径

# 缺哪个装哪个 (Debian/Ubuntu)
sudo apt install curl jq python3
```

### 2. ASR 凭据：Qwen ASR (DashScope)

**Step 1 ASR 转写使用阿里云 DashScope 的 Qwen3-ASR 服务**（`qwen3-asr-flash-filetrans` 模型）。

**为什么用 Qwen3-ASR**:
- ✅ 中文识别准确率领先（实测 60 分钟播客错误率 < 2%）
- ✅ 支持说话人情感/语言自动检测
- ✅ 异步 URL 模式，**不下载音频到本地**、不消耗 CPU
- ✅ 8 小时长音频支持
- ✅ 价格便宜：60 分钟音频约 ¥0.5-1

**怎么申请 API key**:
1. 打开 https://dashscope.console.aliyun.com/apiKey
2. 用阿里云账号登录（**没账号先注册，支付宝/淘宝/钉钉账号直接登**）
3. 开通 DashScope 服务（首次会要实名+免费额度，**新人有 100 万 token 免费**）
4. 点"创建 API-KEY" → 复制 `sk-xxx` 开头的 key

**怎么把 key 给 skill 用**（三种方式任选）:

```bash
# 方式 1: 环境变量 (临时)
export DASHSCOPE_API_KEY="sk-xxx"  # 你的 key
bash scripts/pipeline.sh "https://www.xiaoyuzhoufm.com/episode/xxx"

# 方式 2: 配置文件 (推荐, 跨 agent)
mkdir -p ~/.config/xiaoyuzhou-transcribe
echo 'DASHSCOPE_API_KEY=sk-xxx' > ~/.config/xiaoyuzhou-transcribe/.env
chmod 600 ~/.config/xiaoyuzhou-transcribe/.env  # 防止别人读

# 方式 3: 加到 shell rc (永久)
echo 'export DASHSCOPE_API_KEY="sk-xxx"' >> ~/.bashrc
source ~/.bashrc

# 方式 4: Hermes Agent 用户 (兼容旧版)
echo 'DASHSCOPE_API_KEY=sk-xxx' >> ~/.hermes/.env
```

**优先级**: 环境变量 > `~/.config/xiaoyuzhou-transcribe/.env` > `~/.hermes/.env`

**安全注意**: 
- ⚠️ API key 跟密码一样, **不要 commit 到 git, 不要贴 issue, 不要发聊天群**
- ⚠️ 配置文件权限设为 `chmod 600` (仅自己能读)
- ⚠️ 不用了从 [DashScope 控制台](https://dashscope.console.aliyun.com/apiKey) 删掉

### 3. LLM (Step 3 总结用, agent 自带)

**本 skill 不替你调 LLM**——你用什么 agent 就用什么 agent 的 LLM:
- Claude Code → Claude (Sonnet / Opus)
- Cursor → GPT-4o / Claude (看订阅)
- Codex → GPT-4
- Hermes Agent → 你配置的 provider (Anthropic / OpenAI / Gemini / 本地)

**没要求, 没限制, 不要钱**——已经在用 agent 就不用额外花钱。

### 4. (可选) 本地 ASR 兜底

**只在 Step 1 URL 失效**时需要 (小宇宙 mediaKey 过期、URL 私网鉴权等):
- 安装: `pip install qwen3-asr-toolkit`
- 文档: https://github.com/QwenLM/Qwen3-ASR-Toolkit
- 默认情况下**不需要**——只装系统工具 + 申请 DashScope key 就能用

## 快速开始 (3 分钟跑通)

```bash
# 1. 申请 DashScope API key (5 分钟)
#    打开 https://dashscope.console.aliyun.com/apiKey → 复制 sk-xxx

# 2. 配置 key (任选一种)
export DASHSCOPE_API_KEY="sk-xxx"

# 3. 跑!
git clone https://github.com/xiaohuzai/xiaoyuzhou-transcribe.git
cd xiaoyuzhou-transcribe
bash scripts/pipeline.sh "https://www.xiaoyuzhoufm.com/episode/xxx"

# 4. 看输出
cat /tmp/xy_pipeline_*/transcript_formatted.md

# 5. 让你的 agent 读 Part A + references/ai-summary-prompt.md
#    让 agent 自己调 LLM 生成 Part B
#    拼装 Part A + Part B → 最终 transcript.md
```

- [SKILL.md](SKILL.md) — 完整使用文档
- [references/dashscope-async-filetrans.md](references/dashscope-async-filetrans.md) — ASR 协议
- [references/ai-summary-prompt.md](references/ai-summary-prompt.md) — 给 LLM 的 prompt 模板
- [references/speaker-detection-strategies.md](references/speaker-detection-strategies.md) — 说话人识别

## 许可

MIT
