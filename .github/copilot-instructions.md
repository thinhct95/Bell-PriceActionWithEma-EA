## Objective

This repository contains MetaTrader 5 Expert Advisors (MQL5). The primary EA is `Experts/BellPriceActionWithEma50EA.mq5`. These instructions help an AI coding assistant make productive, low-risk edits by highlighting the project's structure, conventions, and important code patterns.

## Quick architecture overview

- Codebase is organized under `Experts/`, `Include/`, `Indicators/`, `Libraries/`, `Scripts/` following typical MQL5 terminal structure.
- Primary control loop: `OnTick()` in `Experts/BellPriceActionWithEma50EA.mq5` — this contains entry logic, signal detection, position sizing, and order placement.
- Signal & filters:
  - Trend filter: `EMAFilter()` uses `iMA` (EMA50/EMA200) on `TrendTF` (default `PERIOD_M5`).
  - Entry patterns: `DetectDoubleTop()` / `DetectDoubleBottom()` plus `IsBullishEngulfing()` / `IsBearishEngulfing()` run on `EntryTF` (default `PERIOD_M1`).
  - Risk sizing: `CalculateLotByRisk()` computes lots from `RiskPercent` and stop-loss points using `SymbolInfoDouble` values.
  - Order execution: `PlaceMarketOrder()` calls the `CTrade` methods `Buy()`/`Sell()` and sets `ExpertMagicNumber`.

## What to change safely

- Non-critical tweaks: input parameter defaults near the top of `Experts/BellPriceActionWithEma50EA.mq5` (e.g., `EMA_Fast`, `EMA_Slow`, `RiskPercent`, `TP_Multiplier`, `MaxOpenPositions`).
- Add diagnostics/logging: use `Print()` or `PrintFormat()` inside `OnTick()` and helper functions. Avoid printing every tick (rate-limit by comparing `iTime()` or a static timestamp).
- Visualization: toggles like `VisualizeEMAs` control `ChartIndicatorAdd()` calls; toggles are safe to change.

## What to avoid / high-risk areas

- Changing position sizing or order placement logic without running a backtest can cause real-money risk. `CalculateLotByRisk()` and `PlaceMarketOrder()` are the critical sections to review together.
- Do not change the `ExpertMagicNumber` lightly — it's used to identify positions opened by this EA.

## Project-specific conventions

- Timeframe separation: Trend calculation runs on `TrendTF` (M5 by default) while entry pattern detection runs on `EntryTF` (M1). Keep this separation when adding indicators or signals.
- Many helper functions work with the `_Symbol` and explicit timeframe arguments (`ENUM_TIMEFRAMES`). Prefer `iMA`, `iOpen`, `iClose`, `iLow`, `iHigh` calls to keep data access consistent.
- Use `_Point`, `SymbolInfoDouble(..., SYMBOL_...)`, and account info functions when computing price/volume; these are used throughout for portability across symbols and instruments.

## Build / test / debug workflows

- This is an MQL5 project intended to be edited inside MetaEditor or the MetaTrader terminal:
  - Build: open the `.mq5` file in MetaEditor and press Compile (or use the terminal's compile command).
  - Backtest / debug: use the Strategy Tester in MetaTrader 5. There is no CI here; changes should be validated with local backtests before live deployment.
- Quick local checks an AI agent can suggest to the developer (do not run live):
  - Run a short backtest (few thousand ticks) in the Strategy Tester on a demo account.
  - Add `PrintFormat()` statements and use the Journal/Experts log to inspect behavior during a forward test.

## Examples from codebase (patterns an AI should follow)

- Pattern detection: `DetectDoubleBottom(EntryTF, 40, DoubleTolerancePoints, level)` — helpers return booleans and an out parameter `levelPrice`.
- Rate-limited tick handling: `static datetime lastEntryTime` + comparing to `iTime(_Symbol, EntryTF, 0)` to run logic only once per `EntryTF` candle.
- Position counting: `CountOpenPositionsSymbol()` loops `PositionsTotal()` and compares `PositionGetSymbol(i) == _Symbol`.

## Edit guidance for PRs

- Provide a short description linking changes to specific inputs or functions (e.g., “Adjust risk calc in `CalculateLotByRisk()` to use SYMBOL_TRADE_TICK_VALUE fallback”).
- Add or update a small test/backtest report (Strategy Tester settings and graphs) in the PR description when changing trading logic.

## Missing information / when to ask the human

- If a change modifies risk, order execution, or magic number, ask for the intended account (demo vs live) and a short test plan.
- If adding new external dependencies (libraries/indicators), request the exact indicator file or include path and confirm licensing.

---
If anything in this file is unclear or you want me to include more project-specific examples (e.g., sample Strategy Tester settings, typical symbol/instrument, or a suggested short backtest), tell me which area to expand.
