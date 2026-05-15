# MT5 Trend Scalper Toolkit

A lightweight MetaTrader 5 toolkit that pairs a trend-finding indicator with a
fully automated scalping EA. Everything is native MQL5, source-only — drop the
two `.mq5` files into your MetaTrader 5 install, press F7 in MetaEditor and
you're ready to attach.

```
MQL5/
├── Indicators/
│   ├── TrendScalperPro.mq5      # auto trend-line indicator with alerts + EA buffers
│   └── TrendScalperPro.ex5      # pre-compiled binary (0 errors / 0 warnings)
└── Experts/
    ├── TrendScalperEA.mq5       # scalping EA that consumes the indicator
    └── TrendScalperEA.ex5       # pre-compiled binary (0 errors / 0 warnings)
docs/
├── TrendScalperPro.compile.log
└── TrendScalperEA.compile.log
```

---

## 1. What it does

### `TrendScalperPro` (indicator)

1. Detects swing highs / swing lows with a configurable depth (Bill-Williams
   style pivot logic, **5 bars left + 5 bars right** by default).
2. Connects the **last two confirmed pivots on each side** into:
   - an **up support line** (lime, drawn through the two latest swing lows)
   - a **down resistance line** (red, drawn through the two latest swing highs)
3. Confirms a **trend flip** when price closes through the opposing line **and**
   is on the right side of an EMA bias filter, with an ATR threshold to mute
   noise.
4. Prints **arrows on every flip bar**, lights up a small dashboard, and fires
   **popup + push + email + sound alerts** (each independently toggleable).
5. Exposes **5 buffers** so an EA can read every signal without parsing the
   chart:

   | Buffer | Name             | Meaning                                          |
   |-------:|------------------|--------------------------------------------------|
   |   0    | `UpTrendLine`    | Projected price of the lime support line         |
   |   1    | `DownTrendLine`  | Projected price of the red resistance line       |
   |   2    | `BuySignal`      | Non-zero price on the bar where trend flipped UP |
   |   3    | `SellSignal`     | Non-zero price on the bar where trend flipped DN |
   |   4    | `TrendDirection` | `+1` up, `-1` down, `0` not yet established      |

### `TrendScalperEA` (expert advisor)

1. Loads the indicator via `iCustom` and reads buffers 2/3/4 on the **last
   closed bar** (no intra-bar repaint).
2. On a fresh flip, opens **one** market order with:
   - ATR-based **stop-loss** (`SL = ATR × SL_ATRmult`)
   - ATR-based **take-profit** (`TP = ATR × TP_ATRmult`)
   - Optional **breakeven move** once price has travelled
     `BE_ATRmult × ATR` in profit (+ small lock-in offset).
   - Optional **ATR trailing stop** (`distance = ATR × Trail_ATRmult`).
3. Sizes the trade by **fixed lot** or **risk % of equity** clamped by
   `InpMaxLot` and the broker's volume step.
4. Refuses to trade when **any** of these gates are open:
   - spread > `InpMaxSpreadPoints`
   - outside the configured **session hours / weekdays**
   - inside a configured **news blackout window** (HH:MM list ± N minutes)
   - the **daily equity guard** has tripped (auto-flatten + freeze)
   - **daily trade cap** reached
   - **cooldown** since the last closed trade hasn't elapsed
5. All safety counters reset at the broker midnight.

---

## 2. Install

Pre-compiled `.ex5` binaries are included in the repo
(`0 errors, 0 warnings` — see `docs/*.compile.log` for the full MetaEditor
compiler output). You can either copy the binaries directly, or copy the
sources and recompile from your local MetaEditor.

**Fast path — drop in the compiled files:**

1. In MT5 click **File → Open Data Folder**.
2. Copy:
   - `MQL5/Indicators/TrendScalperPro.ex5` → `<data-folder>/MQL5/Indicators/`
   - `MQL5/Experts/TrendScalperEA.ex5`    → `<data-folder>/MQL5/Experts/`
3. In the terminal Navigator, right-click `Indicators` (and `Expert Advisors`)
   and choose **Refresh**. Both items now appear.

**Recompile from source (recommended if you want to tweak the code):**

1. Same as above, but copy the `.mq5` files instead of `.ex5`.
2. Open MetaEditor (F4 in the terminal). In the Navigator double-click each
   `.mq5` file and press **F7** (Compile). You should see
   `0 errors, 0 warnings` for both.
3. The fresh `.ex5` files land next to the sources and the Navigator picks
   them up automatically.

---

## 3. Quick start

### Run just the indicator

- Drag **TrendScalperPro** onto any chart (recommended: 5M / 15M on major
  FX pairs).
- Leave the inputs at defaults the first time. You should see:
  - a lime dotted line under the price (up support)
  - a red dotted line over the price (down resistance)
  - lime up-arrows / magenta down-arrows on flip bars
  - a small text dashboard in the upper-left corner

### Run the indicator + EA together

- Keep the indicator chart open (optional but recommended for visual feedback).
- Drag **TrendScalperEA** onto the same chart, **same timeframe**.
- In the EA inputs make sure the four indicator-related inputs at the top
  (`InpSwingDepth`, `InpEMAFilter`, `InpATRPeriod`, `InpATRMinMove`) match
  the values used on the chart-attached indicator. The EA loads its own
  silent copy via `iCustom` — if the parameters differ, the signals it reads
  will not match the ones you see drawn.
- Enable **Algo Trading** in the toolbar.

---

## 4. Inputs reference

### Indicator inputs

| Group       | Input               | Default      | Purpose                                                        |
|------------:|---------------------|--------------|----------------------------------------------------------------|
| Swing/trend | `InpSwingDepth`     | `5`          | Bars left & right required to confirm a pivot                  |
|             | `InpEMAFilter`      | `50`         | EMA used as bias filter (`0` = disabled)                       |
|             | `InpATRPeriod`      | `14`         | ATR window for the noise filter                                |
|             | `InpATRMinMove`     | `0.25`       | Min swing distance in ATR units (lower = more pivots)          |
|             | `InpExtendLines`    | `true`       | Project the OBJ_TREND lines to the right of the chart          |
|             | `InpMaxHistoryBars` | `1500`       | Bars to keep computed (perf cap; `0` = all)                    |
| Visuals     | `InpDrawObjects`    | `true`       | Show OBJ_TREND lines on the chart                              |
|             | `InpUpColor`        | `clrLime`    |                                                                |
|             | `InpDownColor`      | `clrRed`     |                                                                |
|             | `InpLineStyle`      | `STYLE_SOLID`|                                                                |
|             | `InpLineWidth`      | `2`          |                                                                |
|             | `InpShowDashboard`  | `true`       |                                                                |
| Alerts      | `InpAlertPopup`     | `true`       | `Alert()` popup on every confirmed flip                        |
|             | `InpAlertPush`      | `false`      | `SendNotification` (configure MetaQuotes ID in terminal)       |
|             | `InpAlertEmail`     | `false`      | `SendMail` (configure SMTP in terminal)                        |
|             | `InpAlertSound`     | `true`       | `PlaySound`                                                    |
|             | `InpAlertSoundFile` | `alert.wav`  |                                                                |

### EA inputs

| Group           | Input                  | Default        | Purpose                                                              |
|----------------:|------------------------|----------------|----------------------------------------------------------------------|
| Indicator       | `InpIndicatorName`     | `TrendScalperPro` | Source file name (no `.ex5`); use `folder\\name` for subfolders |
|                 | `InpSwingDepth`        | `5`            | Must match chart indicator                                           |
|                 | `InpEMAFilter`         | `50`           | Must match chart indicator                                           |
|                 | `InpATRPeriod`         | `14`           | Must match chart indicator                                           |
|                 | `InpATRMinMove`        | `0.25`         | Must match chart indicator                                           |
| Sizing          | `InpUseRiskPercent`    | `false`        | Risk % of equity on each trade (else fixed lot)                      |
|                 | `InpFixedLot`          | `0.01`         |                                                                      |
|                 | `InpRiskPercent`       | `0.5`          | Percentage of equity to risk per trade when risk-sizing is on        |
|                 | `InpMaxLot`            | `5.0`          | Hard cap                                                             |
|                 | `InpMaxOpenPositions`  | `1`            | Max concurrent positions on this symbol/magic                        |
| Stops & targets | `InpSL_ATRmult`        | `1.5`          | `SL = ATR × this`                                                    |
|                 | `InpTP_ATRmult`        | `2.0`          | `TP = ATR × this`                                                    |
|                 | `InpMinStopPoints`     | `80`           | Hard min SL/TP in *points*, also respects broker `STOPLEVEL`         |
|                 | `InpUseBreakeven`      | `true`         |                                                                      |
|                 | `InpBE_ATRmult`        | `1.0`          | Profit threshold (ATR units) before SL moves to BE                   |
|                 | `InpBE_OffsetPoints`   | `5`            | Points of profit locked when moving to BE                            |
|                 | `InpUseTrailing`       | `true`         |                                                                      |
|                 | `InpTrail_ATRmult`     | `1.0`          | Trailing distance in ATR units                                       |
| Execution       | `InpMagic`             | `20260515`     | EA magic                                                             |
|                 | `InpDeviationPoints`   | `10`           | Slippage allowance                                                   |
|                 | `InpMaxSpreadPoints`   | `30`           | Max acceptable spread in points (`0` = disabled)                     |
|                 | `InpTradeComment`      | `TrendScalperEA` |                                                                    |
| Session         | `InpUseSessionFilter`  | `true`         |                                                                      |
|                 | `InpStartHour`         | `7`            | Inclusive; `Start==End` means 24/7                                   |
|                 | `InpEndHour`           | `20`           | Exclusive; if `End < Start` window wraps past midnight               |
|                 | `InpTradeMonday..Sun`  | M-F on         |                                                                      |
| Safety          | `InpNewsPauseTimes`    | `""`           | Comma-sep `HH:MM` server times, e.g. `13:30,15:00`                   |
|                 | `InpNewsPauseMinutes`  | `30`           | Half-width of each blackout window                                   |
|                 | `InpEquityGuardOn`     | `true`         |                                                                      |
|                 | `InpEquityGuardPct`    | `5.0`          | Auto-flatten + freeze if equity drops this % from the day's start    |
|                 | `InpMaxTradesPerDay`   | `30`           | `0` = unlimited                                                      |
|                 | `InpCooldownMinutes`   | `3`            | Wait between successive trades                                       |

---

## 5. Recommended starting settings (FX majors)

| Pair      | Timeframe | SwingDepth | EMAFilter | ATRPeriod | ATRMinMove | SL×ATR | TP×ATR | MaxSpread |
|-----------|-----------|-----------:|----------:|----------:|-----------:|-------:|-------:|----------:|
| EURUSD    | M5        |     5      |    50     |    14     |    0.25    |  1.5   |  2.0   |    15     |
| GBPUSD    | M5        |     5      |    50     |    14     |    0.30    |  1.5   |  2.0   |    20     |
| USDJPY    | M5        |     5      |    50     |    14     |    0.25    |  1.5   |  2.0   |    15     |
| AUDUSD    | M5        |     5      |    50     |    14     |    0.25    |  1.5   |  2.0   |    18     |
| USDCAD    | M5        |     5      |    50     |    14     |    0.30    |  1.5   |  2.0   |    20     |
| XAUUSD    | M15       |     6      |    80     |    14     |    0.30    |  1.8   |  2.5   |   100     |

Start with `InpFixedLot = 0.01` on a demo and only switch to
`InpUseRiskPercent = true` once you have at least a 1-week stable equity curve.

---

## 6. Backtesting

1. Open the **Strategy Tester** (`Ctrl+R`).
2. Expert: `TrendScalperEA`.
3. Symbol + period: e.g. **EURUSD** + **M5**.
4. Date range: at least **3 months** to cover several volatility regimes.
5. Model: **Every tick based on real ticks** (most accurate). If you don't have
   tick history, use **1 minute OHLC** as a fast first pass.
6. Optimization: enable for inputs you actually want to tune
   (`InpSL_ATRmult`, `InpTP_ATRmult`, `InpATRMinMove`, `InpEMAFilter`).
7. **Disable optimization on safety inputs** (`InpEquityGuardPct`,
   `InpMaxTradesPerDay`) — those exist to bound risk, not to be curve-fitted.

Recommended reporting metrics:
- **Profit factor** (target > 1.3)
- **Recovery factor** (target > 3)
- **Maximum drawdown %** (target < 10% of starting equity)
- **Trades per day** (target 5–15 for a scalper on M5)

A working set of backtest defaults (EURUSD M5, 90 days, every-tick):

```
Initial deposit       : 10 000 USD
Fixed lot             : 0.01
Slippage              : 5 points
Spread                : current
Profit factor (target): 1.30+
Max drawdown (target) : < 8%
```

> **Note**: This repo intentionally does **not** ship any pre-generated
> backtest report. Performance is broker / spread / period dependent — always
> run the tester on **your** broker's history before going live.

---

## 7. Tweaking checklist

- **Too few signals**: lower `InpATRMinMove` (e.g. `0.15`), shrink
  `InpSwingDepth` to `3`.
- **Too many fake signals**: raise `InpATRMinMove` (e.g. `0.5`), raise
  `InpEMAFilter` to `100+`, or increase `InpSwingDepth` to `7`.
- **Stops getting hit too often**: bump `InpSL_ATRmult` to `2.0` and
  `InpMinStopPoints` to `120+`.
- **TPs never reached**: lower `InpTP_ATRmult` to `1.5`, enable trailing.
- **Bad fills around news**: populate `InpNewsPauseTimes` with the upcoming
  high-impact releases (broker server time) and keep
  `InpNewsPauseMinutes = 30`.
- **Drawdown days**: tighten `InpEquityGuardPct` to `3.0` and set
  `InpMaxTradesPerDay = 15`.

---

## 8. File-by-file reference

### `MQL5/Indicators/TrendScalperPro.mq5`

- Self-contained; no external dependencies.
- Uses `iATR` and `iMA` handles. Cleans up chart objects on `OnDeinit`.
- Buffer 4 (`TrendDirection`) is `INDICATOR_CALCULATIONS` — not plotted, but
  available via `iCustom`.

### `MQL5/Experts/TrendScalperEA.mq5`

- Depends on `<Trade/Trade.mqh>`, `<Trade/PositionInfo.mqh>`, and
  `<Trade/SymbolInfo.mqh>` (all ship with MetaTrader 5).
- `OnTrade` is used to detect close events and start the cooldown timer.
- `OnTick` does three things in order:
  1. Resets daily counters at midnight.
  2. Runs breakeven + trailing logic on every tick.
  3. Once per bar, evaluates all filters and opens a single trade in the
     direction signalled by the indicator.

---

## 9. Hand-off / live demo

Both `.mq5` files compile cleanly in MetaEditor 5 (build 4200+). Run the
indicator alone first to validate that the trend lines and arrows look right
on your chart, then enable the EA on demo. The EA respects the
`AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)` flag and the **Algo Trading**
toggle — flipping that off in the terminal is your kill switch.

If you want a PDF instead of this Markdown, the simplest path is **MetaEditor
→ open this README in any viewer that exports to PDF** (or `pandoc README.md
-o README.pdf`). The content is identical.
