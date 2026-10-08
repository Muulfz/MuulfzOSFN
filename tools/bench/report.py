"""Build benchmarks/report/index.html from tests/vm/bench-compare.ps1 results (stdlib only).

  python tools/bench/report.py                      # reads benchmarks/vm-compare2/*.json
  python tools/bench/report.py --dir benchmarks/vm-compare
  python tools/bench/report.py --selftest

One section per Windows release (26H2, 25H2). Per release: a scoreboard (every config vs
that release's stock install, with verdict), then per metric a small horizontal bar chart
(mean of N boots, min-max whisker, value label on every bar) with a data table.
"""
from __future__ import annotations

import html
import json
import pathlib
import statistics
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
# Color follows the entity in both releases: MuulfzOSFN slot 1, stock 2, VBS 3, Atlas 4, perf options 5
# (validated light + dark in display order; magenta must not sit next to orange).
CONFIGS = {
    "muulfzosfn-perf": ("v5 + opções de performance", 5),
    "muulfzosfn": ("MuulfzOSFN v5", 1),
    "stock": ("26H2 de fábrica", 2),
    "stock-vbs": ("26H2 + Memory Integrity (VBS)", 3),
    "25h2-muulfzosfn": ("MuulfzOSFN v5", 1),
    "25h2-stock": ("25H2 de fábrica", 2),
    "25h2-atlas": ("AtlasOS 0.5 (padrão)", 4),
}
# (key, title, base config, configs in display order)
SETS = [
    ("25h2", "Windows 11 25H2 (build 26200) · a versão que a maioria usa", "25h2-stock", ["25h2-muulfzosfn", "25h2-atlas", "25h2-stock"]),
    ("26h2", "Windows 11 26H2 (build 26300) · a mais nova", "stock", ["muulfzosfn-perf", "muulfzosfn", "stock", "stock-vbs"]),
]
GAME = "Jogo · Unigine Heaven 4.0 DX11, 1280×720 low, GPU-P (partição da RTX 5080)"
IDLE = "Sistema em repouso (5 min após o login)"
UDP = "Rede sob carga · tráfego UDP estilo endgame (host → VM, pacotes de 1000 B) + ping UDP a 60 Hz"
NET = "Rede na VM (placa virtual: os ajustes de placa não se aplicam aqui)"
# (section, key path, label, unit, lower_is_better)
METRICS = [
    (GAME, ("g", "AvgFps"), "FPS médio", "fps", False),
    (GAME, ("g", "Low1PctFps"), "1% low", "fps", False),
    (GAME, ("g", "FrameTimeP99Ms"), "Frame time p99", "ms", True),
    (GAME, ("g", "FrameTimeSdMs"), "Oscilação do frame time (desvio padrão)", "ms", True),
    (UDP, ("u", "0", "RttP99Ms"), "Ping p99 sem carga", "ms", True),
    (UDP, ("u", "600", "RttP99Ms"), "Ping p99 · endgame pesado (600 pacotes/s)", "ms", True),
    (UDP, ("u", "600", "JitterMs"), "Jitter · endgame pesado", "ms", True),
    (UDP, ("u", "600", "CpuPct"), "CPU · endgame pesado", "%", True),
    (UDP, ("u", "40000", "RttP99Ms"), "Ping p99 · enxurrada tipo download (40 mil/s)", "ms", True),
    (UDP, ("u", "40000", "CpuPct"), "CPU · enxurrada (40 mil/s)", "%", True),
    (UDP, ("u", "40000", "MaxCoreDpcPct"), "DPC de rede no núcleo mais carregado · enxurrada", "%", True),
    (UDP, ("u", "40000", "LossPct"), "Pacotes perdidos · enxurrada", "%", True),
    (IDLE, ("idle", "Processes"), "Processos", "", True),
    (IDLE, ("idle", "RamUsedMB"), "RAM em uso", "MB", True),
    (IDLE, ("idle", "ServicesRunning"), "Serviços em execução", "", True),
    (IDLE, ("idle", "Threads"), "Threads", "", True),
    (IDLE, ("idle", "AppxPackages"), "Apps (pacotes Appx)", "", True),
    (IDLE, ("idle", "CpuBusyPct"), "CPU ocupada em repouso", "%", True),
    (IDLE, ("idle", "IdleNetKB"), "Tráfego de fundo em 60 s", "KB", True),
    ("Boot", ("idle", "BootTimeMs"), "Boot total (Windows)", "ms", True),
    ("Boot", ("idle", "BootMainPathMs"), "Boot até o desktop (main path)", "ms", True),
    ("CPU (7-Zip benchmark)", ("bench", "cpu", "sevenzip_mips_mt"), "Multi-thread", "MIPS", False),
    ("CPU (7-Zip benchmark)", ("bench", "cpu", "sevenzip_mips_1t"), "Single-thread", "MIPS", False),
    (NET, ("bench", "net_idle", "ping-eu.ds.on.epicgames.com", "p50"), "Ping Fortnite EU (p50)", "ms", True),
    (NET, ("bench", "net_idle", "ping-eu.ds.on.epicgames.com", "jitter"), "Jitter Fortnite EU", "ms", True),
    (NET, ("bench", "bufferbloat", "down", "added_p95_ms"), "Latência extra com download", "ms", True),
]
SCOREBOARD = ["FPS médio", "1% low", "Frame time p99", "CPU · enxurrada (40 mil/s)", "Ping p99 · endgame pesado (600 pacotes/s)", "Processos", "RAM em uso", "Serviços em execução",
              "Apps (pacotes Appx)", "CPU ocupada em repouso", "Tráfego de fundo em 60 s", "Boot até o desktop (main path)", "Multi-thread"]

NOTES = {
    GAME: "Mesmo motor gráfico, mesma cena e resolução em todas as VMs, 3 medições por boot (PresentMon). "
          "A GPU é uma partição da RTX 5080 do host: mostra se o Windows atrapalha o jogo, não o FPS que você terá no PC. "
          "O Fortnite em si não roda em VM (o anti-cheat bloqueia).",
    UDP: "Um endgame pesado do Fortnite é algo como 30 a 600 pacotes/s (servidor a 30 Hz). Mede quanto de CPU o caminho de rede do Windows "
         "gasta, se o trabalho se acumula num núcleo só e quanto o ping piora; 40 mil/s simula um download pesado ao mesmo tempo. "
         "Passa pela placa virtual da VM, não pela física.",
    "CPU (7-Zip benchmark)": "1 rodada por boot; oscila cerca de 7% entre boots no mesmo host, então diferenças menores que isso são ruído.",
    NET: "As VMs foram medidas em horários diferentes, pela mesma rede de casa e pelo NAT do Hyper-V. "
         "Diferenças aqui são variação de horário, não efeito do playbook: a placa virtual não tem EEE, Green Ethernet nem as outras opções que ele ajusta.",
}


def dig(d, path):
    for k in path:
        if d is None:
            return None
        d = d.get(k)
    return d


def load(folder: pathlib.Path) -> dict[str, list[dict]]:
    runs: dict[str, list[dict]] = {}
    for f in sorted(folder.glob("*.json")):
        r = json.loads(f.read_text(encoding="utf-8-sig"))
        if "config" in r:
            runs.setdefault(r["config"], []).append(prep(r))
    return runs


def prep(r: dict) -> dict:
    """Derived fields: idle network total, per-boot mean of the game runs."""
    idle = r.get("idle") or {}
    if idle.get("IdleNetRecvKB") is not None:
        idle["IdleNetKB"] = round(idle["IdleNetRecvKB"] + idle["IdleNetSentKB"], 1)
    udp = r.get("udp") or []
    r["u"] = {str(x["Pps"]): x for x in ([udp] if isinstance(udp, dict) else udp)}
    games = r.get("game") or []
    games = [games] if isinstance(games, dict) else games      # ConvertTo-Json unwraps 1-item arrays
    r["g"] = {k: statistics.fmean(g[k] for g in games) for k in ("AvgFps", "Low1PctFps", "FrameTimeP99Ms", "FrameTimeSdMs")} if games else None
    return r


def summarize(vals: list) -> dict | None:
    vals = [float(v) for v in vals if v is not None]
    if not vals:
        return None
    return {"mean": statistics.fmean(vals), "min": min(vals), "max": max(vals), "n": len(vals), "vals": vals}


def verdict(base: dict, new: dict, lower_better: bool) -> tuple[str, float]:
    """'better' / 'worse' / 'same' / 'noisy'. 'same' under 3%; 'noisy' inside run-to-run spread."""
    d = (new["mean"] - base["mean"]) / base["mean"] * 100 if base["mean"] else 0.0
    spread = max(base["max"] - base["min"], new["max"] - new["min"]) / base["mean"] * 100 if base["mean"] else 0.0
    if abs(d) < 3.0:
        return "same", d
    if abs(d) < spread:
        return "noisy", d
    improved = d < 0 if lower_better else d > 0
    return ("better" if improved else "worse"), d


def fmt(v: float, unit: str) -> str:
    if abs(v) >= 100 or abs(v - round(v)) < 0.05 and unit not in ("ms", "%", "fps"):
        s = f"{v:,.0f}"
    else:
        s = f"{v:,.1f}" if abs(v) >= 10 else f"{v:,.2f}"
    return f"{s} {unit}".strip()


def rounded(x0: float, y: float, w: float, h: float, r: float = 4) -> str:
    """Bar with square baseline end and 4px rounded data end."""
    r = min(r, w / 2, h / 2)
    return (f"M{x0:.1f},{y} H{x0 + w - r:.1f} Q{x0 + w:.1f},{y} {x0 + w:.1f},{y + r} "
            f"V{y + h - r} Q{x0 + w:.1f},{y + h} {x0 + w - r:.1f},{y + h} H{x0:.1f} Z")


def bar_chart(label: str, unit: str, rows: list[tuple[str, dict]]) -> str:
    W, left, right, bh, gap, top = 520, 210, 92, 22, 14, 6
    vmax = max(s["max"] for _, s in rows) * 1.02 or 1
    x = lambda v: left + (W - left - right) * v / vmax
    h = top + len(rows) * (bh + gap)
    out = [f'<svg viewBox="0 0 {W} {h}" role="img" aria-label="{html.escape(label)}">',
           f'<line x1="{left}" y1="0" x2="{left}" y2="{h - gap / 2}" class="axis"/>']
    for i, (k, s) in enumerate(rows):
        name, slot = CONFIGS[k]
        y = top + i * (bh + gap)
        tip = html.escape(f"{name}: média {fmt(s['mean'], unit)} · min {fmt(s['min'], unit)} · máx {fmt(s['max'], unit)} · {s['n']} boots")
        out.append(f'<text x="{left - 10}" y="{y + bh / 2 + 4}" class="cat" text-anchor="end">{html.escape(name)}</text>')
        w = max(x(s["mean"]) - left, 1)
        out.append(f'<path class="m s{slot}" d="{rounded(left, y, w, bh)}" data-tip="{tip}"/>')
        if s["n"] > 1:
            xa, xb, yc = x(s["min"]), x(s["max"]), y + bh / 2
            out.append(f'<line class="whisker" x1="{xa:.1f}" y1="{yc}" x2="{xb:.1f}" y2="{yc}"/>'
                       f'<line class="whisker" x1="{xa:.1f}" y1="{yc - 5}" x2="{xa:.1f}" y2="{yc + 5}"/>'
                       f'<line class="whisker" x1="{xb:.1f}" y1="{yc - 5}" x2="{xb:.1f}" y2="{yc + 5}"/>')
        out.append(f'<text x="{max(x(s["max"]), left + w) + 8:.1f}" y="{y + bh / 2 + 4}" class="val">{fmt(s["mean"], unit)}</text>')
    out.append("</svg>")
    return "".join(out)


WORD = {"better": ("melhor", "good", "▲"), "worse": ("pior", "bad", "▼"), "same": ("igual", "same", "="), "noisy": ("dentro da variação", "same", "≈")}


def build_set(runs: dict, title: str, base: str, cfgs: list[str]) -> str:
    cfgs = [k for k in cfgs if runs.get(k)]
    if not cfgs:
        return ""
    stats = {m[2]: {k: summarize([dig(r, m[1]) for r in runs[k]]) for k in cfgs} for m in METRICS}

    # Scoreboard: every non-base config vs stock of the same release.
    others = [k for k in cfgs if k != base]
    head = f"<tr><th>métrica</th><th>{html.escape(CONFIGS[base][0])}</th>" + "".join(f"<th>{html.escape(CONFIGS[k][0])}</th>" for k in others) + "</tr>"
    body = []
    for m in METRICS:
        if m[2] not in SCOREBOARD or not stats[m[2]].get(base):
            continue
        st, unit, b = stats[m[2]], m[3], stats[m[2]][base]
        cells = []
        for k in others:
            if not st.get(k):
                cells.append("<td class='muted'>—</td>")
                continue
            v, d = verdict(b, st[k], m[4])
            w, cls, icon = WORD[v]
            cells.append(f"<td><b>{fmt(st[k]['mean'], unit)}</b> <span class='td {cls}'>{icon} {d:+.1f}% {w}</span></td>")
        better = "↓ melhor" if m[4] else "↑ melhor"
        body.append(f"<tr><td>{html.escape(m[2])} <span class='muted'>{better}</span></td><td>{fmt(b['mean'], unit)}</td>{''.join(cells)}</tr>")
    score = f'<table class="score">{head}{"".join(body)}</table>'

    sections: dict[str, list[str]] = {}
    for section, path, label, unit, lower in METRICS:
        rows = [(k, stats[label][k]) for k in cfgs if stats[label].get(k)]
        if not rows:
            continue
        table = "".join(f"<tr><td>{html.escape(CONFIGS[k][0])}</td><td>{' · '.join(fmt(v, unit) for v in s['vals'])}</td><td><b>{fmt(s['mean'], unit)}</b></td></tr>" for k, s in rows)
        better = "menor é melhor" if lower else "maior é melhor"
        sections.setdefault(section, []).append(
            f'<figure><figcaption>{html.escape(label)} <span class="muted">· {better}</span></figcaption>{bar_chart(label, unit, rows)}'
            f'<details><summary>tabela</summary><table><tr><th>config</th><th>por boot</th><th>média</th></tr>{table}</table></details></figure>')
    parts = [f'<section><h3>{html.escape(s)}</h3>{f"<p>{NOTES[s]}</p>" if s in NOTES else ""}<div class="grid">{"".join(c)}</div></section>' for s, c in sections.items()]
    legend = "".join(f'<span class="key"><i class="sw s{CONFIGS[k][1]}"></i>{html.escape(CONFIGS[k][0])} <span class="muted">({len(runs[k])} boots)</span></span>' for k in cfgs)
    return f'<h2>{html.escape(title)}</h2><div class="legend">{legend}</div>{score}{"".join(parts)}'


def build(runs: dict[str, list[dict]], host: dict | None) -> str:
    body = "".join(build_set(runs, t, b, c) for _, t, b, c in SETS)
    host_html = ""
    if host:
        n, bb = host.get("net_idle", {}), host.get("bufferbloat", {})
        eu = n.get("ping-eu.ds.on.epicgames.com", {})
        cells = [("Gateway", n.get("gateway", {}).get("p50"), "ms"), ("Fortnite EU p50", eu.get("p50"), "ms"), ("Fortnite EU p99", eu.get("p99"), "ms"),
                 ("Jitter EU", eu.get("jitter"), "ms"), ("Extra c/ download", bb.get("down", {}).get("added_p95_ms"), "ms"), ("Extra c/ upload", bb.get("up", {}).get("added_p95_ms"), "ms")]
        host_html = ('<h2>Rede real do seu PC (baseline, sem playbook aplicado)</h2><div class="kpis">' +
                     "".join(f'<div class="tile"><div class="tl">{l}</div><div class="tv">{fmt(v, u)}</div></div>' for l, v, u in cells if v is not None) +
                     '</div><p class="muted">Referência para comparar depois num PC físico com a ISO. Os ajustes de placa de rede só têm efeito em hardware real.</p>')
    return TEMPLATE.format(body=body, host=host_html)


TEMPLATE = """<!doctype html><html lang="pt"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>MuulfzOSFN v5 - benchmark</title>
<style>
.viz-root{{color-scheme:light;--surface:#fcfcfb;--page:#f9f9f7;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;
--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--s4:#eda100;--s5:#e87ba4;--good:#006300;--bad:#d03b3b;--ring:rgba(11,11,11,.10)}}
@media (prefers-color-scheme:dark){{.viz-root{{color-scheme:dark;--surface:#1a1a19;--page:#0d0d0d;--ink:#fff;--ink2:#c3c2b7;--muted:#898781;--grid:#2c2c2a;--axis:#383835;
--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500;--s5:#d55181;--good:#0ca30c;--bad:#e66767;--ring:rgba(255,255,255,.10)}}}}
body{{margin:0;background:var(--page)}} .viz-root{{font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;color:var(--ink);background:var(--page);padding:28px;max-width:1180px;margin:auto}}
h1{{font-size:22px;margin:0 0 4px}} h2{{font-size:19px;margin:40px 0 6px;padding-top:18px;border-top:1px solid var(--grid)}} h3{{font-size:15px;margin:26px 0 8px}}
.muted{{color:var(--muted)}} p{{color:var(--ink2)}}
.legend{{display:flex;flex-wrap:wrap;gap:18px;margin:10px 0 12px;color:var(--ink2)}} .key{{display:flex;align-items:center;gap:6px}}
.sw{{width:12px;height:12px;border-radius:3px;display:inline-block}}
.sw.s1,.m.s1{{background:var(--s1);fill:var(--s1)}} .sw.s2,.m.s2{{background:var(--s2);fill:var(--s2)}} .sw.s3,.m.s3{{background:var(--s3);fill:var(--s3)}} .sw.s4,.m.s4{{background:var(--s4);fill:var(--s4)}} .sw.s5,.m.s5{{background:var(--s5);fill:var(--s5)}}
.kpis{{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px}}
.tile{{background:var(--surface);border-radius:10px;padding:14px 16px;box-shadow:0 0 0 1px var(--ring)}} .tl{{color:var(--ink2);font-size:13px}} .tv{{font-size:24px;font-weight:600;margin:2px 0}}
.td{{font-size:12px;white-space:nowrap}} .td.good{{color:var(--good)}} .td.bad{{color:var(--bad)}} .td.same{{color:var(--ink2)}}
table.score{{background:var(--surface);border-radius:10px;box-shadow:0 0 0 1px var(--ring);padding:8px 14px;width:100%}} table.score td,table.score th{{padding:6px 14px 6px 0}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(520px,1fr));gap:12px}}
figure{{margin:0;background:var(--surface);border-radius:10px;padding:14px 16px 10px;box-shadow:0 0 0 1px var(--ring)}}
figcaption{{font-weight:600;margin-bottom:8px}} svg{{width:100%;height:auto;display:block}}
.axis{{stroke:var(--axis);stroke-width:1}} .whisker{{stroke:var(--ink2);stroke-width:1.5}} .cat{{fill:var(--ink2);font-size:12px}} .val{{fill:var(--ink);font-size:12px;font-variant-numeric:tabular-nums}}
.m{{cursor:default}} .m:hover{{opacity:.85}}
details{{margin-top:6px;color:var(--ink2);font-size:12px}} table{{border-collapse:collapse;margin-top:6px;font-variant-numeric:tabular-nums}}
td,th{{padding:3px 10px 3px 0;text-align:left;border-bottom:1px solid var(--grid)}}
#tip{{position:fixed;pointer-events:none;background:var(--surface);color:var(--ink);box-shadow:0 0 0 1px var(--ring),0 4px 14px rgba(0,0,0,.15);border-radius:8px;padding:6px 10px;font-size:12px;display:none;max-width:320px}}
</style>
<body><div class="viz-root">
<h1>MuulfzOSFN v5 vs Windows de fábrica vs AtlasOS</h1>
<p>VMs Hyper-V idênticas (8 vCPU, 16 GB, mesmo host), uma de cada vez, Windows Update pausado em todas.
Cada configuração: 3 boots limpos, medição 5 min após o login, depois benchmark de CPU/rede, estresse UDP e 3 rodadas do jogo.
Barras = média; traço = mínimo-máximo entre boots. "Dentro da variação" = diferença menor que a oscilação entre boots.</p>
{body}
{host}
<p class="muted">Limites honestos: a VM usa uma partição da GPU e placa de rede virtual, e o anti-cheat do Fortnite bloqueia VMs.
FPS real do Fortnite e latência de rede real só no PC físico (tools/bench/run.py + sysbench.ps1).</p>
<div id="tip"></div></div>
<script>
const tip=document.getElementById('tip');
document.querySelectorAll('[data-tip]').forEach(el=>{{
 el.addEventListener('mousemove',e=>{{tip.textContent=el.dataset.tip;tip.style.display='block';tip.style.left=(e.clientX+14)+'px';tip.style.top=(e.clientY+14)+'px'}});
 el.addEventListener('mouseleave',()=>tip.style.display='none');}});
</script></body></html>"""


def selftest() -> None:
    s = summarize([10, 12, 11])
    assert s["mean"] == 11 and s["min"] == 10 and s["max"] == 12
    assert verdict({"mean": 100, "min": 99, "max": 101}, {"mean": 80, "min": 79, "max": 81}, True)[0] == "better"
    assert verdict({"mean": 100, "min": 90, "max": 110}, {"mean": 95, "min": 90, "max": 100}, True)[0] == "noisy"  # 5% but inside spread
    assert verdict({"mean": 100, "min": 99, "max": 101}, {"mean": 98, "min": 97, "max": 99}, True)[0] == "same"     # < 3%
    assert verdict({"mean": 100, "min": 99, "max": 101}, {"mean": 120, "min": 119, "max": 121}, False)[0] == "better"
    assert verdict({"mean": 100, "min": 99, "max": 101}, {"mean": 120, "min": 119, "max": 121}, True)[0] == "worse"
    g = {"AvgFps": 400, "Low1PctFps": 250, "FrameTimeP99Ms": 4, "FrameTimeSdMs": 1}
    run = lambda cfg, fps: prep({"config": cfg, "idle": {"Processes": 120}, "game": {**g, "AvgFps": fps},
                                 "udp": [{"Pps": 40000, "CpuPct": 20.0, "RttP99Ms": 1.0, "LossPct": 0, "MaxCoreDpcPct": 5, "JitterMs": 0.1}]})
    html_ = build({"25h2-stock": [run("25h2-stock", 400)], "25h2-atlas": [run("25h2-atlas", 440)]}, None)
    assert "AtlasOS" in html_ and "+10.0%" in html_ and "26H2 (build" not in html_ and "CPU · enxurrada" in html_  # 1-item game unwrapped; empty set skipped
    print("report selftest OK")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit()
    folder = REPO / (sys.argv[sys.argv.index("--dir") + 1] if "--dir" in sys.argv else "benchmarks/vm-compare2")
    runs = load(folder)
    hosts = sorted((REPO / "benchmarks" / "sys").glob("host-baseline-*.json"))
    host = json.loads(hosts[-1].read_text(encoding="utf-8-sig")) if hosts else None
    out = REPO / "benchmarks" / "report" / "index.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(build(runs, host), encoding="utf-8")
    print(f"wrote {out} ({sum(len(v) for v in runs.values())} runs from {folder.name})")
