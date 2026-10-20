"""Tests for "Monitor PC.html", run in headless Chromium with Playwright.

    python -m unittest discover -s tests/page -v

Each test talks to a fake LibreHardwareMonitor (fake_lhm.py) or feeds the
page snapshots directly. Code coverage of the page script is collected on
every page and written to tests/results/ at the end of the run.
"""
import json
import os
import re
import sys
import time
import unittest
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from coverage_v8 import Collector  # noqa: E402
from fake_lhm import FakeLhm, PAGE  # noqa: E402

PAGE_URL = PAGE.as_uri()
RESULTS = Path(os.environ.get("TEST_RESULTS", Path(__file__).resolve().parents[1] / "results"))
DEAD = "?host=http://127.0.0.1:9"          # nothing listens there: the page stays offline
COV = Collector()
PW = BROWSER = None


def setUpModule():
    global PW, BROWSER
    PW = sync_playwright().start()
    BROWSER = PW.chromium.launch()


def tearDownModule():
    BROWSER.close()
    PW.stop()
    _, text = COV.write(RESULTS)
    print("\n" + text)


# ------------------------------------------------------------------ snapshots fed straight to render()
def snap(cpu=None, gpu=None, ram=None):
    base_cpu = {"name": "Test CPU", "temp": 50, "load": 20, "threads": [20, 30], "clockMax": 4500, "clockAvg": 4200, "power": 60}
    base_gpu = {"name": "Test GPU", "temp": 45, "load": 10, "clock": 1500, "memClock": 1000, "power": 90, "fan": 1200,
                "vramUsed": 3 * 2 ** 30, "vramTotal": 12 * 2 ** 30}
    base_ram = {"used": 8 * 2 ** 30, "total": 32 * 2 ** 30, "load": 25}
    out = {"sensors": 3,
           "cpu": None if cpu is False else dict(base_cpu, **(cpu or {})),
           "gpu": None if gpu is False else dict(base_gpu, **(gpu or {})),
           "ram": None if ram is False else dict(base_ram, **(ram or {}))}
    return out


class Base(unittest.TestCase):
    def setUp(self):
        self.opened = []

    def tearDown(self):
        for ctx, page in self.opened:
            COV.collect(page)
            ctx.close()
        for ctx, page in self.opened:
            self.assertEqual(page.errors, [], "JavaScript errors on the page")

    def open(self, query="", locale="it-IT", init=None, base=None, clock=False, size=(800, 480)):
        ctx = BROWSER.new_context(locale=locale, viewport={"width": size[0], "height": size[1]})
        page = ctx.new_page()
        page.errors = []
        page.on("pageerror", lambda e: page.errors.append(str(e)))
        if init:
            page.add_init_script(init)
        COV.attach(ctx, page)
        if clock:
            page.clock.install()
        page.goto((base + "/monitor.html" if base else PAGE_URL) + query)
        self.opened.append((ctx, page))
        return page

    # helpers
    def text(self, page, sel):
        return page.eval_on_selector(sel, "e => e.textContent.trim()")

    def hidden(self, page, sel):
        return page.eval_on_selector(sel, "e => e.hidden || !!e.closest('[hidden]')")

    def wait(self, page, js, timeout=8000):
        page.wait_for_function(js, timeout=timeout)

    def state(self, page, pid):
        return page.eval_on_selector("#" + pid, "e => e.dataset.state + '/' + e.dataset.load")

    def save(self, page):
        """Press Save in the settings and wait until the page has applied them."""
        page.evaluate("""window.__saved = new Promise(r => document.querySelector('#settings')
            .addEventListener('close', () => setTimeout(r, 0), { once: true })); 0""")
        page.click("button[value=save]")
        page.evaluate("window.__saved")

    def reload(self, page):
        COV.collect(page)          # coverage of the page about to be replaced
        page.reload()

    def render(self, page, s):
        page.evaluate("s => window.__monitor.render(s)", s)


# ================================================================== reading LibreHardwareMonitor
class Reading(Base):
    def live(self, lhm, locale="it-IT"):
        page = self.open("?host=" + lhm.url, locale=locale)
        self.wait(page, "document.querySelector('#status').dataset.kind !== 'off'")
        return page

    def test_amd_nvidia_release_096_italian(self):
        with FakeLhm(fmt="096", locale="it") as lhm:
            p = self.live(lhm)
            self.assertEqual(self.text(p, "#cpu .temp-val"), "48")
            self.assertEqual(self.text(p, "#cpu .model"), "Ryzen 7 5800X3D")
            self.assertEqual(self.text(p, "#gpu .model"), "RTX 4070 SUPER")
            self.assertEqual(self.text(p, "#gpu .temp-val"), "44")
            self.assertEqual(self.text(p, "#status"), "Dati in tempo reale")
            self.assertEqual(self.text(p, "#cpu [data-f=tlabel]"), "16 thread")
            self.assertEqual(self.text(p, "#gpu [data-x=fan] b"), "ferma")
            self.assertEqual(self.text(p, "#gpu [data-f=vram]"), "3,0 / 12 GB")
            self.assertEqual(self.text(p, "#ram-used"), "11,3 GB")
            self.assertRegex(self.text(p, "#cpu [data-f=freq]"), r"^\d,\d\d$")
            self.assertEqual(self.state(p, "cpu"), "ok/normal")

    def test_intel_with_integrated_gpu_newer_format_english(self):
        with FakeLhm(fmt="master", locale="en", cpu="intel", gpu="nvidia") as lhm:
            p = self.live(lhm, locale="en-US")
            self.assertEqual(self.text(p, "#cpu .model"), "Core i7-13700K")
            self.assertEqual(self.text(p, "#gpu .model"), "RTX 4070 SUPER")     # the discrete card wins
            self.assertEqual(self.text(p, "#cpu .temp-val"), "48")              # "CPU Package"
            self.assertEqual(self.text(p, "#cpu [data-f=tlabel]"), "24 threads")
            self.assertRegex(self.text(p, "#cpu [data-f=freq]"), r"^\d\.\d\d$")
            self.assertEqual(self.text(p, "#gpu [data-f=vram]"), "3.0 / 12 GB")
            self.assertEqual(self.text(p, "#ram-used"), "11.3 GB")

    def test_radeon_total_memory_from_used_plus_free(self):
        with FakeLhm(fmt="master", locale="en", gpu="amd") as lhm:
            p = self.live(lhm, locale="en-US")
            self.assertEqual(self.text(p, "#gpu .model"), "RX 7800 XT")
            self.assertEqual(self.text(p, "#gpu [data-f=vram]"), "4.1 / 16 GB")
            self.assertEqual(self.text(p, "#gpu [data-x=fan] b"), "950 RPM")

    def test_fahrenheit_setting_does_not_change_the_reading(self):
        with FakeLhm(fmt="096", fahrenheit=True) as lhm:
            p = self.live(lhm)
            self.assertEqual(self.text(p, "#cpu .temp-val"), "48")

    def test_oldest_format_without_raw_values_in_fahrenheit(self):
        with FakeLhm(fmt="noraw", fahrenheit=True, locale="en") as lhm:
            p = self.live(lhm)
            self.assertEqual(self.text(p, "#cpu .temp-val"), "48")
            self.assertEqual(self.text(p, "#gpu .temp-val"), "44")
            self.assertEqual(self.text(p, "#ram-used"), "11,3 GB")

    def test_only_integrated_graphics(self):
        with FakeLhm(cpu="intel", gpu="igpu") as lhm:
            p = self.live(lhm)
            self.assertEqual(self.text(p, "#gpu .model"), "UHD Graphics 770")
            self.assertEqual(self.text(p, "#gpu .temp-val"), "–")
            self.assertEqual(self.text(p, "#gpu .temp-peak"), "non disponibile")
            self.assertTrue(self.hidden(p, "#gpu .under"))
            self.assertEqual(self.state(p, "gpu"), "unknown/normal")

    def test_without_administrator_rights(self):
        with FakeLhm(noadmin=True) as lhm:
            p = self.live(lhm)
            self.assertEqual(self.text(p, "#cpu .temp-val"), "–")
            self.assertEqual(self.text(p, "#cpu [data-f=freq]"), "–")
            self.assertTrue(self.hidden(p, "#cpu [data-x=power]"))
            self.assertIn("amministratore", self.text(p, "#status"))
            self.assertEqual(p.eval_on_selector("#status", "e => e.dataset.kind"), "warn")

    def test_old_cpu_and_no_graphics_card(self):
        with FakeLhm(cpu="old", gpu="none") as lhm:
            p = self.live(lhm)
            self.assertEqual(self.text(p, "#cpu .temp-val"), "48")          # single "CPU Cores" sensor
            self.assertEqual(self.text(p, "#gpu .model"), "Nessuna scheda video rilevata")
            self.assertTrue(self.hidden(p, "#gpu .extras"))
            self.assertTrue(self.hidden(p, "#gpu .under"))
            self.assertTrue(self.hidden(p, "#cpu [data-x=power]"))
            self.assertEqual(self.text(p, "#cpu [data-f=tlabel]"), "8 thread")

    def test_cpu_missing_from_the_list(self):
        with FakeLhm(cpu="none") as lhm:
            p = self.live(lhm)
            self.assertEqual(self.text(p, "#cpu .model"), "Processore non rilevato")
            self.assertIn("File → Hardware", self.text(p, "#status"))
            self.assertTrue(self.hidden(p, "#cpu .extras"))
            self.assertTrue(self.hidden(p, "#cpu .under"))

    def test_unusual_sensor_trees(self):
        p = self.open(DEAD)

        def node(text, typ=None, sid=None, value=None, raw="absent", children=None, hwid=None):
            n = {"Text": text, "Children": children or []}
            if hwid:
                n["HardwareId"] = hwid
            if typ:
                n.update({"Type": typ, "SensorId": sid, "Value": value})
                if raw != "absent":
                    n["RawValue"] = raw
            return n
        tree = node("root", children=[None, 7, node("PC", children=[
            # CPU with no preferred temperature or total load: max of the cores, average of the threads
            node("Some CPU", hwid="/intelcpu/0", children=[
                node("Temperatures", children=[node("Core #1", "Temperature", "/intelcpu/0/temperature/0", "61,0 °C"),
                                               node("Core #2", "Temperature", "/intelcpu/0/temperature/1", "67,0 °C"),
                                               node("Broken", "Temperature", "/intelcpu/0/temperature/2", "-", raw=None)]),
                node("Load", children=[node("CPU Core #1", "Load", "/intelcpu/0/load/2", "20 %", raw=20),
                                       node("CPU Core #2", "Load", "/intelcpu/0/load/3", "40 %", raw=40)])]),
            # GPU with no "GPU Core" temperature: the first sensor that is not a hot spot or memory
            node("Some GPU", hwid="/gpu-amd/0", children=[
                node("Temperatures", children=[node("GPU Hot Spot", "Temperature", "/gpu-amd/0/temperature/0", "80 °C", raw=80),
                                               node("GPU Diode", "Temperature", "/gpu-amd/0/temperature/1", "55 °C", raw=55)]),
                node("Data", children=[node("GPU Memory Used", "SmallData", "/gpu-amd/0/smalldata/0", None, raw=512),
                                       node("D3D Dedicated Memory Total", "Data", "/gpu-amd/0/data/1", None, raw=4.0)])]),
            # memory values without units: bytes when large, GB otherwise
            node("Total Memory", hwid="/ram", children=[
                node("Data", children=[node("Memory Used", "Data", "/ram/data/0", None, raw=3 * 2 ** 30),
                                       node("Memory Available", "Data", "/ram/data/1", None, raw=5.0)])]),
            # a sensor whose hardware node has no HardwareId: named after the grandparent
            node("Mystery board", children=[node("Group", children=[node("Fan", "Fan", "/lpc/x/fan/0", "900 RPM", raw="900 RPM")])]),
            # single-core CPU: load comes from "CPU Core"
        ])])
        s = p.evaluate("t => window.__monitor.snapshotFromLhm(t)", tree)
        self.assertEqual(s["cpu"]["temp"], 67)
        self.assertEqual(s["cpu"]["load"], 30)
        self.assertEqual(s["gpu"]["temp"], 55)
        self.assertEqual(s["gpu"]["vramUsed"], 512 * 2 ** 20)
        self.assertEqual(s["gpu"]["vramTotal"], 4 * 2 ** 30)
        self.assertEqual(s["ram"]["used"], 3 * 2 ** 30)
        self.assertEqual(s["ram"]["total"], 8 * 2 ** 30)
        self.assertEqual(s["sensors"], 4)

        odd = node("root", children=[
            node("", "Fan", "/lonely/fan/0", "100 RPM", raw=100),        # straight under the root: named after its id
            node("Total Memory", hwid="/ram", children=[node("Data", children=[
                node("Memory Used", "Data", "/ram/data/0", None, raw=None),
                node("Memory Used", "Data", "/ram/data/0", "4 GB", raw="4,0 GB"),
                node("Memory Available", "Data", "/ram/data/1", None, raw=float("nan"))])]),
            node("Some CPU", hwid="/amdcpu/0", children=[node("T", children=[
                node("CPU Cores", "Temperature", "/amdcpu/0/temperature/0", None),
                node("Core (Tctl/Tdie)", "Temperature", "/amdcpu/0/temperature/1", "58 °C", raw=float("nan"))])])])
        s = p.evaluate("t => window.__monitor.snapshotFromLhm(t)", odd)
        self.assertEqual(s["sensors"], 3)
        self.assertIsNone(s["cpu"]["temp"])                    # no usable value at all
        self.assertEqual(s["ram"]["used"], 4 * 2 ** 30)
        self.assertIsNone(s["ram"]["total"])                   # "Memory Available" missing
        names = p.evaluate("t => window.__monitor.snapshotFromLhm({Children: [t]}).sensors", odd)
        self.assertEqual(names, 3)

        single = node("root", children=[node("Old CPU", hwid="/genericcpu/0", children=[
            node("Load", children=[node("CPU Core", "Load", "/genericcpu/0/load/0", "33 %", raw=33)])])])
        s = p.evaluate("t => window.__monitor.snapshotFromLhm(t)", single)
        self.assertEqual(s["cpu"]["load"], 33)
        self.assertIsNone(s["cpu"]["temp"])
        self.assertIsNone(s["gpu"])
        self.assertIsNone(s["ram"])


# ================================================================== alarms and load
class Alarms(Base):
    def test_heating_up_alarm_and_hysteresis(self):
        with FakeLhm() as lhm:
            p = self.open("?host=" + lhm.url)
            self.wait(p, "document.querySelector('#cpu').dataset.state === 'ok'")
            steps = [(85, "warm"), (91, "hot"), (89, "hot"), (87, "warm"), (79, "warm"), (77, "ok")]
            for t, want in steps:
                lhm.set(cpu_t=t)
                p.wait_for_function("t => document.querySelector('#cpu .temp-val').textContent === String(t)", arg=t, timeout=8000)
                self.assertEqual(p.eval_on_selector("#cpu", "e => e.dataset.state"), want, "at %d °C" % t)
                if want == "hot":
                    self.assertTrue(p.title().startswith("⚠ CPU %d°" % t), p.title())
                    self.assertEqual(self.text(p, "#cpu .verdict"), "Temperatura alta")
                if want == "warm":
                    self.assertEqual(self.text(p, "#cpu .verdict"), "Sta scaldando")
            self.assertEqual(p.title(), "Monitor PC")
            self.assertEqual(self.text(p, "#cpu .temp-peak"), "picco 91°")

    def test_full_load_needs_three_samples_and_releases_after_three(self):
        p = self.open(DEAD)
        seq = []
        for load in [100, 100, 100, 96, 92, 50, 50, 50]:
            self.render(p, snap(cpu={"load": load}))
            seq.append(p.eval_on_selector("#cpu", "e => e.dataset.load"))
        self.assertEqual(seq, ["normal", "normal", "full", "full", "full", "full", "full", "normal"])
        self.assertFalse(self.hidden(p, "#cpu .chip"))
        self.render(p, snap(cpu={"load": None}))
        self.assertEqual(p.eval_on_selector("#cpu", "e => e.dataset.load"), "normal")
        self.assertEqual(self.text(p, "#cpu [data-f=load]"), "–")

    def test_three_digit_temperature_shrinks(self):
        p = self.open(DEAD)
        self.render(p, snap(cpu={"temp": 101}))
        self.assertTrue(p.eval_on_selector("#cpu", "e => e.classList.contains('three')"))
        self.assertEqual(p.eval_on_selector("#cpu", "e => e.dataset.state"), "hot")
        self.render(p, snap(cpu={"temp": 70}))
        self.assertFalse(p.eval_on_selector("#cpu", "e => e.classList.contains('three')"))

    def test_edge_values_in_the_panels(self):
        p = self.open(DEAD)
        self.render(p, snap(cpu={"threads": [], "clockMax": None, "clockAvg": None, "power": None},
                            gpu={"clock": 12000, "fan": 0, "vramTotal": None, "memClock": None, "power": None},
                            ram={"total": None, "load": 40}))
        self.assertEqual(self.text(p, "#gpu [data-f=freq]"), "12,00")
        self.assertEqual(self.text(p, "#gpu [data-f=frequ]"), "GHz")
        self.assertEqual(self.text(p, "#gpu [data-x=fan] b"), "ferma")
        self.assertEqual(self.text(p, "#gpu [data-f=vram]"), "3,0 GB")
        self.assertTrue(self.hidden(p, "#gpu [data-x=memclk]"))
        self.assertTrue(self.hidden(p, "#cpu .under"))
        self.assertTrue(self.hidden(p, "#cpu [data-x=avg]"))
        self.assertEqual(self.text(p, "#cpu [data-f=freq]"), "–")
        self.assertEqual(self.text(p, "#ram-of"), "")
        self.assertEqual(p.eval_on_selector("#ram-bar", "e => e.style.getPropertyValue('--p')"), "40%")
        self.render(p, snap(gpu={"clock": None}, ram={"total": None, "load": None}))
        self.assertEqual(self.text(p, "#gpu [data-f=freq]"), "–")
        self.render(p, snap(ram={"used": None}))
        self.assertTrue(self.hidden(p, ".ram"))
        self.render(p, snap(cpu=False, gpu=False, ram=False))
        self.assertEqual(self.text(p, "#cpu .model"), "Processore non rilevato")
        self.assertEqual(self.state(p, "gpu"), "unknown/normal")

    def test_long_history_fewer_threads_and_unnamed_hardware(self):
        p = self.open(DEAD)
        for i in range(125):                                   # the graph keeps the last 120 samples
            self.render(p, snap(cpu={"temp": 40 + i % 10, "threads": [10] * 16}))
        self.assertEqual(p.evaluate("window.__monitor.P.cpu.hist.length"), 120)
        self.assertEqual(p.eval_on_selector_all("#cpu .threads i", "l => l.length"), 16)
        self.render(p, snap(cpu={"threads": [10] * 8, "name": ""}))
        self.assertEqual(p.eval_on_selector_all("#cpu .threads i", "l => l.length"), 8)
        self.assertEqual(self.text(p, "#cpu .model"), "")

    def test_close_thresholds_show_only_the_alarm_mark(self):
        init = "localStorage.setItem('monitor-pc.v1', JSON.stringify({cpuWarn: 88, cpuCrit: 90}))"
        p = self.open(DEAD, init=init)
        self.assertTrue(p.eval_on_selector("#cpu .mark.warn", "e => e.hidden"))
        self.assertFalse(p.eval_on_selector("#gpu .mark.warn", "e => e.hidden"))
        self.assertEqual(self.text(p, "#cpu .mark.crit"), "90°")


# ================================================================== connection
class Connection(Base):
    def test_setup_screen_until_the_server_appears(self):
        with FakeLhm(status=500) as lhm:
            p = self.open("?host=" + lhm.url)
            self.wait(p, "!document.querySelector('#setup').hidden")
            self.assertIn("127.0.0.1:%d" % lhm.server.server_address[1], self.text(p, "#setup-wait"))
            lhm.status = 200
            self.wait(p, "document.querySelector('#setup').hidden", timeout=10000)
            self.assertEqual(self.text(p, "#status"), "Dati in tempo reale")

    def test_lost_connection_dims_the_panels_and_recovers(self):
        with FakeLhm() as lhm:
            p = self.open("?host=" + lhm.url)
            self.wait(p, "document.querySelector('#status').dataset.kind === 'live'")
            lhm.status = 500
            self.wait(p, "document.body.dataset.stale === '1'", timeout=10000)
            self.assertIn("Nessun dato da", self.text(p, "#status"))
            self.assertTrue(self.hidden(p, "#setup"))            # it was live once: no setup screen
            lhm.status = 200
            self.wait(p, "document.body.dataset.stale === '0'", timeout=10000)

    def test_invalid_or_empty_answers_count_as_missing(self):
        for body in ("this is not json", json.dumps({"Text": "Sensor", "Children": []})):
            with FakeLhm(body=body) as lhm:
                p = self.open("?host=" + lhm.url)
                self.wait(p, "!document.querySelector('#setup').hidden")
                self.assertGreater(lhm.requests, 0)

    def test_password_protected_server_counts_as_missing(self):
        with FakeLhm(status=401) as lhm:
            p = self.open("?host=" + lhm.url)
            self.wait(p, "!document.querySelector('#setup').hidden")

    def test_web_preview_starts_the_demo_then_switches_to_real_data(self):
        with FakeLhm(status=500) as lhm:
            init = "localStorage.setItem('monitor-pc.v1', JSON.stringify({host: '%s'}))" % lhm.url
            p = self.open("", init=init, base=lhm.url)          # served over http, no ?host
            self.wait(p, "!document.querySelector('#demo-tag').hidden")
            self.assertTrue(self.hidden(p, "#setup"))
            p.wait_for_timeout(4500)                            # at least one check while the server still fails
            self.assertFalse(self.hidden(p, "#demo-tag"))
            lhm.status = 200
            self.wait(p, "document.querySelector('#demo-tag').hidden", timeout=12000)
            self.wait(p, "document.querySelector('#status').dataset.kind === 'live'")


    def test_demo_started_while_a_reading_is_on_its_way(self):
        # the answer (good or bad) arrives after the demo started: the demo must stay
        for status in (200, 500):
            with FakeLhm(delay=1.5, status=status) as lhm:
                p = self.open("?host=" + lhm.url)
                p.keyboard.press("d")
                p.wait_for_timeout(2500)
                self.assertFalse(self.hidden(p, "#demo-tag"), status)
                self.assertTrue(self.hidden(p, "#setup"), status)
                self.assertNotEqual(self.text(p, "#status"), "Dati in tempo reale")

# ================================================================== demo
class Demo(Base):
    def test_demo_goes_through_every_state_in_a_minute(self):
        p = self.open("?demo=1", clock=True)
        seen = []
        for _ in range(62):
            p.clock.run_for(1000)
            st = self.state(p, "cpu") + " " + self.state(p, "gpu")
            if not seen or seen[-1] != st:
                seen.append(st)
        joined = " | ".join(seen)
        self.assertEqual(seen[0], "ok/normal ok/normal", joined)
        self.assertIn("ok/full", joined)
        self.assertIn("hot/full", joined)
        self.assertEqual(seen[-1], "ok/normal ok/normal", joined)
        self.assertFalse(self.hidden(p, "#demo-tag"))
        self.assertEqual(self.text(p, "#status"), "")

    def test_demo_on_and_off(self):
        p = self.open(DEAD)
        self.wait(p, "!document.querySelector('#setup').hidden")
        p.click("#setup-demo")
        self.assertFalse(self.hidden(p, "#demo-tag"))
        self.assertTrue(self.hidden(p, "#setup"))
        p.click("#demo-tag")
        self.assertTrue(self.hidden(p, "#demo-tag"))
        p.keyboard.press("d")
        self.assertFalse(self.hidden(p, "#demo-tag"))
        p.keyboard.press("d")
        self.assertTrue(self.hidden(p, "#demo-tag"))


# ================================================================== settings
class Settings(Base):
    def saved(self, p):
        return json.loads(p.evaluate("localStorage.getItem('monitor-pc.v1')") or "{}")

    def test_save_clamps_thresholds_fixes_the_address_and_persists(self):
        with FakeLhm() as lhm:
            p = self.open(DEAD)
            p.keyboard.press("s")
            p.fill("input[name=cpuWarn]", "95")
            p.fill("input[name=cpuCrit]", "90")
            p.fill("input[name=gpuWarn]", "70")
            p.fill("input[name=gpuCrit]", "60")
            p.fill("input[name=fullLoad]", "90")
            p.fill("input[name=host]", lhm.url.replace("http://", ""))
            self.save(p)
            cfg = self.saved(p)
            self.assertEqual((cfg["cpuWarn"], cfg["cpuCrit"], cfg["gpuWarn"], cfg["gpuCrit"], cfg["fullLoad"]), (90, 90, 60, 60, 90))
            self.assertEqual(cfg["host"], lhm.url)
            self.assertEqual(self.text(p, "#cpu .mark.crit"), "90°")
            # a new address connects right away
            self.wait(p, "document.querySelector('#status').dataset.kind === 'live'")
            self.reload(p)
            self.assertEqual(p.evaluate("window.__monitor.cfg().cpuCrit"), 90)

    def test_cancel_defaults_and_buttons(self):
        p = self.open(DEAD)
        self.wait(p, "!document.querySelector('#setup').hidden")
        p.click("#setup-settings")
        self.assertTrue(p.evaluate("document.querySelector('#settings').open"))
        p.fill("input[name=cpuCrit]", "70")
        p.click("button[value=cancel]")
        self.assertEqual(p.evaluate("window.__monitor.cfg().cpuCrit"), 90)
        p.eval_on_selector("#btn-settings", "e => e.click()")       # the setup screen covers the toolbar
        p.fill("input[name=cpuCrit]", "70")
        p.check("input[name=sound]")
        p.click("#settings-reset")
        self.assertEqual(p.input_value("input[name=cpuCrit]"), "90")
        self.assertFalse(p.is_checked("input[name=sound]"))
        p.click("#settings-demo")
        self.assertFalse(p.evaluate("document.querySelector('#settings').open"))
        self.assertFalse(self.hidden(p, "#demo-tag"))

    def test_keys_are_ignored_while_the_dialog_is_open_or_with_ctrl(self):
        p = self.open(DEAD)
        p.keyboard.press("Control+d")
        self.assertTrue(self.hidden(p, "#demo-tag"))
        p.keyboard.press("s")
        p.keyboard.press("d")
        self.assertTrue(self.hidden(p, "#demo-tag"))
        p.keyboard.press("x")

    def test_storage_that_throws_does_not_break_the_page(self):
        init = """Object.defineProperty(window, 'localStorage', { get() { throw new Error('blocked'); } });"""
        with FakeLhm() as lhm:
            p = self.open("?host=" + lhm.url, init=init)
            self.wait(p, "document.querySelector('#status').dataset.kind === 'live'")
            p.keyboard.press("s")
            p.fill("input[name=cpuCrit]", "85")
            self.save(p)
            self.assertEqual(p.evaluate("window.__monitor.cfg().cpuCrit"), 85)

    def test_corrupt_saved_settings_fall_back_to_defaults(self):
        p = self.open(DEAD, init="localStorage.setItem('monitor-pc.v1', '{not json')")
        self.assertEqual(p.evaluate("window.__monitor.cfg().cpuCrit"), 90)
        p = self.open(DEAD, init="localStorage.setItem('monitor-pc.v1', 'null')")
        self.assertEqual(p.evaluate("window.__monitor.cfg().cpuCrit"), 90)

    def test_blank_address_goes_back_to_the_default(self):
        p = self.open(DEAD)
        p.keyboard.press("s")
        p.fill("input[name=host]", "   ")
        self.save(p)
        self.assertEqual(p.evaluate("window.__monitor.cfg().host"), "http://localhost:8085")


# ================================================================== language
class Language(Base):
    def test_automatic_language(self):
        for locale, want, label in (("it-IT", "it", "Carico"), ("en-US", "en", "Load"), ("de-DE", "en", "Load")):
            p = self.open(DEAD, locale=locale)
            self.assertEqual(p.evaluate("document.documentElement.lang"), want, locale)
            self.assertEqual(self.text(p, "#cpu .label"), label)

    def test_language_from_the_address_and_from_the_settings(self):
        p = self.open(DEAD + "&lang=en", locale="it-IT")
        self.assertEqual(self.text(p, "#setup h1"), "Only the sensor reader is missing")
        p = self.open("?demo=1", locale="it-IT")
        p.keyboard.press("s")
        p.select_option("select[name=lang]", "en")
        self.save(p)
        self.assertEqual(self.text(p, "#demo-tag"), "Demo, fake data")
        self.assertEqual(p.get_attribute("#btn-full", "title"), "Full screen (F)")
        self.reload(p)
        self.assertEqual(p.evaluate("document.documentElement.lang"), "en")
        p.keyboard.press("s")
        p.select_option("select[name=lang]", "it")
        self.save(p)
        self.assertEqual(self.text(p, "#demo-tag"), "Demo, dati finti")

    def test_browser_without_a_language_and_unknown_texts(self):
        p = self.open(DEAD, init="Object.defineProperty(navigator, 'language', { get: () => undefined });")
        self.assertEqual(p.evaluate("document.documentElement.lang"), "en")
        self.assertEqual(p.evaluate("window.__monitor.t('no-such-text')"), "no-such-text")

    def test_every_text_exists_in_both_languages(self):
        p = self.open(DEAD)
        r = p.evaluate("""() => { const M = window.__monitor.I18N;
            const used = [...document.querySelectorAll('[data-t],[data-th],[data-t-title],[data-t-aria]')]
              .flatMap(e => [e.dataset.t, e.dataset.th, e.dataset.tTitle, e.dataset.tAria]).filter(Boolean);
            return { it: Object.keys(M.it).sort(), en: Object.keys(M.en).sort(), missing: used.filter(k => !(k in M.it) || !(k in M.en)) }; }""")
        self.assertEqual(r["it"], r["en"])
        self.assertEqual(r["missing"], [])


# ================================================================== browser features
FAKE_AUDIO = """
window.__beeps = 0;
window.AudioContext = class { constructor() { this.state = 'suspended'; this.currentTime = 0; this.destination = {}; }
  resume() { this.state = 'running'; }
  createOscillator() { window.__beeps++; return { type: '', frequency: {}, connect: g => g, start() {}, stop() {} }; }
  createGain() { const g = { gain: { setValueAtTime() {}, linearRampToValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect: x => x }; return g; } };
"""


class Browser(Base):
    def test_beep_on_alarm_and_every_twenty_seconds(self):
        init = FAKE_AUDIO + "localStorage.setItem('monitor-pc.v1', JSON.stringify({sound: true}));"
        p = self.open(DEAD, init=init, clock=True)
        self.render(p, snap(cpu={"temp": 95}))
        self.assertEqual(p.evaluate("window.__beeps"), 2)            # two short beeps
        p.clock.run_for(6000)
        self.assertEqual(p.evaluate("window.__beeps"), 2)            # not again too soon
        p.clock.run_for(20000)
        self.assertEqual(p.evaluate("window.__beeps"), 4)
        self.render(p, snap(cpu={"temp": 50}))
        p.clock.run_for(25000)
        self.assertEqual(p.evaluate("window.__beeps"), 4)            # silent once it cools down

    def test_no_beep_when_sound_is_off_and_broken_audio_is_harmless(self):
        p = self.open(DEAD, init=FAKE_AUDIO)
        self.render(p, snap(cpu={"temp": 95}))
        self.assertEqual(p.evaluate("window.__beeps"), 0)
        init = "window.AudioContext = function () { throw new Error('no audio'); };" \
               "localStorage.setItem('monitor-pc.v1', JSON.stringify({sound: true}));"
        p = self.open(DEAD, init=init)
        self.render(p, snap(cpu={"temp": 95}))
        p.keyboard.press("s")
        self.save(p)                                 # saving with sound on plays a test beep

    def test_beep_with_the_older_audio_name(self):
        init = FAKE_AUDIO.replace("window.AudioContext =", "window.webkitAudioContext =") + \
            "delete window.AudioContext; window.AudioContext = undefined;" \
            "localStorage.setItem('monitor-pc.v1', JSON.stringify({sound: true}));"
        p = self.open(DEAD, init=init)
        self.render(p, snap(cpu={"temp": 95}))
        self.assertEqual(p.evaluate("window.__beeps"), 2)

    def test_screen_stays_awake_and_the_pointer_hides(self):
        init = "window.__locks = 0; Object.defineProperty(navigator, 'wakeLock', { value: { request: async () => { window.__locks++; return {}; } } });"
        p = self.open(DEAD, init=init, clock=True)
        self.assertEqual(p.evaluate("window.__locks"), 1)
        p.evaluate("document.dispatchEvent(new Event('visibilitychange'))")
        self.assertEqual(p.evaluate("window.__locks"), 2)
        p.clock.run_for(4500)
        self.assertTrue(p.evaluate("document.body.classList.contains('idle')"))
        p.mouse.move(10, 10)
        self.assertFalse(p.evaluate("document.body.classList.contains('idle')"))
        self.assertRegex(self.text(p, "#clock"), r"^\d\d:\d\d$")

    def test_wake_lock_refused_is_harmless(self):
        init = "Object.defineProperty(navigator, 'wakeLock', { value: { request: () => Promise.reject(new Error('no')) } });"
        self.open(DEAD, init=init)

    def test_full_screen_key_and_button(self):
        init = """window.__fs = 0; window.__exit = 0; let on = null;
          Object.defineProperty(document, 'fullscreenElement', { get: () => on });
          Element.prototype.requestFullscreen = function () { window.__fs++; on = this; return Promise.resolve(); };
          document.exitFullscreen = function () { window.__exit++; on = null; return Promise.resolve(); };"""
        p = self.open(DEAD, init=init)
        p.keyboard.press("f")
        p.keyboard.press("f")
        p.eval_on_selector("#btn-full", "e => e.click()")
        self.assertEqual(p.evaluate("[window.__fs, window.__exit]"), [2, 1])

    def test_refused_full_screen_is_harmless(self):
        init = "Element.prototype.requestFullscreen = () => Promise.reject(new Error('denied'));"
        p = self.open(DEAD, init=init)
        p.keyboard.press("f")


class Layout(Base):
    def test_no_horizontal_scroll_at_common_small_screen_sizes(self):
        for size in ((480, 320), (800, 480), (1024, 600), (1920, 480), (480, 800)):
            p = self.open("?demo=1", size=size)
            p.wait_for_timeout(300)
            self.assertLessEqual(p.evaluate("document.documentElement.scrollWidth"), size[0], size)


if __name__ == "__main__":
    unittest.main(verbosity=2)
