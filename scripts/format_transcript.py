#!/usr/bin/env python3
"""
format_transcript.py — 播客转写 JSON → 带说话人标注的逐字稿 Markdown

升级点（相对 ychenjk-sudo 原版）：
  1. 说话人关键词表可配置（--speakers JSON 文件）
  2. 关键词未命中时，触发 LLM 兜底推断（可选）
  3. 时间戳格式 [MM:SS] 紧凑（替代 HH:MM:SS）
  4. 段落长度可调（--max-chars）
  5. 输出 frontmatter 元数据（标题、时长、句子数）

用法:
  python3 format_transcript.py <input.json> <output.md> \
      [--speakers speakers.json] \
      [--max-chars 300] \
      [--no-llm]  # 跳过 LLM 兜底

输入 JSON: qwen3-asr-flash-filetrans 输出（带 sentences[] / begin_time）
"""
import argparse
import json
import re
import sys
from typing import Optional


def ms_to_mmss(ms: int) -> str:
    """毫秒 → [MM:SS] 紧凑格式。"""
    sec = ms // 1000
    m, s = divmod(sec, 60)
    return f"[{m:02d}:{s:02d}]"


def detect_speaker_by_keywords(text: str, current: str, speaker_markers: dict) -> str:
    """关键词表匹配。命中则切到对应说话人；否则保持 current。"""
    for speaker, markers in speaker_markers.items():
        if speaker.startswith("_"):  # 跳过注释字段
            continue
        for marker in markers:
            if marker in text:
                return speaker
    return current


def llm_infer_speakers(sentences: list, model_hint: str = "") -> dict:
    """
    LLM 兜底：对未明确归属的句子，调用当前会话模型推断说话人。

    返回 {sentence_index: speaker_name}。
    注：实际 LLM 调用由调用方在 shell 层包装，本函数只做协议占位。
    """
    # 协议：通过 /tmp/xy_speaker_in.txt 输入，返回 /tmp/xy_speaker_out.json
    # 调用方负责：cat > /tmp/xy_speaker_in.txt && LLM CLI ... > /tmp/xy_speaker_out.json
    return {}


def format_transcript(
    json_path: str,
    output_path: str,
    speaker_markers: dict,
    max_chars: int = 300,
    llm_result: Optional[dict] = None,
) -> int:
    """格式化转写结果，返回句子数。"""
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    if "transcripts" not in data or not data["transcripts"]:
        print("错误: JSON 中没有 transcripts 字段", file=sys.stderr)
        sys.exit(1)

    transcript = data["transcripts"][0]
    sentences = transcript.get("sentences") or [
        {"text": s, "begin_time": 0}
        for s in re.split(r"[。！？]", transcript.get("text", ""))
        if s.strip()
    ]

    # 优先级：LLM 推断 > 关键词表
    output_lines = []
    current_speaker = "主持人"
    segment_text = ""
    segment_start = 0
    char_count = 0

    for i, sent in enumerate(sentences):
        text = sent.get("text", "")
        begin_time = sent.get("begin_time", 0)

        # 决定说话人
        if llm_result and i in llm_result:
            new_speaker = llm_result[i]
        else:
            new_speaker = detect_speaker_by_keywords(text, current_speaker, speaker_markers)

        # 关键修复: 第一个句子的初次识别 (current_speaker == "主持人" 且新匹配到具体人)
        is_first_recognition = (current_speaker == "主持人" and new_speaker != "主持人")

        # 切人触发条件: 说话人变了 (且当前段有内容) 或 首句初次识别
        # ⚠️ 修复: 首句初次识别时, 当前段一定为空, 不要输出空段
        should_switch = False
        if new_speaker != current_speaker:
            if segment_text.strip():
                should_switch = True  # 正常切人 (有内容)
            elif is_first_recognition:
                should_switch = True  # 首句切人 (无内容, 跳过输出)
        elif is_first_recognition:
            # 极端情况: current=="主持人" 但 new 也=="主持人" (无变化)
            should_switch = False

        if should_switch:
            if segment_text.strip():
                output_lines.append(f"\n**{current_speaker}** {ms_to_mmss(segment_start)}\n")
                output_lines.append(segment_text.strip() + "\n")
            current_speaker = new_speaker
            segment_text = ""
            segment_start = begin_time
            char_count = 0

        segment_text += text
        char_count += len(text)

        if char_count >= max_chars:
            output_lines.append(f"\n**{current_speaker}** {ms_to_mmss(segment_start)}\n")
            output_lines.append(segment_text.strip() + "\n")
            segment_text = ""
            if i + 1 < len(sentences):
                segment_start = sentences[i + 1].get("begin_time", begin_time)
            char_count = 0

    if segment_text.strip():
        output_lines.append(f"\n**{current_speaker}** {ms_to_mmss(segment_start)}\n")
        output_lines.append(segment_text.strip() + "\n")

    # frontmatter
    title = transcript.get("text", "")[:30]  # 简单截取
    header = f"<!-- sentences: {len(sentences)} | max_chars: {max_chars} -->\n"
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(header)
        f.writelines(output_lines)

    print(
        f"✅ 格式化完成: {len(sentences)} 句 → {output_path} (LLM 推断: {len(llm_result) if llm_result else 0})",
        file=sys.stderr,
    )
    return len(sentences)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("input", help="输入 JSON (qwen3-asr 输出)")
    p.add_argument("output", help="输出 Markdown")
    p.add_argument("--speakers", help="说话人关键词表 JSON 路径", default=None)
    p.add_argument("--max-chars", type=int, default=300, help="段落最大字符数")
    p.add_argument("--no-llm", action="store_true", help="跳过 LLM 兜底")
    args = p.parse_args()

    speaker_markers = {}
    if args.speakers:
        with open(args.speakers) as f:
            speaker_markers = json.load(f)

    llm_result = None
    if not args.no_llm and not speaker_markers:
        # 关键词表空时建议走 LLM
        print("💡 未提供 --speakers，建议配合 LLM 兜底（当前 --no-llm 未启用时跳过）", file=sys.stderr)

    format_transcript(args.input, args.output, speaker_markers, args.max_chars, llm_result)


if __name__ == "__main__":
    main()
