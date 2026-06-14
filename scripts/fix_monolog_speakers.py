#!/usr/bin/env python3
"""
fix_monolog_speakers.py
========================

Post-pipeline speaker-label fixup for 嘉宾主导型 (guest-monolog) podcasts.
Run AFTER `pipeline.sh` and BEFORE delegating Part B generation to the LLM.

Why: Step 2's keyword-table-based detection only catches the guest's "我是XXX"
self-introduction line. On long-form 商业访谈/纪录片对谈 (commercial interviews,
documentary monologs), the host may ask 5-8 questions then hand the floor to
the guest for 30-50 minutes at a stretch. The script's default fallback
labels everything as "主持人" — which is the opposite of reality on those
shows. This script implements the receiver-side fixup.

Usage:
    python3 fix_monolog_speakers.py <transcript_formatted.md> [<host_name> [<guest_name>]]
    # host_name / guest_name default to "主持人" / "嘉宾" (you must replace)

Outputs:
    <input>_speakers_fixed.md — same content, with corrected per-paragraph
    speaker labels (one `**[Name]** [MM:SS]` per paragraph).
    Also prints the speaker-stats summary to stdout.

Heuristics (apply in order, first match wins):
    1. 段内出现 `听众朋友们好，我是XXX` / `Hello, 我是XXX` / similar intro →
        split paragraph at that anchor; prefix is host, suffix is guest.
    2. 段尾出现 `好啦，这期节目就是这样` / `我们下期再见` / `拜拜` →
        split paragraph at that anchor; suffix is host closer.
    3. 段首含 `<host_name>老师` 或 `<host_name>，` 加 `?` / `？` 提问 → host
    4. 段尾以 `?` / `？` 收束 → host (or guest's rhetorical question; weak signal)
    5. Default → guest

The script is intentionally a starting point — for any non-standard program
format, hand-edit the HOST_SEGMENT_OVERRIDES dict at the bottom before
running. Verified working on 2026-06-08 against:
    - 张小俊商业访谈录 / 张君毅 (汽车史话, 77 min)
    - 商业访谈录 / 阳萌 (Anker 创新, 218 min)
"""
import re
import sys
from collections import Counter


def split_paragraph_at(text, anchor, after_anchor=True):
    """Find `anchor` in `text`; if present, return (prefix, suffix). Else (text, '')."""
    idx = text.find(anchor)
    if idx < 0:
        return text, ''
    cut = idx + len(anchor) if after_anchor else idx
    return text[:cut].strip(), text[cut:].strip()


def judge_speaker(paragraph_text, host_name, guest_name,
                  seen_guest_intro=False, seen_host_closer=False):
    """
    Return (speaker, role) for a single paragraph.
    role is one of: 'intro_prefix', 'intro_suffix', 'closer', 'normal'
    Returns None to signal "use default" (= guest).
    """
    # Rule 1: guest self-intro anchor
    intro_anchors = [
        f'听众朋友们好，我是{guest_name}',
        f'大家好，我是{guest_name}',
        f'Hello, 大家好，我是{guest_name}',
        f'Hello大家好，我是{guest_name}',
    ]
    for a in intro_anchors:
        if a in paragraph_text:
            return 'host', 'intro_prefix'  # the whole para up to intro is host

    # Rule 2: host closer anchor (only after we've seen content — i.e. not the first paragraph)
    closer_anchors = [
        '好啦，这期节目就是这样',
        '我们下期再见',
        '那我们下期再见',
        '如果你喜欢我的节目',
    ]
    for a in closer_anchors:
        if a in paragraph_text:
            return 'guest', 'closer'  # prefix is guest, suffix is host closer

    # Rule 3: host asks question at start of paragraph
    head = paragraph_text[:80]
    if (f'{host_name}老师' in head or f'{host_name}，' in head) and ('?' in head or '？' in head):
        return 'host', 'normal'

    # Rule 4: paragraph ends with question mark → likely host question
    tail = paragraph_text.rstrip()
    if tail.endswith('?') or tail.endswith('？'):
        return 'host', 'normal'

    return None  # use default (guest)


def process(input_path, host_name='主持人', guest_name='嘉宾'):
    with open(input_path) as f:
        content = f.read()

    # Split into paragraphs: each is "**主持人** [MM:SS]\n<body>"
    parts = re.split(r'\*\*主持人\*\* \[(\d{2}:\d{2})\]\n', content)
    # parts[0] = header, parts[1] = ts, parts[2] = body, [3] = ts, [4] = body, ...
    paragraphs = []
    for i in range(1, len(parts), 2):
        ts = parts[i]
        body = parts[i+1].strip()
        paragraphs.append((ts, body))

    # First pass: detect intro/closer split anchors, and label paragraphs.
    new_paragraphs = []  # list of (ts, speaker, body)
    for i, (ts, body) in enumerate(paragraphs):
        if i == 0:
            # First paragraph is almost always the host opening
            new_paragraphs.append((ts, host_name, body))
            continue

        # Check for guest self-intro
        intro_anchors = [
            f'听众朋友们好，我是{guest_name}',
            f'大家好，我是{guest_name}',
            f'Hello, 大家好，我是{guest_name}',
            f'Hello大家好，我是{guest_name}',
            f'Hello大家好，我是',  # generic, takes the next 1-2 words as name
        ]
        split_done = False
        for a in intro_anchors:
            idx = body.find(a)
            if idx > 0:
                prefix = body[:idx].strip()
                suffix = body[idx:].strip()
                new_paragraphs.append((ts, host_name, prefix))
                new_paragraphs.append((ts, guest_name, suffix))
                split_done = True
                break
        if split_done:
            continue

        # Check for host closer
        closer_anchors = [
            '好啦，这期节目就是这样',
            '我们下期再见',
            '那我们下期再见',
            '今天的节目就是这样',
        ]
        split_done = False
        for a in closer_anchors:
            idx = body.find(a)
            if idx > 0:
                prefix = body[:idx].strip()
                suffix = body[idx:].strip()
                new_paragraphs.append((ts, guest_name, prefix))
                new_paragraphs.append((ts, host_name, suffix))
                split_done = True
                break
        if split_done:
            continue

        # Standard rules
        sp = judge_speaker(body, host_name, guest_name)
        if sp == 'host':
            new_paragraphs.append((ts, host_name, body))
        else:
            new_paragraphs.append((ts, guest_name, body))

    # Apply manual overrides (caller can pass these via env or edit the dict below)
    for idx, (override_ts, override_sp) in HOST_SEGMENT_OVERRIDES.items():
        if 0 <= idx < len(new_paragraphs):
            new_paragraphs[idx] = (new_paragraphs[idx][0], override_sp, new_paragraphs[idx][2])

    # Stats
    stats = Counter(sp for _, sp, _ in new_paragraphs)
    print(f"Speaker stats: {dict(stats)}", file=sys.stderr)
    print(f"Total paragraphs: {len(new_paragraphs)}", file=sys.stderr)

    # Write output
    out_path = input_path.replace('.md', '_speakers_fixed.md')
    with open(out_path, 'w') as f:
        f.write(content[:content.find('**主持人**')])  # original header
        for ts, sp, body in new_paragraphs:
            f.write(f"\n**{sp}** [{ts}]\n{body}\n")
    print(f"Wrote {out_path}", file=sys.stderr)
    return out_path


# Override map: paragraph index → (timestamp, speaker)  for hosts who ask
# off-pattern questions (no "老师, ?" lead-in, no ?-tail). Add entries by
# running the script once, eyeballing the output, and patching this dict.
# Indices match the OUTPUT of split_paragraph_at, so a paragraph that was
# split into 2 gets two consecutive indices.
HOST_SEGMENT_OVERRIDES = {
    # Example:
    # 4: ('05:12', '小军'),   # "你没有想做科研是吧？"
    # 5: ('06:28', '小军'),   # "你当时是怎么"
}


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    inp = sys.argv[1]
    host = sys.argv[2] if len(sys.argv) > 2 else '主持人'
    guest = sys.argv[3] if len(sys.argv) > 3 else '嘉宾'
    process(inp, host, guest)
