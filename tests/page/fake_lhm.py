"""Fake LibreHardwareMonitor web server for the page tests.

It serves /data.json with the same tree shape and headers as the real
server (LibreHardwareMonitor.Windows.Forms/Utilities/HttpServer.cs), in the
two formats seen in the wild:

  fmt="096"     release 0.9.x: RawValue is a formatted string, Data in GB,
                SmallData in MB
  fmt="master"  later builds: RawValue is a number, Data in bytes
  fmt="noraw"   very old builds: no RawValue at all, only formatted Value

It also serves the page itself at /monitor.html, so tests can load it over
http as well as from file://.
"""
import json
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PAGE = Path(__file__).resolve().parents[2] / "Monitor PC.html"

FORMATS = {"Voltage": "{:.3f} V", "Clock": "{:.1f} MHz", "Load": "{:.1f} %", "Temperature": "{:.1f} °C",
           "Fan": "{:.0f} RPM", "Control": "{:.1f} %", "Power": "{:.1f} W", "Factor": "{:.3f}"}


class FakeLhm:
    """Options:
    fmt       "096" | "master" | "noraw"
    locale    "it" (decimal comma) | "en"
    cpu       "amd" | "intel" | "old" | "none"
    gpu       "nvidia" | "amd" | "igpu" | "none"
    fahrenheit, noadmin (no driver-backed sensors)
    status    HTTP status for /data.json (200 normally; 401, 500...)
    delay     seconds to wait before answering /data.json
    body      raw body to send instead of the JSON tree (e.g. invalid JSON)
    """

    def __init__(self, **opts):
        self.fmt = opts.get("fmt", "096")
        self.locale = opts.get("locale", "it")
        self.cpu = opts.get("cpu", "amd")
        self.gpu = opts.get("gpu", "nvidia")
        self.fahrenheit = opts.get("fahrenheit", False)
        self.noadmin = opts.get("noadmin", False)
        self.status = opts.get("status", 200)
        self.body = opts.get("body")
        self.delay = opts.get("delay", 0)
        self.state = {"cpu_t": 48.0, "cpu_l": 12.0, "gpu_t": 44.0, "gpu_l": 6.0}
        self.requests = 0
        self.lock = threading.Lock()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    # ------------------------------------------------------------ lifecycle
    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def set(self, **values):
        with self.lock:
            self.state.update({k: float(v) for k, v in values.items()})

    # ------------------------------------------------------------ formatting
    def _loc(self, s):
        return s.replace(".", ",") if self.locale == "it" else s

    def _fmt(self, typ, v, raw=False):
        if v is None:
            return "-"
        if typ == "Temperature" and self.fahrenheit and not raw:
            return self._loc("{:.1f} °F".format(v * 1.8 + 32))
        if typ in ("Data", "SmallData"):
            if self.fmt == "096":
                return self._loc("{:.1f} {}".format(v, "GB" if typ == "Data" else "MB"))
            for lim, unit in ((2 ** 20, "KB"), (2 ** 30, "MB"), (2 ** 40, "GB")):
                if v < lim:
                    return self._loc("{:.1f} {}".format(v / (lim / 1024), unit))
            return self._loc("{:.1f} TB".format(v / 2 ** 40))
        return self._loc(FORMATS[typ].format(v))

    def _gb(self, v):
        return v if self.fmt == "096" else v * 2 ** 30

    def _mb(self, v):
        return v if self.fmt == "096" else v * 2 ** 20

    # ------------------------------------------------------------ tree
    def build(self):
        with self.lock:
            s = dict(self.state)
        ids = iter(range(1, 10 ** 6))
        j = lambda a: random.uniform(-a, a)
        fake = self

        def sensor(hw, name, typ, idx, v):
            t = "Data" if (typ == "SmallData" and fake.fmt == "master") else typ
            n = {"id": next(ids), "Text": name, "Min": fake._fmt(typ, v), "Value": fake._fmt(typ, v), "Max": fake._fmt(typ, v),
                 "SensorId": "{}/{}/{}".format(hw, t.lower(), idx), "Type": t}
            if fake.fmt == "master":
                n["RawMin"] = n["RawValue"] = n["RawMax"] = v
            elif fake.fmt == "096":
                n["RawValue"] = fake._fmt(typ, v, raw=True)
            n["ImageURL"] = "images/transparent.png"
            n["Children"] = []
            return n

        def group(title, sensors):
            return {"id": next(ids), "Text": title, "Min": "", "Value": "", "Max": "", "ImageURL": "images_icon/x.png", "Children": sensors}

        def hw(name, hwid, groups):
            return {"id": next(ids), "Text": name, "Min": "", "Value": "", "Max": "", "HardwareId": hwid,
                    "ImageURL": "images_icon/x.png", "Children": [g for g in groups if g["Children"]]}

        hws = []
        na = self.noadmin
        load = max(0.0, min(100.0, s["cpu_l"] + j(1.0)))
        clk = 3600 + 1200 * (load / 100)
        if self.cpu == "amd":
            hid, name = "/amdcpu/0", "AMD Ryzen 7 5800X3D 8-Core Processor"
            layout = [(c, 2) for c in range(8)]
            core = lambda c: "CPU Core #%d" % (c + 1)
            temps = [] if na else [sensor(hid, "Core (Tctl/Tdie)", "Temperature", 2, s["cpu_t"]), sensor(hid, "CCD1 (Tdie)", "Temperature", 3, s["cpu_t"] - 6)]
            clocks = [] if na else [sensor(hid, "Bus Speed", "Clock", 0, 100.0), sensor(hid, "Cores (Average)", "Clock", 1, clk)]
            if not na:
                for c in range(8):
                    clocks.append(sensor(hid, "Core #%d" % (c + 1), "Clock", 3 + c, clk + j(150)))
            power = [] if na else [sensor(hid, "Package", "Power", 0, 28 + load)]
        elif self.cpu == "intel":
            hid, name = "/intelcpu/0", "13th Gen Intel(R) Core(TM) i7-13700K"
            layout = [(c, 2) for c in range(8)] + [(c, 1) for c in range(8, 16)]
            names = ["P-Core #%d" % (i + 1) for i in range(8)] + ["E-Core #%d" % (i + 1) for i in range(8)]
            core = lambda c: names[c]
            temps, clocks = [], []
            if not na:
                temps = [sensor(hid, names[c], "Temperature", c, s["cpu_t"] - 5) for c in range(16)]
                temps.append(sensor(hid, "CPU Package", "Temperature", 16, s["cpu_t"]))
                temps.append(sensor(hid, "P-Core #1 Distance to TjMax", "Temperature", 17, 100 - s["cpu_t"]))
                clocks = [sensor(hid, "Bus Speed", "Clock", 0, 100.0)] + [sensor(hid, names[c], "Clock", c + 1, clk) for c in range(16)]
            power = [] if na else [sensor(hid, "CPU Package", "Power", 0, 20 + load * 2)]
        elif self.cpu == "old":
            hid, name = "/amdcpu/0", "AMD FX-8350"
            layout = [(c, 1) for c in range(8)]
            core = lambda c: "CPU Core #%d" % (c + 1)
            temps = [sensor(hid, "CPU Cores", "Temperature", 0, s["cpu_t"])]
            clocks = [sensor(hid, core(c), "Clock", c + 1, clk) for c in range(8)]
            power = []
        else:
            hid = None
        if hid:
            loads = [sensor(hid, "CPU Total", "Load", 0, load), sensor(hid, "CPU Core Max", "Load", 1, min(100, load + 20))]
            th = 0
            for c, n in layout:
                for k in range(n):
                    loads.append(sensor(hid, core(c) + (" Thread #%d" % (k + 1) if n > 1 else ""), "Load", th + 2, load))
                    th += 1
            hws.append(hw(name, hid, [group("Powers", power), group("Clocks", clocks), group("Temperatures", temps), group("Load", loads)]))

        used = 11.3
        hws.append(hw("Total Memory", "/ram", [group("Load", [sensor("/ram", "Memory", "Load", 0, used / 31.9 * 100)]),
                                              group("Data", [sensor("/ram", "Memory Used", "Data", 0, self._gb(used)),
                                                             sensor("/ram", "Memory Available", "Data", 1, self._gb(31.9 - used))])]))

        gl = max(0.0, min(100.0, s["gpu_l"] + j(0.5)))
        ig = "/gpu-intel-integrated/1"
        igpu = hw("Intel(R) UHD Graphics 770", ig, [group("Load", [sensor(ig, "D3D 3D", "Load", 0, 1.0)]),
                                                    group("Powers", [sensor(ig, "GPU Power", "Power", 0, 0.4)])])
        if self.gpu == "igpu" or (self.cpu == "intel" and self.gpu != "none"):
            hws.append(igpu)        # listed before the discrete card, like the real thing
        if self.gpu == "nvidia":
            g = "/gpu-nvidia/0"
            hws.append(hw("NVIDIA GeForce RTX 4070 SUPER", g, [
                group("Powers", [sensor(g, "GPU Package", "Power", 0, 18 + gl * 2)]),
                group("Clocks", [sensor(g, "GPU Core", "Clock", 0, 210 + gl * 25), sensor(g, "GPU Memory", "Clock", 4, 405 + gl * 100)]),
                group("Temperatures", [sensor(g, "GPU Core", "Temperature", 0, s["gpu_t"]), sensor(g, "GPU Hot Spot", "Temperature", 2, s["gpu_t"] + 11)]),
                group("Load", [sensor(g, "GPU Core", "Load", 0, gl), sensor(g, "GPU Memory", "Load", 3, 38.0)]),
                group("Fans", [sensor(g, "GPU Fan 1", "Fan", 1, 0 if s["gpu_t"] < 50 else 900.0)]),
                group("Data", [sensor(g, "GPU Memory Used", "SmallData", 1, self._mb(3100)), sensor(g, "GPU Memory Total", "SmallData", 2, self._mb(12282))])]))
        elif self.gpu == "amd":
            g = "/gpu-amd/0"
            hws.append(hw("AMD Radeon RX 7800 XT", g, [
                group("Powers", [sensor(g, "GPU Package", "Power", 3, 22 + gl * 2)]),
                group("Clocks", [sensor(g, "GPU Core", "Clock", 0, 60 + gl * 23), sensor(g, "GPU Memory", "Clock", 2, 2474)]),
                group("Temperatures", [sensor(g, "GPU Core", "Temperature", 0, s["gpu_t"])]),
                group("Load", [sensor(g, "GPU Core", "Load", 0, gl)]),
                group("Fans", [sensor(g, "GPU Fan", "Fan", 0, 950.0)]),
                group("Data", [sensor(g, "GPU Memory Used", "SmallData", 0, self._mb(4200)), sensor(g, "GPU Memory Free", "SmallData", 1, self._mb(12184))])]))

        return {"id": 0, "Text": "Sensor", "Min": "Min", "Value": "Value", "Max": "Max", "ImageURL": "",
                "Children": [{"id": next(ids), "Text": "TESTPC", "Min": "", "Value": "", "Max": "", "ImageURL": "images_icon/computer.png", "Children": hws}]}

    # ------------------------------------------------------------ http
    def _handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body, ctype):
                self.send_response(code)
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                path = self.path.split("?")[0]
                if path == "/monitor.html":
                    return self._send(200, PAGE.read_bytes(), "text/html; charset=utf-8")
                if path == "/data.json":
                    fake.requests += 1
                    if fake.delay:
                        time.sleep(fake.delay)
                    if fake.status != 200:
                        return self._send(fake.status, b"", "text/plain")
                    if fake.body is not None:
                        return self._send(200, fake.body.encode(), "application/json")
                    return self._send(200, json.dumps(fake.build(), ensure_ascii=False).encode("utf-8"), "application/json")
                self._send(404, b"", "text/plain")

        return Handler
