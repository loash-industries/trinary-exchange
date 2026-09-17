#!/usr/bin/env python3
"""Splice Appendix B (section + figure script) into the whitepaper HTML.

Idempotent: an existing <section id="s11"> and the LADDER script block are
replaced rather than duplicated, so this can be re-run after editing either
fragment.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTML = os.path.join(ROOT, "whitepaper.html")
SEC = os.path.join(ROOT, "figs_section.html")
SCR = os.path.join(ROOT, "figs_script.html")
DATA = os.path.join(ROOT, "results", "ladder_data.json")

COLOPHON_RE = re.compile(
    r'\n    <hr class="end">\n    <p class="colophon">.*?</p>\n', re.S)
SEC11_RE = re.compile(r'\n  <!-- ============ 11 ============ -->.*?'
                      r'\n  </section>\n', re.S)
SCRIPT_RE = re.compile(r'\n<script>\nvar LADDER = .*?\n</script>\n', re.S)


def main():
    html = open(HTML).read()
    section = open(SEC).read().rstrip("\n")
    script = open(SCR).read().rstrip("\n")
    data = open(DATA).read().strip()
    script = script.replace("__LADDER__", data)

    # drop a previously spliced section / script so this is re-runnable
    html = SEC11_RE.sub("\n", html)
    html = SCRIPT_RE.sub("\n", html)

    # the colophon closes the document: move it out of s10 into the new s11
    m = COLOPHON_RE.search(html)
    if m:
        html = html[:m.start()] + "\n" + html[m.end():]

    # insert the section after the last section closes, before .paper's </div>
    m = re.search(r"</section>\s*\n</div>", html)
    if not m:
        raise SystemExit("could not find the end of the last section")
    at = html.index("\n", m.start()) + 1
    html = html[:at] + "\n" + section + "\n" + html[at:]

    html = html.rstrip("\n") + "\n" + script + "\n"
    open(HTML, "w").write(html)
    print(f"spliced: section {len(section):,} chars, "
          f"script {len(script):,} chars, data {len(data):,} chars")


if __name__ == "__main__":
    main()
