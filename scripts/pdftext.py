#!/usr/bin/env python3
"""totta が書き出した PDF のテキスト層(透明テキスト)を、正しい読み順で取り出す。

- コンテンツストリームの描画順(= Vision OCR の認識順、左ページ→右ページ)で読む。
  pdfminer の extract_text() はレイアウト解析で見開きの左右の行を交互に混ぜ、
  PDFKit の page.string は(2026-08-16 以前の書き出しで)段落内の行順を入れ替えるため、
  どちらも見開き PDF には向かない。
- 埋め込み CID フォント(Adobe-Japan1)は pdfminer 同梱の CMap で Unicode に戻す
  (totta の PDF には ToUnicode が無いので pypdf 単体では文字化けする)。
- 見開き 1 ページは、行の x 位置でページ中央より左/右に分けて出す。

依存: pypdf, pdfminer.six  (pip install pypdf pdfminer.six)
使い方: scripts/pdftext.py FILE.pdf [FILE2.pdf ...] [--pages 1-3,7] [--no-split] [--out DIR]
  --pages    1 始まりのページ範囲。省略時は全ページ
  --no-split 左右に分けず描画順のまま出す(分割済み PDF 向け)
  --out DIR  標準出力ではなく DIR/<pdf名>.txt に書く
"""
import argparse
import io
import logging
import os
import sys

from pdfminer.cmapdb import CMapDB
from pypdf import PdfReader
from pypdf.generic import ByteStringObject, ContentStream, TextStringObject

logging.getLogger("pypdf").setLevel(logging.ERROR)
AJ1 = CMapDB.get_unicode_map("Adobe-Japan1", vertical=False).cid2unichr


def font_decoders(page):
    """フォント名 → bytes を文字列にするデコーダ"""
    decoders = {}
    res = page.get("/Resources") if "/Resources" in page else None
    fonts = res.get("/Font", {}) if res else {}
    for name, f in (fonts.items() if fonts else []):
        f = f.get_object()
        if f.get("/Subtype") == "/Type0":
            df = f["/DescendantFonts"][0].get_object()
            csi = df.get("/CIDSystemInfo", {})
            ordering = str(csi.get("/Ordering", ""))
            if ordering == "Japan1":
                decoders[name] = lambda b: "".join(AJ1.get((b[i] << 8) | b[i + 1], "�") for i in range(0, len(b) - 1, 2))
            else:  # 想定外の CID 体系はそのまま 2 バイト値を出す
                decoders[name] = lambda b: "".join(chr((b[i] << 8) | b[i + 1]) for i in range(0, len(b) - 1, 2))
        else:  # Helvetica など 1 バイトフォント(数字・英字)
            decoders[name] = lambda b: b.decode("latin1")
    return decoders


def page_lines(reader, page):
    """[(x, y, text)] を描画順で返す。同じベースライン上の連続する断片(フォント切替)は結合する。"""
    dec = font_decoders(page)
    cs = ContentStream(page.get_contents(), reader)
    lines, cur, pos, font = [], None, None, None
    for ops, op in cs.operations:
        if op == b"cm":
            pos = (float(ops[4]), float(ops[5]))
        elif op == b"Tf":
            font = ops[0]
        elif op == b"BT":
            cur = ""
        elif op in (b"Tj", b"TJ"):
            parts = [ops[0]] if op == b"Tj" else [x for x in ops[0] if isinstance(x, (bytes, ByteStringObject, TextStringObject))]
            d = dec.get(font, lambda b: b.decode("latin1", "replace"))
            for s in parts:
                b = s.original_bytes if hasattr(s, "original_bytes") else bytes(s)
                cur = (cur or "") + d(b)
        elif op == b"ET":
            if cur:
                if lines and pos and lines[-1][0] is not None and abs(lines[-1][1] - pos[1]) < 3 and pos[0] >= lines[-1][0]:
                    x, y, t = lines[-1]
                    lines[-1] = (x, y, t + cur)
                else:
                    lines.append((pos[0] if pos else None, pos[1] if pos else 0.0, cur))
            cur = None
    return lines


def parse_pages(spec, n):
    if not spec:
        return list(range(n))
    out = []
    for part in spec.split(","):
        if "-" in part:
            a, b = part.split("-")
            out.extend(range(int(a) - 1, min(int(b), n)))
        else:
            out.append(int(part) - 1)
    return [p for p in out if 0 <= p < n]


def extract(path, pages_spec=None, split=True):
    r = PdfReader(path)
    chunks = []
    for i in parse_pages(pages_spec, len(r.pages)):
        p = r.pages[i]
        w = float(p.mediabox.width)
        ls = page_lines(r, p)
        chunks.append(f"\n===== [p.{i + 1}] =====")
        if split and w > float(p.mediabox.height):  # 横長 = 見開き
            left = [t for (x, y, t) in ls if x is not None and x < w / 2]
            right = [t for (x, y, t) in ls if x is None or x >= w / 2]
            if left:
                chunks.append("--- 左ページ ---\n" + "\n".join(left))
            if right:
                chunks.append("--- 右ページ ---\n" + "\n".join(right))
        else:
            chunks.append("\n".join(t for (_, _, t) in ls))
    return "\n".join(chunks) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pdfs", nargs="+")
    ap.add_argument("--pages")
    ap.add_argument("--no-split", action="store_true")
    ap.add_argument("--out")
    a = ap.parse_args()
    for path in a.pdfs:
        text = extract(path, a.pages, split=not a.no_split)
        if a.out:
            os.makedirs(a.out, exist_ok=True)
            dst = os.path.join(a.out, os.path.splitext(os.path.basename(path))[0] + ".txt")
            with open(dst, "w") as f:
                f.write(text)
            print(f"{dst}: {len(text)} chars", file=sys.stderr)
        else:
            sys.stdout.write(text)


if __name__ == "__main__":
    main()
