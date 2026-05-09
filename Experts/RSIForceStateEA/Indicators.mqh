#ifndef RSI_FORCE_STATE_EA__INDICATORS_MQH
#define RSI_FORCE_STATE_EA__INDICATORS_MQH

// ============================================================
// Indicator handles + cached series buffers.
// All buffers are timeseries indexed (index 0 = current bar).
// ============================================================

int g_hRSI    = INVALID_HANDLE;
int g_hEMA9   = INVALID_HANDLE;  // EMA(InpRSI_EMA9Period) computed on RSI
int g_hWMA45  = INVALID_HANDLE;  // WMA(InpRSI_WMA45Period) computed on RSI
int g_hEMA200 = INVALID_HANDLE;  // EMA(InpEMA200Period) on close
int g_hATR    = INVALID_HANDLE;

// Dynamic arrays so ArraySetAsSeries(...) is allowed.
double   g_RSI[];
double   g_EMA9[];
double   g_WMA45[];
double   g_EMA200[];
double   g_ATR[];
MqlRates g_Bars[];

// How many bars we keep cached. Must be > swing/sideway/cross lookback.
const int kIndicatorCacheBars = 200;

// ------------------------------------------------------------
// Lifecycle
// ------------------------------------------------------------

bool InitIndicators()
{
  g_hRSI = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
  if (g_hRSI == INVALID_HANDLE) return false;

  // EMA9 / WMA45 are computed on the RSI buffer (not on price).
  g_hEMA9   = iMA(_Symbol, _Period, InpRSI_EMA9Period,  0, MODE_EMA,  g_hRSI);
  if (g_hEMA9 == INVALID_HANDLE) return false;

  g_hWMA45  = iMA(_Symbol, _Period, InpRSI_WMA45Period, 0, MODE_LWMA, g_hRSI);
  if (g_hWMA45 == INVALID_HANDLE) return false;

  g_hEMA200 = iMA(_Symbol, _Period, InpEMA200Period,    0, MODE_EMA,  PRICE_CLOSE);
  if (g_hEMA200 == INVALID_HANDLE) return false;

  g_hATR    = iATR(_Symbol, _Period, InpATRPeriod);
  if (g_hATR == INVALID_HANDLE) return false;

  ArraySetAsSeries(g_RSI,    true);
  ArraySetAsSeries(g_EMA9,   true);
  ArraySetAsSeries(g_WMA45,  true);
  ArraySetAsSeries(g_EMA200, true);
  ArraySetAsSeries(g_ATR,    true);
  ArraySetAsSeries(g_Bars,   true);
  return true;
}

void ReleaseIndicators()
{
  if (g_hRSI    != INVALID_HANDLE) IndicatorRelease(g_hRSI);
  if (g_hEMA9   != INVALID_HANDLE) IndicatorRelease(g_hEMA9);
  if (g_hWMA45  != INVALID_HANDLE) IndicatorRelease(g_hWMA45);
  if (g_hEMA200 != INVALID_HANDLE) IndicatorRelease(g_hEMA200);
  if (g_hATR    != INVALID_HANDLE) IndicatorRelease(g_hATR);
}

// Refresh the cached series buffers; returns false on partial copy.
bool RefreshIndicatorData()
{
  const int n = kIndicatorCacheBars;
  if (CopyRates(_Symbol, _Period, 0, n, g_Bars) < n) return false;
  if (CopyBuffer(g_hRSI,    0, 0, n, g_RSI)    < n) return false;
  if (CopyBuffer(g_hEMA9,   0, 0, n, g_EMA9)   < n) return false;
  if (CopyBuffer(g_hWMA45,  0, 0, n, g_WMA45)  < n) return false;
  if (CopyBuffer(g_hEMA200, 0, 0, n, g_EMA200) < n) return false;
  if (CopyBuffer(g_hATR,    0, 0, n, g_ATR)    < n) return false;
  return true;
}

// ------------------------------------------------------------
// Helpers used by the state machine on series-indexed buffers
// ------------------------------------------------------------

// True when buffer is monotonically decreasing across [shift .. shift+lookback-1].
// In timeseries indexing: newer bar = lower index, so "down slope" means
// older value > newer value, i.e. buffer[i+1] > buffer[i].
bool IsBufferSlopingDown(const double &buffer[], const int shift, const int lookback)
{
  for (int i = shift; i < shift + lookback - 1; i++)
  {
    if (!(buffer[i] < buffer[i + 1])) return false;
  }
  return true;
}

// True when buffer is monotonically increasing across [shift .. shift+lookback-1].
bool IsBufferSlopingUp(const double &buffer[], const int shift, const int lookback)
{
  for (int i = shift; i < shift + lookback - 1; i++)
  {
    if (!(buffer[i] > buffer[i + 1])) return false;
  }
  return true;
}

// Returns true if (a-b) sign changes anywhere within
// [fromShift .. fromShift+lookback-1]. Used to ensure RSI has stayed
// on one side of WMA45 for at least N bars before a fresh trigger.
bool HasCrossInLastNBars(const double &a[], const double &b[], const int fromShift, const int lookback)
{
  for (int i = fromShift; i < fromShift + lookback; i++)
  {
    const double diffNew = a[i]     - b[i];
    const double diffOld = a[i + 1] - b[i + 1];
    if (diffNew == 0.0 || diffOld == 0.0
        || (diffNew > 0.0 && diffOld < 0.0)
        || (diffNew < 0.0 && diffOld > 0.0))
      return true;
  }
  return false;
}

#endif
