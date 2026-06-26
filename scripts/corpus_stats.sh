#!/usr/bin/env bash
# corpus_stats.sh — 中文学术语料摸底工具
# ---------------------------------------------------------------------------
# 一次性把一个文件夹里的论文（PDF/DOCX/TXT）转成文本，并给出作者分档与文风
# 分析所需的"地形图"：每篇的字符数（识别扫描件）、首若干行（作者/单位/摘要块）、
# 各级标题（找签名结构模板）、以及一份连接词/骨架词的跨篇频次表。
#
# 用法:
#   bash corpus_stats.sh <语料文件夹> [选项]
#
# 选项:
#   --out <目录>        文本输出目录 (默认: <语料文件夹>/_corpus_txt)
#   --head <N>          每篇 dump 前 N 行 (默认 25; 作者块、摘要常在此)
#   --phrases "a,b,c"   自定义词频清单(逗号分隔)，覆盖内置中文社科默认表
#   --freq-only         跳过逐篇摘要，只输出词频表
#   --no-extract        不再抽取(沿用已存在的 .txt)，直接统计
#
# 依赖: pdftotext (poppler) 为主; markitdown 兜底(docx/无文本层时)
# 例:
#   bash corpus_stats.sh "./导师论文"
#   bash corpus_stats.sh "./papers" --phrases "首先,其次,综上,因此,路径依赖"
# ---------------------------------------------------------------------------
set -uo pipefail

CORPUS="${1:-}"
if [[ -z "$CORPUS" || ! -d "$CORPUS" ]]; then
  echo "用法: bash corpus_stats.sh <语料文件夹> [--out 目录] [--head N] [--phrases \"a,b\"] [--freq-only] [--no-extract]" >&2
  exit 1
fi
shift

OUT="$CORPUS/_corpus_txt"
HEAD_N=25
FREQ_ONLY=0
DO_EXTRACT=1
PHRASES_RAW=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)       OUT="$2"; shift 2;;
    --head)      HEAD_N="$2"; shift 2;;
    --phrases)   PHRASES_RAW="$2"; shift 2;;
    --freq-only) FREQ_ONLY=1; shift;;
    --no-extract)DO_EXTRACT=0; shift;;
    *) echo "未知选项: $1" >&2; exit 1;;
  esac
done

mkdir -p "$OUT"

# 内置默认词频清单：中文人文社科常见的连接词 + 结构骨架词。
# 想换学科/作者时用 --phrases 覆盖即可。
DEFAULT_PHRASES="首先,其次,再次,复次,最后,其一,其二,其三,具体而言,在此意义上,这意味着,由此可,从而,因此,综上,值得注意,一方面,另一方面,不仅,尽管,然而,是指,的角度,的视角,基于,取向,路径依赖,身份认同,谱系,源流,脉络,张力,范式,建构,机制,逻辑,维度,意涵,意义评析"
if [[ -n "$PHRASES_RAW" ]]; then PHRASES="$PHRASES_RAW"; else PHRASES="$DEFAULT_PHRASES"; fi

have() { command -v "$1" >/dev/null 2>&1; }

extract_one() {
  # $1 源文件  $2 目标 txt
  local src="$1" dst="$2" ext="${1##*.}"
  ext="$(echo "$ext" | tr 'A-Z' 'a-z')"
  case "$ext" in
    pdf)
      if have pdftotext; then pdftotext "$src" "$dst" 2>/dev/null; fi
      # 无文本层(扫描件)→ markitdown 兜底(可能含 OCR，视安装而定)
      if [[ ! -s "$dst" || $(wc -m < "$dst" 2>/dev/null) -lt 50 ]] && have markitdown; then
        markitdown "$src" > "$dst" 2>/dev/null || true
      fi
      ;;
    docx|doc|pptx|html|htm)
      if have markitdown; then markitdown "$src" > "$dst" 2>/dev/null
      elif have pdftotext && [[ "$ext" == html* ]]; then cp "$src" "$dst"; fi
      ;;
    txt|md) cp "$src" "$dst";;
    *) return 1;;
  esac
}

# Unicode 感知去空白：把所有空白(含 U+3000 全角空格、断行)删掉，得到单行连续文本。
# 关键：绝不用 `tr -d` 删多字节空格——tr 逐字节操作，会损坏相邻 CJK 字符的 UTF-8 编码。
flatten() {  # 读 stdin，输出去空白后的单行
  if have perl; then perl -CSD -pe 's/\s+//g'
  elif have python3; then python3 -c 'import sys,re;sys.stdout.write(re.sub(r"\s+","",sys.stdin.read()))'
  else tr -d '\n\r\t '   # 最后退路：仅删 ASCII 空白，全角空格可能残留
  fi
}

# 收集语料文件(顶层；如需递归把 -maxdepth 去掉)
shopt -s nullglob nocaseglob
mapfile -t SRCS < <(find "$CORPUS" -maxdepth 1 -type f \( -iname '*.pdf' -o -iname '*.docx' -o -iname '*.doc' -o -iname '*.txt' -o -iname '*.md' \) | sort)
shopt -u nocaseglob

if [[ ${#SRCS[@]} -eq 0 ]]; then echo "未在 $CORPUS 找到 PDF/DOCX/TXT 文件。" >&2; exit 1; fi

# ---------- 抽取 + 逐篇摘要 ----------
if [[ $FREQ_ONLY -eq 0 ]]; then
  echo "############################################################"
  echo "# 逐篇摘要 (字符数 / 扫描件标记 / 首${HEAD_N}行 / 各级标题)"
  echo "############################################################"
fi

TXTS=()   # 只收真正的篇目 txt，避免把合并临时文件算进词频
for src in "${SRCS[@]}"; do
  base="$(basename "$src")"; base="${base%.*}"
  dst="$OUT/$base.txt"
  if [[ $DO_EXTRACT -eq 1 ]]; then extract_one "$src" "$dst"; fi
  [[ -f "$dst" ]] || { echo "（抽取失败，跳过）$base"; continue; }
  TXTS+=("$dst")

  if [[ $FREQ_ONLY -eq 1 ]]; then continue; fi

  chars=$(wc -m < "$dst" 2>/dev/null | tr -d ' ')
  flag=""
  if [[ "${chars:-0}" -lt 800 ]]; then flag="  ⚠️可能是扫描件(无文本层)→如非必要可跳过"; fi
  echo ""
  echo "========== $base =========="
  echo "字符数: ${chars:-0}${flag}"
  echo "---- 首${HEAD_N}行(作者/单位/摘要块) ----"
  sed -n "1,${HEAD_N}p" "$dst"
  echo "---- 各级标题(一、/（一）/1.) ----"
  grep -nE "^[　 ]*[一二三四五六七八九十]+[、．]|^[　 ]*（[一二三四五六七八九十]+）|^[　 ]*[0-9]+[.、][^0-9]" "$dst" | head -30
done

# ---------- 跨篇词频(按频次降序) ----------
echo ""
echo "############################################################"
echo "# 跨篇词频 (按频次降序；越高越是作者的'骨架词/口头禅'，刻意复用)"
echo "############################################################"
FLAT="$OUT/_ALL_FLAT.txt"
cat "${TXTS[@]}" 2>/dev/null | flatten > "$FLAT"
IFS=',' read -ra PARR <<< "$PHRASES"
{
  for p in "${PARR[@]}"; do
    p_trim="$(echo "$p" | sed 's/^ *//; s/ *$//')"
    [[ -z "$p_trim" ]] && continue
    n=$(grep -o "$p_trim" "$FLAT" 2>/dev/null | wc -l | tr -d ' ')
    printf "%s\t%s\n" "$n" "$p_trim"
  done
} | sort -k1 -nr | awk -F'\t' 'BEGIN{printf "%-14s %s\n%-14s %s\n","词/短语","频次","------","----"}{printf "%-14s %s\n",$2,$1}'

echo ""
echo "（文本已存于: $OUT ；可对高权重篇目用 sed -n '起,止p' 精读关键段。）"
