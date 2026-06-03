#!/usr/bin/env bash
# pipeline.sh — 小宇宙链接 → 本地 markdown (Part A + Part B)
#
# 端到端跑 Step 1-3:
#   Step 1: DashScope 异步 ASR (transcribe_async.sh)
#   Step 2: 说话人标注 + 时间戳格式化 (format_transcript.py)
#   Step 3: LLM 生成 Part B 结构化总结 (summarize_transcript.sh)
#
# **通用 skill** — 输出本地 markdown (Part A + Part B)，用户自行决定下游用途
# （粘 Notion / Obsidian / 飞书 web / Word / git 入库 / 任何 markdown 接收器）。
#
# 用法:
#   bash pipeline.sh <xiaoyuzhou_url> \
#       --title "<episode_title>" \
#       [--date 2026-06-01] \
#       [--speakers speakers/silicon101.json] \
#       [--dry-run]
#
# 依赖:
#   - DASHSCOPE_API_KEY 在 ~/.hermes/.env (或 ${HERMES_HOME}/.env)
#   - transcribe_async.sh / format_transcript.py / summarize_transcript.sh

set -euo pipefail

# ---------- 默认配置 ----------
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- 参数解析 ----------
INPUT_URL=""
EPISODE_TITLE=""
EPISODE_DATE="$(date +%Y-%m-%d)"
SPEAKERS_JSON=""
DRY_RUN=false
MAX_CHARS=300
EPISODE_NUM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)        EPISODE_TITLE="$2"; shift 2 ;;
        --date)         EPISODE_DATE="$2"; shift 2 ;;
        --episode-num)  EPISODE_NUM="$2"; shift 2 ;;
        --speakers)     SPEAKERS_JSON="$2"; shift 2 ;;
        --max-chars)    MAX_CHARS="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '2,28p' "$0"
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
    sed -n '2,20p' "$0"
    exit 1
fi

# 默认标题
if [ -z "$EPISODE_TITLE" ]; then
    EPISODE_TITLE="未命名节目_$(date +%H%M%S)"
fi

# 默认 speakers
if [ -z "$SPEAKERS_JSON" ]; then
    SPEAKERS_JSON="$SKILL_DIR/speakers/silicon101.json"
fi

# ---------- 环境 ----------
# 加载 DASHSCOPE_API_KEY (兼容自定义 HERMES_HOME)
[ -f "${HERMES_HOME:-$HOME/.hermes}/.env" ] && source "${HERMES_HOME:-$HOME/.hermes}/.env" 2>/dev/null || true
if [ -z "${DASHSCOPE_API_KEY:-}" ]; then
    echo "❌ DASHSCOPE_API_KEY 未设置（检查 ~/.hermes/.env）" >&2
    exit 1
fi

# ---------- 中间文件 ----------
TS=$(date +%Y%m%d_%H%M%S)
WORKDIR="/tmp/xy_pipeline_$TS"
mkdir -p "$WORKDIR"
echo "📁 工作目录: $WORKDIR"

RAW_JSON="$WORKDIR/transcript_raw.json"
FORMATTED_MD="$WORKDIR/transcript_formatted.md"
FINAL_MD="$WORKDIR/transcript_final.md"
COMBINED_MD="$WORKDIR/transcript.md"  # Part A + Part B 拼接

# ---------- Step 1: ASR 转写 ----------
echo ""
echo "🎙️  [1/3] ASR 转写 (异步 URL 模式)..."
# 注意: 不能用 `2>&1 | tail -5`，会被 SIGPIPE 杀掉上游（set -o pipefail）
bash "$SKILL_DIR/scripts/transcribe_async.sh" "$INPUT_URL" "$RAW_JSON" > /tmp/xy_step1.log 2>&1 || true
echo "  → ASR 完成: $(wc -c < "$RAW_JSON" 2>/dev/null || echo 0) bytes, 日志: /tmp/xy_step1.log"
[ -s "$RAW_JSON" ] || { echo "❌ ASR 输出为空"; exit 1; }

# ---------- Step 2: 格式化 ----------
echo ""
echo "📝  [2/3] 格式化逐字稿 (说话人标注 + 时间戳)..."
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

# ---------- Step 3: LLM 总结 ----------
echo ""
echo "🤖  [3/3] LLM 总结..."
bash "$SKILL_DIR/scripts/summarize_transcript.sh" \
    "$FORMATTED_MD" "$FINAL_MD" > /tmp/xy_step3.log 2>&1 || {
    echo "❌ LLM 总结失败：" >&2
    tail -20 /tmp/xy_step3.log >&2
    exit 1
}
echo "  → LLM 总结完成: $(wc -c < "$FINAL_MD") chars, 日志: /tmp/xy_step3.log"
[ -s "$FINAL_MD" ] || { echo "❌ LLM 总结输出为空"; exit 1; }

# ---------- 拼接 Part A + Part B ----------
{
    echo "# ${EPISODE_TITLE}"
    echo ""
    echo "**源链接**: ${INPUT_URL}  "
    echo "**处理时间**: $(date -Iseconds)  "
    echo ""
    echo "---"
    echo ""
    echo "## Part A — 带说话人标注的完整转写"
    echo ""
    cat "$FORMATTED_MD"
    echo ""
    echo "---"
    echo ""
    # Part B 来自 summarize_transcript.sh（已经包含 "## Part B — 结构化总结" 头）
    cat "$FINAL_MD"
} > "$COMBINED_MD"

# Safety Net: 拼接后验证
if ! grep -q "## Part A" "$COMBINED_MD"; then
    echo "❌ LOCAL_MD_MISSING_PART_A — 拼接输出缺 Part A 标记" >&2
    exit 1
fi
if ! grep -q "## Part B" "$COMBINED_MD"; then
    echo "❌ LOCAL_MD_MISSING_PART_B — 拼接输出缺 Part B 标记" >&2
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "⏭️  --dry-run 模式 (跳过最终输出)"
    echo "   中间产物保留在 $WORKDIR"
    echo "   最终拼装: $COMBINED_MD"
    exit 0
fi

# ---------- 完成 ----------
echo ""
echo "🎉 全部完成！"
echo ""
echo "📄 拼装好的 transcript (Part A + Part B):"
echo "   $COMBINED_MD"
echo ""
echo "📁 工作目录 (含所有中间产物):"
echo "   $WORKDIR"
echo "   ├── transcript_raw.json     (Step 1 原始 ASR 输出)"
echo "   ├── transcript_formatted.md (Step 2 说话人 + 时间戳)"
echo "   ├── transcript_final.md     (Step 3 LLM 总结)"
echo "   └── transcript.md           (Part A + Part B 拼装, 上述文件)"
echo ""
echo "下一步（用户自行决定）:"
echo "  • 自己看: cat $COMBINED_MD | less"
echo "  • 粘到 Notion / Obsidian / 飞书 web / Word / git 入库 / 任何 markdown 接收器"
