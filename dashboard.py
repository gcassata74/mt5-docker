#!/usr/bin/env python3
"""
ScalpEngine v3 — P&L Dashboard
30-day graphical P&L history.
Run: python3 dashboard.py
Open: http://localhost:8888
"""

import json
import re
import subprocess
from datetime import date, timedelta
from http.server import BaseHTTPRequestHandler, HTTPServer

CONTAINER = "mt5-docker-mt5-1"
LOG_DIR   = "/config/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Logs"
PORT      = 8888
DAYS      = 30

EXIT_RE = re.compile(r'\[EXIT\].*profit: ([+-]?[\d.]+)')

_history: dict = {}  # date_iso -> {pnl, trades, wins} | None


def _read_log(d: date):
    path = f"{LOG_DIR}/{d.strftime('%Y%m%d')}.log"
    try:
        r = subprocess.run(
            ["docker", "exec", CONTAINER, "cat", path],
            capture_output=True, timeout=10
        )
        if r.returncode != 0:
            return None
        text = r.stdout.decode("utf-16-le", errors="ignore")
        lines = text.splitlines()
        if lines and lines[0].startswith('﻿'):
            lines[0] = lines[0][1:]
        return lines
    except Exception:
        return None


def _parse(lines):
    pnl, trades, wins = 0.0, 0, 0
    for line in lines:
        m = EXIT_RE.search(line)
        if m:
            v = float(m.group(1))
            pnl += v
            trades += 1
            if v > 0:
                wins += 1
    return round(pnl, 2), trades, wins


def _get_day(d: date, force: bool = False):
    dk = d.isoformat()
    if not force and dk in _history:
        return _history[dk]
    lines = _read_log(d)
    if lines is None:
        entry = None
    else:
        pnl, trades, wins = _parse(lines)
        entry = {"pnl": pnl, "trades": trades, "wins": wins}
    _history[dk] = entry
    return entry


def build_payload():
    today = date.today()
    out = []
    for i in range(DAYS - 1, -1, -1):
        d = today - timedelta(days=i)
        entry = _get_day(d, force=(i == 0))
        item = {
            "date": d.strftime("%d/%m"),
            "isoDate": d.isoformat(),
            "isToday": i == 0,
            "isWeekend": d.weekday() >= 5,
            "pnl": None,
            "trades": 0,
            "wins": 0,
        }
        if entry:
            item.update(entry)
        out.append(item)
    return out


HTML = """<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ScalpEngine v3 — P&L</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0f172a; color: #e2e8f0;
      font-family: 'Courier New', monospace;
      padding: 28px 32px;
    }
    header {
      display: flex; justify-content: space-between; align-items: baseline;
      margin-bottom: 24px;
    }
    h1 { font-size: 1.1rem; color: #94a3b8; }
    h1 strong { color: #f1f5f9; }
    #ts { font-size: 0.7rem; color: #475569; }

    .stats {
      display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px;
      margin-bottom: 24px;
    }
    .card {
      background: #1e293b; border-radius: 8px; padding: 14px 18px;
      border: 1px solid #1e3a5f;
    }
    .card-label {
      font-size: 0.65rem; color: #64748b;
      text-transform: uppercase; letter-spacing: .05em; margin-bottom: 6px;
    }
    .card-value { font-size: 1.5rem; font-weight: bold; }
    .pos { color: #22c55e; }
    .neg { color: #ef4444; }
    .neu { color: #94a3b8; }

    .chart-wrap {
      background: #1e293b; border-radius: 8px; padding: 20px 20px 12px;
      border: 1px solid #1e3a5f;
    }
    .chart-title {
      font-size: 0.65rem; color: #64748b;
      text-transform: uppercase; letter-spacing: .05em; margin-bottom: 14px;
    }
  </style>
</head>
<body>
  <header>
    <h1>ScalpEngine v3 — <strong>P&amp;L Dashboard</strong></h1>
    <span id="ts">caricamento...</span>
  </header>

  <div class="stats">
    <div class="card">
      <div class="card-label">P&amp;L Totale (30gg)</div>
      <div class="card-value neu" id="s-total">—</div>
    </div>
    <div class="card">
      <div class="card-label">Giorni positivi</div>
      <div class="card-value neu" id="s-wins">—</div>
    </div>
    <div class="card">
      <div class="card-label">Miglior giorno</div>
      <div class="card-value pos" id="s-best">—</div>
    </div>
    <div class="card">
      <div class="card-label">Peggior giorno</div>
      <div class="card-value neg" id="s-worst">—</div>
    </div>
  </div>

  <div class="chart-wrap">
    <div class="chart-title">P&amp;L giornaliero — ultimi 30 giorni</div>
    <canvas id="chart" height="70"></canvas>
  </div>

  <script>
    let chart = null;

    function fmt(v) {
      if (v === null || v === undefined) return '—';
      return (v >= 0 ? '+' : '') + v.toFixed(2) + ' €';
    }

    function colorOf(d) {
      if (d.pnl === null) return 'rgba(51,65,85,0.35)';
      const alpha = d.isToday ? '1.0' : '0.75';
      return d.pnl >= 0
        ? 'rgba(34,197,94,' + alpha + ')'
        : 'rgba(239,68,68,' + alpha + ')';
    }

    function render(data) {
      const labels  = data.map(d => d.date);
      const values  = data.map(d => d.pnl !== null ? d.pnl : 0);
      const bg      = data.map(colorOf);
      const borders = data.map(d => d.isToday ? '#f1f5f9' : 'transparent');
      const bwidths = data.map(d => d.isToday ? 2 : 0);

      const ds = {
        label: 'P&L €',
        data: values,
        backgroundColor: bg,
        borderColor: borders,
        borderWidth: bwidths,
        borderRadius: 4,
      };

      if (chart) {
        chart.data.labels   = labels;
        chart.data.datasets = [ds];
        chart.update('none');
      } else {
        chart = new Chart(document.getElementById('chart'), {
          type: 'bar',
          data: { labels, datasets: [ds] },
          options: {
            responsive: true,
            animation: false,
            plugins: {
              legend: { display: false },
              tooltip: {
                callbacks: {
                  title: items => {
                    const d = data[items[0].dataIndex];
                    return d.date + (d.isToday ? ' (oggi)' : '');
                  },
                  label: ctx => {
                    const d = data[ctx.dataIndex];
                    if (d.pnl === null) return ' Nessun dato';
                    const wr = d.trades
                      ? '  ' + d.wins + '/' + d.trades + ' trade vincenti'
                      : '  (nessun trade chiuso)';
                    return [' P&L: ' + fmt(d.pnl), wr];
                  }
                }
              }
            },
            scales: {
              x: {
                grid: { color: 'rgba(51,65,85,0.4)', drawTicks: false },
                ticks: { color: '#64748b', font: { size: 10 }, maxRotation: 45 }
              },
              y: {
                grid: { color: 'rgba(51,65,85,0.4)', drawTicks: false },
                ticks: {
                  color: '#64748b', font: { size: 11 },
                  callback: v => (v >= 0 ? '+' : '') + v + '€'
                }
              }
            }
          }
        });
      }

      // Stats
      const active = data.filter(d => d.pnl !== null && d.trades > 0);
      const total  = active.reduce((s, d) => s + d.pnl, 0);
      const wins   = active.filter(d => d.pnl > 0).length;
      const best   = active.length ? Math.max.apply(null, active.map(d => d.pnl)) : null;
      const worst  = active.length ? Math.min.apply(null, active.map(d => d.pnl)) : null;

      const el = id => document.getElementById(id);
      el('s-total').textContent = fmt(total);
      el('s-total').className = 'card-value ' + (total > 0 ? 'pos' : total < 0 ? 'neg' : 'neu');
      el('s-wins').textContent  = active.length ? wins + ' / ' + active.length : '—';
      el('s-best').textContent  = best !== null ? fmt(best) : '—';
      el('s-worst').textContent = worst !== null ? fmt(worst) : '—';
      el('ts').textContent = 'aggiornato: ' + new Date().toLocaleTimeString('it-IT');
    }

    async function refresh() {
      try {
        const r    = await fetch('/api/data');
        const data = await r.json();
        render(data);
      } catch(e) {
        document.getElementById('ts').textContent = 'errore connessione';
      }
    }

    refresh();
    setInterval(refresh, 60000);
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _send(self, code, ctype, body):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", len(b))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, "text/html; charset=utf-8", HTML)
        elif self.path == "/api/data":
            self._send(200, "application/json", json.dumps(build_payload()))
        else:
            self._send(404, "text/plain", "Not found")


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"ScalpEngine P&L Dashboard → http://localhost:{PORT}")
    print("Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
