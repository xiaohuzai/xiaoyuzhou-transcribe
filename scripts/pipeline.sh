#!/usr/bin/env bash
# pipeline.sh — 小宇宙链接 → 已格式化的 Part A transcript (带说话人 + 时间戳)
#
# **这是给 LLM agent 用的 skill 工具**。本脚本只跑机械部分 (ASR + 格式化),
# LLM 总结步骤由 agent 自己完成 (读 references/ai-summary-prompt.md 拿 prompt 模板)。
#
# 用法:
#   bash scripts/pipeline.sh "https://www.xiaoyuzhoufm.com/episode/xxx" \
#       [--speakers speakers/silicon101.json]
#
# 输出:
#   /tmp/xy_pipeline_<timestamp>/
#   ├── transcript_raw.json        Step 1 原始 ASR JSON
#   ├── transcript_formatted.md    Step 2 Part A (说话人 + 时间戳)  ← 主输出
#   └── transcript.md              Part A + Part B 占位
#
# 下一步 (agent 做):
#   1. 读 references/ai-summary-prompt.md 拿 prompt 模板
#   2. 拿 Part A 内容 + 元数据, 用 prompt 调 LLM 生成 Part B
#   3. 把 Part A + Part B 拼成最终 transcript.md

set -euo pipefail

# ---------- 默认配置 ----------
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- 参数解析 ----------
INPUT_URL=""
SPEAKERS_JSON=""
MAX_CHARS=300

while [[ $# -gt 0 ]]; do
    case "$1" in
        --speakers)  SPEAKERS_JSON="$2"; shift 2 ;;
        --max-chars) MAX_CHARS="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *)
            if [ -z "$INPUT_URL" ]; then
                INPUT_URL="$1"
            else
                echo "❌ 未知参数: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# ---------- 校验 ----------
if [ -z "$INPUT_URL" ]; then
    echo "❌ 缺少输入 URL" >&2
    sed -n '2,18p' "$0"
    exit 1
fi

# 默认 speakers
if [ -z "$SPEAKERS_JSON" ]; then
    SPEAKERS_JSON="$SKILL_DIR/speakers/silicon101.json"
fi

# ---------- 环境 ----------
# 加载 DASHSCOPE_API_KEY (跨 agent 兼容, 不绑定任何 agent 平台)
# 优先级: 环境变量 > ~/.config/xiaoyuzhou-transcribe/.env > ~/.hermes/.env (hermes 兼容)
if [ -z "${DASHSCOPE_API_KEY:-}" ] && [ -f "$HOME/.config/xiaoyuzhou-transcribe/.env" ]; then
    DASHSCOPE_API_KEY=$(grep -E "^DASHSCOPE_API_KEY=" "$HOME/.config/xiaoyuzhou-transcribe/.env" 2>/dev/null | head -1 | cut -d'=' -f2-)
    export DASHSCOPE_API_KEY
fi
if [ -z "${DASHSCOPE_API_KEY:-}" ] && [ -f "${HERMES_HOME:-$HOME/.hermes}/.env" ]; then
    DASHSCOPE_API_KEY=$(grep -E "^DASHSCOPE_API_KEY=" "${HERMES_HOME:-$HOME/.hermes}/.env" 2>/dev/null | head -1 | cut -d'=' -f2-)
    export DASHSCOPE_API_KEY
fi
if [ -z "${DASHSCOPE_API_KEY:-}" ]; then
    echo "❌ DASHSCOPE_API_KEY 未设置" >&2
    echo "   三个来源任选一个:" >&2
    echo "     1. 环境变量: export DASHSCOPE_API_KEY=*** ~/.bashrc)" >&2
    echo "     2. 配置文件: echo 'DASHSCOPE_API_KEY=***' > ~/.config/xiaoyuzhou-transcribe/.env" >&2
    echo "     3. Hermes 兼容: 加进 ~/.hermes/.env" >&2
    exit 1
fi

# ---------- 中间文件 ----------
TS=$(date +%Y%m%d_%H%M%S)
WORKDIR="/tmp/xy_pipeline_$TS"
mkdir -p "$WORKDIR"
echo "📁 工作目录: $WORKDIR"

RAW_JSON="$WORKDIR/transcript_raw.json"
FORMATTED_MD="$WORKDIR/transcript_formatted.md"
COMBINED_MD="$WORKDIR/transcript.md"

# ---------- Step 1: ASR 转写 ----------
echo ""
echo "🎙️  [1/2] ASR 转写 (DashScope 异步 URL 模式)..."
# 注意: 不能用 `2>&1 | tail -5`，会被 SIGPIPE 杀掉上游（set -o pipefail）
bash "$SKILL_DIR/scripts/transcribe_async.sh" "$INPUT_URL" "$RAW_JSON" > /tmp/xy_step1.log 2>&1 || true
echo "  → ASR 完成: $(wc -c < "$RAW_JSON" 2>/dev/null || echo 0) bytes, 日志: /tmp/xy_step1.log"
[ -s "$RAW_JSON" ] || { echo "❌ ASR 输出为空"; exit 1; }

# ---------- Step 2: 格式化 ----------
echo ""
echo "📝  [2/2] 格式化逐字稿 (说话人标注 + 时间戳)..."
python3 "$SKILL_DIR/scripts/format_transcript.py" \
    "$RAW_JSON" "$FORMATTED_MD" \
    --speakers "$SPEAKERS_JSON" \
    --max-chars "$MAX_CHARS" > /tmp/xy_step2.log 2>&1 || {
    echo "❌ 格式化失败：" >&2
    tail -20 /tmp/xy_step2.log >&2
    exit 1
}
echo "  → 格式化完成: $(wc -c < "$FORMATTED_MD") chars, 日志: /tmp/xy_step2.log"
[ -s "$FORMATTED_MD" ] || { echo "❌ 格式化输出为空"; exit 1; }

# ---------- 拼装 (含 Part B placeholder, 留给 agent 填) ----------
{
    echo "# 转写与小宇宙元数据"
    echo ""
    echo "**源链接**: ${INPUT_URL}  "
    echo "**处理时间**: $(date -Iseconds)  "
    echo ""
    echo "---"
    echo ""
    echo "## Part A — 带说话人标注的完整转写 (Step 1+2 机械产出)"
    echo ""
    cat "$FORMATTED_MD"
    echo ""
    echo "---"
    echo ""
    echo "## Part B — 结构化总结 (LLM 总结步骤, agent 自行生成)"
    echo ""
    echo "<!--"
    echo "  ⚠️ 这部分是占位, agent 拿到上方 Part A 后请:"
    echo "  1. 读 references/ai-summary-prompt.md 拿 prompt 模板"
    echo "  2. 按模板拼装 prompt, 调 LLM 生成 Part B"
    echo "  3. 把生成的 Part B 内容替换此占位"
    echo "  详细工作流见 SKILL.md。"
    echo "-->"
} > "$COMBINED_MD"

# ---------- 完成 ----------
echo ""
echo "🎉 机械部分完成 (Step 1+2)。"
echo ""
echo "📄 主输出 (Part A, 含说话人 + 时间戳):"
echo "   $FORMATTED_MD"
echo ""
echo "📄 待补全 transcript (Part A + Part B 占位):"
echo "   $COMBINED_MD"
echo ""
echo "📁 工作目录 (含所有中间产物):"
echo "   $WORKDIR"
echo ""
echo "下一步 (agent):"
echo "  1. 读 $FORMATTED_MD 拿 Part A 内容"
echo "  2. 读 $SKILL_DIR/references/ai-summary-prompt.md 拿 prompt 模板"
echo "  3. 按模板生成 Part B, 替换 $COMBINED_MD 的占位"
echo "  4. 把最终 transcript 粘到 Notion / Obsidian / 飞书 web / Word / 任何下游"
