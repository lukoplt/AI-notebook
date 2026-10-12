#!/usr/bin/env python3
"""Deterministic synthetic mixed folder for the extraction-concurrency benchmark.

`ExtractionConcurrencyBenchmarkTests` (Swift and C#, opt-in with
AINOTEBOOK_CPU_BENCH=1) extract this folder at several worker counts; both
platforms read the same bytes. Stdlib only: OOXML parts through `zipfile`, a
hand-written text PDF, RFC 5322 mail and plain text, in multilingual prose
(cs/sk/en/de) so language detection and chunking do real work.

Usage: gen_cpu_corpus.py OUT_DIR [--files N]   (default 400 files)
The mix mirrors a real document folder: 30 % pdf, 25 % docx, 20 % xlsx,
20 % eml, 5 % txt. Re-running with the same arguments writes identical bytes;
an existing OUT_DIR/.corpus marker with the same arguments is left as is.
"""

import argparse
import random
import zipfile
from pathlib import Path

WORDS = {
    "cs": "smlouva faktura dodavatel odběratel termín plnění příloha cena celkem objednávka zakázka projekt rozpočet "
          "schůzka zápis vedení společnost oddělení zaměstnanec mzda dovolená převod účet platba splatnost záloha "
          "dokument kontrola revize návrh schválení podpis ředitel jednatel".split(),
    "sk": "zmluva faktúra dodávateľ odberateľ termín plnenia príloha cena spolu objednávka zákazka projekt rozpočet "
          "stretnutie zápisnica vedenie spoločnosť oddelenie zamestnanec mzda dovolenka prevod účet platba splatnosť "
          "záloha dokument kontrola revízia návrh schválenie podpis riaditeľ konateľ".split(),
    "en": "contract invoice supplier customer deadline delivery appendix price total order project budget meeting "
          "minutes management company department employee salary holiday transfer account payment due deposit "
          "document review revision proposal approval signature director board".split(),
    "de": "Vertrag Rechnung Lieferant Kunde Frist Lieferung Anlage Preis gesamt Bestellung Auftrag Projekt Budget "
          "Besprechung Protokoll Leitung Gesellschaft Abteilung Mitarbeiter Gehalt Urlaub Überweisung Konto Zahlung "
          "Fälligkeit Anzahlung Dokument Prüfung Revision Vorschlag Genehmigung Unterschrift Direktor".split(),
}
LANGS = sorted(WORDS)
MIX = [("pdf", 30), ("docx", 25), ("xlsx", 20), ("eml", 20), ("txt", 5)]


def sentence(rng: random.Random, lang: str) -> str:
    words = [rng.choice(WORDS[lang]) for _ in range(rng.randint(8, 18))]
    words[0] = words[0][:1].upper() + words[0][1:]
    return " ".join(words) + rng.choice([".", ".", ".", "?", ";"])


def paragraphs(rng: random.Random, lang: str, count: int) -> list:
    return [" ".join(sentence(rng, lang) for _ in range(rng.randint(3, 7))) for _ in range(count)]


def xml_escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def write_zip(path: Path, parts: list) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in parts:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)


RELS = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/'
        'package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/'
        'relationships/officeDocument" Target="{target}"/></Relationships>')
TYPES = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/'
         '2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships'
         '+xml"/><Default Extension="xml" ContentType="application/xml"/>{overrides}</Types>')


def docx(path: Path, rng: random.Random, lang: str) -> None:
    body = "".join(f"<w:p><w:r><w:t xml:space=\"preserve\">{xml_escape(p)}</w:t></w:r></w:p>"
                   for p in paragraphs(rng, lang, rng.randint(40, 220)))
    document = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats'
                f'.org/wordprocessingml/2006/main"><w:body>{body}</w:body></w:document>')
    override = ('<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.'
                'wordprocessingml.document.main+xml"/>')
    write_zip(path, [("[Content_Types].xml", TYPES.format(overrides=override)),
                     ("_rels/.rels", RELS.format(target="word/document.xml")),
                     ("word/document.xml", document)])


def xlsx(path: Path, rng: random.Random, lang: str) -> None:
    rows = []
    for r in range(1, rng.randint(150, 1500) + 1):
        cells = [f'<c r="A{r}"><v>{r}</v></c>',
                 f'<c r="B{r}" t="inlineStr"><is><t>{xml_escape(" ".join(rng.choice(WORDS[lang]) for _ in range(3)))}</t></is></c>',
                 f'<c r="C{r}"><v>{rng.randint(1, 99999) / 100}</v></c>',
                 f'<c r="D{r}" t="inlineStr"><is><t>{xml_escape(sentence(rng, lang))}</t></is></c>',
                 f'<c r="E{r}"><v>{45000 + rng.randint(0, 900)}</v></c>']
        rows.append(f'<row r="{r}">{"".join(cells)}</row>')
    sheet = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/'
             f'spreadsheetml/2006/main"><sheetData>{"".join(rows)}</sheetData></worksheet>')
    workbook = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/'
                'spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
                '<sheets><sheet name="Data" sheetId="1" r:id="rIdA"/></sheets></workbook>')
    workbook_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats'
                     '.org/package/2006/relationships"><Relationship Id="rIdA" Type="http://schemas.openxmlformats.org/'
                     'officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>')
    overrides = ('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml'
                 '.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-'
                 'officedocument.spreadsheetml.worksheet+xml"/>')
    write_zip(path, [("[Content_Types].xml", TYPES.format(overrides=overrides)),
                     ("_rels/.rels", RELS.format(target="xl/workbook.xml")),
                     ("xl/workbook.xml", workbook), ("xl/_rels/workbook.xml.rels", workbook_rels),
                     ("xl/worksheets/sheet1.xml", sheet)])


def pdf_text(text: str) -> bytes:
    # WinAnsi (cp1252) covers en/de; Czech/Slovak letters outside it fold to ASCII.
    folded = text.encode("cp1252", errors="replace").replace(b"?", b"")
    return folded.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


def pdf(path: Path, rng: random.Random, lang: str) -> None:
    pages = rng.randint(3, 25)
    objects = {1: b"<< /Type /Catalog /Pages 2 0 R >>", 3: b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
                                                          b"/Encoding /WinAnsiEncoding >>"}
    kids = []
    for page in range(pages):
        page_id, content_id = 4 + page * 2, 5 + page * 2
        kids.append(f"{page_id} 0 R".encode())
        lines = [b"BT /F1 10 Tf 12 TL 50 760 Td"]
        for _ in range(rng.randint(30, 55)):
            lines.append(b"(" + pdf_text(sentence(rng, lang)) + b") '")
        lines.append(b"ET")
        stream = b"\n".join(lines)
        objects[page_id] = (b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                            b"/Contents " + f"{content_id} 0 R".encode() + b" >>")
        objects[content_id] = b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream"
    objects[2] = b"<< /Type /Pages /Kids [" + b" ".join(kids) + b"] /Count " + str(pages).encode() + b" >>"
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for number in sorted(objects):
        offsets[number] = len(out)
        out += f"{number} 0 obj\n".encode() + objects[number] + b"\nendobj\n"
    xref = len(out)
    size = max(objects) + 1
    out += f"xref\n0 {size}\n0000000000 65535 f \n".encode()
    for number in range(1, size):
        out += f"{offsets[number]:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {size} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    path.write_bytes(bytes(out))


def eml(path: Path, rng: random.Random, lang: str, index: int) -> None:
    body = "\n\n".join(paragraphs(rng, lang, rng.randint(3, 25)))
    message = (f"From: Sender {index} <sender{index}@example.com>\nTo: Team <team@example.com>\n"
               f"Subject: {sentence(rng, lang)[:60]}\nDate: Tue, 07 Oct 2026 10:15:00 +0200\nMIME-Version: 1.0\n"
               f"Content-Type: text/plain; charset=\"utf-8\"\nContent-Transfer-Encoding: 8bit\n\n{body}\n")
    path.write_bytes(message.encode("utf-8"))


def txt(path: Path, rng: random.Random, lang: str) -> None:
    path.write_text("\n\n".join(paragraphs(rng, lang, rng.randint(10, 80))) + "\n", encoding="utf-8")


def generate(out: Path, files: int) -> None:
    marker = out / ".corpus"
    stamp = f"gen_cpu_corpus v1 files={files}\n"
    if marker.exists() and marker.read_text() == stamp:
        return
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20261011)
    kinds = [kind for kind, weight in MIX for _ in range(weight)]
    random.Random(7).shuffle(kinds)  # interleaved, so every subset is a mix
    for index in range(files):
        kind = kinds[index % len(kinds)]
        lang = LANGS[index % len(LANGS)]
        directory = out / f"d{index // 50:02d}"
        directory.mkdir(exist_ok=True)
        path = directory / f"file-{index:05d}.{kind}"
        if kind == "docx":
            docx(path, rng, lang)
        elif kind == "xlsx":
            xlsx(path, rng, lang)
        elif kind == "pdf":
            pdf(path, rng, lang)
        elif kind == "eml":
            eml(path, rng, lang, index)
        else:
            txt(path, rng, lang)
    marker.write_text(stamp)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--files", type=int, default=400)
    args = parser.parse_args()
    generate(Path(args.out), args.files)
