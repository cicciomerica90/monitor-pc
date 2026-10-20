"""Code coverage of the page's inline script, measured by Chromium itself.

Every test page is opened with V8 "precise coverage" turned on (the same data
Chrome DevTools shows in its Coverage tab). When a page is closed its result
is merged into one map of executed characters; at the end of the run the map
is turned into line, function and block (branch) percentages plus the list of
lines that never ran.

Only the script inside "Monitor PC.html" is measured.
"""
import json
import os
from pathlib import Path


class Collector:
    def __init__(self, page_name="Monitor PC.html"):
        self.page_name = page_name.replace(" ", "%20")
        self.source = None          # text of the inline script
        self.start_line = 0         # its first line inside the HTML file (0-based)
        self.hit = None             # per character: True = ran at least once
        self.blocks = {}            # (start, end) -> ran at least once
        self.functions = {}         # (start, end) -> (name, ran at least once)

    # ------------------------------------------------------------ per page
    def attach(self, context, page):
        """Call right after creating the page, before navigating."""
        cdp = context.new_cdp_session(page)
        scripts = {}
        cdp.on("Debugger.scriptParsed", lambda e: scripts.__setitem__(e["scriptId"], e))
        cdp.send("Debugger.enable")
        cdp.send("Profiler.enable")
        cdp.send("Profiler.startPreciseCoverage", {"callCount": True, "detailed": True})
        page._cov = (cdp, scripts)

    def collect(self, page):
        """Call before closing the page."""
        cdp, scripts = getattr(page, "_cov", (None, None))
        if cdp is None:
            return
        try:
            result = cdp.send("Profiler.takePreciseCoverage")["result"]
        except Exception:
            return
        for entry in result:
            url = entry["url"].split("?")[0].split("#")[0]
            if not url.endswith(self.page_name) and not url.endswith("/monitor.html"):
                continue
            info = scripts.get(entry["scriptId"])
            if not info or info.get("startLine", 0) == 0:
                continue                                    # only the inline <script>
            try:
                src = cdp.send("Debugger.getScriptSource", {"scriptId": entry["scriptId"]})["scriptSource"]
            except Exception:
                continue                                    # script of a page that was already replaced
            self._merge(src, info["startLine"], entry["functions"])

    def _merge(self, src, start_line, functions):
        if self.source is None:
            self.source, self.start_line = src, start_line
            self.hit = [False] * len(src)
        if src != self.source:
            return                                          # a different build of the page: ignore
        counts = [0] * len(src)
        ranges = []
        for f in functions:
            for i, r in enumerate(f["ranges"]):
                ranges.append((r["startOffset"], r["endOffset"], r["count"]))
                key = (r["startOffset"], r["endOffset"])
                if i == 0:
                    name = f["functionName"] or "(anonymous)"
                    if r["startOffset"] != 0 or r["endOffset"] != len(src):
                        self.functions[key] = name
                else:
                    self.blocks[key] = True
        # outer ranges first, inner ranges overwrite them
        for s, e, c in sorted(ranges, key=lambda r: (r[0], -(r[1] - r[0]))):
            for k in range(s, min(e, len(src))):
                counts[k] = c
        for k, c in enumerate(counts):
            if c > 0:
                self.hit[k] = True

    # ------------------------------------------------------------ report
    def report(self):
        if self.source is None:
            return {"error": "no coverage collected"}
        lines = self.source.split("\n")
        executable, covered, missed = 0, 0, []
        pos = 0
        for n, text in enumerate(lines):
            chars = [pos + i for i, ch in enumerate(text) if not ch.isspace()]
            pos += len(text) + 1
            code = text.strip()
            if not chars or code.startswith("//") or code.startswith("/*") or code.startswith("*"):
                continue
            executable += 1
            if any(self.hit[c] for c in chars):
                covered += 1
            else:
                missed.append(self.start_line + n + 1)       # line number inside the HTML file
        ran = lambda start: self.hit[start] if start < len(self.hit) else False
        blocks_total = len(self.blocks)
        blocks_hit = sum(1 for (s, e) in self.blocks if ran(s))
        fn_total = len(self.functions)
        fn_hit = sum(1 for (s, e) in self.functions if ran(s))
        return {
            "lines": {"covered": covered, "total": executable, "pct": round(100 * covered / max(1, executable), 1)},
            "functions": {"covered": fn_hit, "total": fn_total, "pct": round(100 * fn_hit / max(1, fn_total), 1)},
            "blocks": {"covered": blocks_hit, "total": blocks_total, "pct": round(100 * blocks_hit / max(1, blocks_total), 1)},
            "missed_lines": missed,
            "missed_blocks": sorted(self._line_of(s) for (s, e) in self.blocks if not ran(s)),
            "missed_block_code": [{"line": self._line_of(s), "code": self.source[s:min(e, s + 90)].replace("\n", " ")}
                                  for (s, e) in sorted(self.blocks) if not ran(s)],
            "missed_functions": sorted((self._line_of(s), name) for (s, e), name in self.functions.items() if not ran(s)),
        }

    def _line_of(self, offset):
        return self.start_line + self.source.count("\n", 0, offset) + 1

    def write(self, folder):
        rep = self.report()
        folder = Path(folder)
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "page-coverage.json").write_text(json.dumps(rep, indent=1), encoding="utf-8")
        text = format_report(rep)
        (folder / "page-coverage.txt").write_text(text, encoding="utf-8")
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as f:
                f.write("### Page coverage (Monitor PC.html)\n\n```\n" + text + "\n```\n")
        return rep, text


def format_report(rep):
    if "error" in rep:
        return rep["error"]
    out = ["Monitor PC.html, inline script",
           "  lines     {covered}/{total}  {pct}%".format(**rep["lines"]),
           "  functions {covered}/{total}  {pct}%".format(**rep["functions"]),
           "  blocks    {covered}/{total}  {pct}%".format(**rep["blocks"])]
    if rep["missed_lines"]:
        out.append("  lines never run: " + _ranges(rep["missed_lines"]))
    if rep["missed_blocks"]:
        out.append("  blocks never run start at lines: " + _ranges(sorted(set(rep["missed_blocks"]))))
    if rep["missed_functions"]:
        out.append("  functions never called: " + ", ".join("%s (line %d)" % (n, l) for l, n in rep["missed_functions"]))
    return "\n".join(out)


def _ranges(nums):
    out, start, prev = [], None, None
    for n in nums:
        if start is None:
            start = prev = n
        elif n == prev + 1:
            prev = n
        else:
            out.append(str(start) if start == prev else "%d-%d" % (start, prev))
            start = prev = n
    if start is not None:
        out.append(str(start) if start == prev else "%d-%d" % (start, prev))
    return ", ".join(out)
