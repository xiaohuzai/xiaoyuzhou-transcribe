# xiaoyuzhou-transcribe

> 小宇宙 (XiaoyuzhouFM) 播客一键转写 + AI 总结 → 本地 markdown。

把任何小宇宙播客链接变成带说话人标注的完整转写 + 主题分组结构化总结的 markdown 文件。
你自己决定 markdown 接下来去哪（粘 Notion / Obsidian / Word / 飞书 web / git 入库 / 任何下游）。

## 快速开始

```bash
bash scripts/pipeline.sh "https://www.xiaoyuzhoufm.com/episode/xxx" \
    --title "标题"
```

输出: `/tmp/xy_pipeline_<timestamp>/transcript.md` (Part A 完整转写 + Part B 主题总结)

## 安装 (Hermes Agent)

```bash
hermes skills install https://raw.githubusercontent.com/xiaohuzai/xiaoyuzhou-transcribe/main/SKILL.md
```

或 clone 整个 repo：

```bash
git clone https://github.com/xiaohuzai/xiaoyuzhou-transcribe.git
cd xiaoyuzhou-transcribe
hermes skills install ./SKILL.md
```

## 核心特性

- **DashScope 异步 ASR** — 传音频公网 URL 给云端处理，不下载到本地、支持 8 小时长音频、不消耗 CPU
- **说话人检测** — 关键词表匹配 + LLM 推断，识别常见播客嘉宾
- **AI 结构化总结** — 主题分组 + 章节时间线 + 关键金句 + Q&A
- **端到端 ~2.5 分钟** — 60 分钟播客实测

## 依赖

- `curl`, `jq`
- Python ≥ 3.8
- DashScope API key（[申请](https://dashscope.console.aliyun.com/apiKey)）— 设置在 `~/.hermes/.env`

**不需要 lark-cli / 飞书 SDK / Notion API** — 输出是纯 markdown。

## 文档

- [SKILL.md](SKILL.md) — 完整使用文档
- [references/dashscope-async-filetrans.md](references/dashscope-async-filetrans.md) — ASR 协议
- [references/ai-summary-prompt.md](references/ai-summary-prompt.md) — LLM prompt 模板
- [references/speaker-detection-strategies.md](references/speaker-detection-strategies.md) — 说话人识别
- [references/llm-summarize-pitfalls.md](references/llm-summarize-pitfalls.md) — 常见坑

## 许可

MIT
