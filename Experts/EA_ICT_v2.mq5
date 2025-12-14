//+------------------------------------------------------------------+
//| EA: ICT v2                                                       |
//| Mục đích: Setup ICT đồng thuận trend 3 timeframes                |
//| Người tạo: Bell CW                                                |
//+------------------------------------------------------------------+
#property copyright "Bell CW"
#property version   "2.00"
#property strict

// --- Only Entry logs (user requested) ---
bool PrintEntryLog = true;   // nếu true -> in log chỉ liên quan tới entry

input double RishPercent = 1.0;        // % vốn rủi ro cho mỗi lệnh
input double RiskRewardRatio = 3.0;   // tỉ lệ R:R mặc định

input double moveSLRange = 1;   // Nomal moving SL: số R cần đạt để dời SL về entry (BE)
input int MaxLimitOrderTime = 120;

input double moveSLStartR = 3;   // Advanced moving SL: bắt đầu kích hoạt trailing
input double trailOffsetR = 3;   // Advanced moving SL: khoảng cách SL so với giá hiện tại

// Cấu hình Swing
input int           htfSwingRange = 2;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           mtfSwingRange = 3;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           ltfSwingRange = 4;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           MaxSwingKeep = 2;            // Số đỉnh/đáy gần nhất cần lưu (bạn yêu cầu 2)

// Struct pending entry (single slot)
struct PendingEntry
{
  bool    active;            // đang có pending entry
  int     direction;         // 1 = buy (bull), -1 = sell (bear)
  double  price;             // entry price (edge của LTF internal FVG)
  int     fvgIndex;          // index của MTF FVG (watched) hoặc -1 nếu none
  string  compositeName;     // tên object composite vẽ (line|label)
  datetime created_time;     // thời điểm tạo
  int     source_slot;       // slot nơi phát hiện MSS (HTF/MTF/LTF)
  double  sl_price;        // giá SL (dựa trên swing gần nhất)
  double  tp_price;        // giá TP (dựa trên swing gần nhất)
  double  lotSize;          // kích thước lot tính toán
  ulong   orderTicket;     // ticket lệnh đã mở (0 = chưa mở)
};

// global pending entry variable
PendingEntry pendingEntry;

// --- Watch MSS mode (user requested) ---
bool watchingMSSMode = false;      // mặc định false
int  watchingFVGIndex = -1;      // index trong FVG_* arrays (khi watchingMSSMode==true)
int  watchingFVGDir = 0;         // 1 = bullish FVG, -1 = bearish FVG

// --- Mảng trạng thái: MTF FVG đã bị chạm bởi LTF hay chưa ---
bool     MTF_FVG_Touched[];        // true = MTF FVG k đã bị LTF chạm
datetime MTF_FVG_TouchTime[];     // thời điểm bar LTF đầu tiên chạm zone (datetime)
double   MTF_FVG_TouchPrice[];    // giá chạm đại diện (low khi bullish, high khi bearish)

// Bật/tắt MSS detection cho từng TF
input bool DetectMSS_HTF = false;
input bool DetectMSS_MTF = false;
input bool DetectMSS_LTF = true;

// Cấu hình vẽ Swing trên chart
input bool   ShowSwingMarkers = true;      // Hiển thị các marker swing trên chart
input string SwingObjPrefix   = "Swing_"; // Tiền tố tên object (dễ xóa/điều chỉnh)
input int    SwingMarkerFontSize    = 10;        // Kích thước font cho label

input int FVGLookback = 200;   // Số nến lookback khi tính FVG (dùng ở EnsureFVGUpToDate)

input bool   PrintToExperts = false;    // không dùng — logs đã được chọn lại

// --- lưu trend đã tính cho mỗi slot ---
// slot 0 = HTF, 1 = MTF, 2 = LTF
int TrendTF[3]; // 1 = up, -1 = down, 0 = sideway / unknown

input ENUM_TIMEFRAMES HighTF = PERIOD_D1;    // Khung thời gian cao
input ENUM_TIMEFRAMES MiddleTF = PERIOD_H1;  // Khung thời gian trung bình (dùng để tìm FVG)
input ENUM_TIMEFRAMES LowTF = PERIOD_M5;    // Khung thời gian thấp (Tìm điểm vào lệnh)

// --- multi-TF swing storage (slots) ---
// slot 0 = HighTF, slot 1 = MiddleTF, slot 2 = LowTF
// dimension: [slot][index]  (index 0 = nearest, 1 = older)
double SwingHighPriceTF[3][2];
datetime SwingHighTimeTF[3][2];
int    SwingHighCountTF[3];

double SwingLowPriceTF[3][2];
datetime SwingLowTimeTF[3][2];
int    SwingLowCountTF[3];

// --- cấu hình cho trend provisional (phát hiện sớm) ---
input int ProvisionalBreakPips = 5; // số pips để coi là phá sớm (change-as-you-like)
input int ProvisionalConsecCloses = 1; // số nến đóng liên tiếp vượt level để xác nhận provisional (thường 1 hoặc 2)

// --- FVG struct & storage (replace old separate arrays) ---
struct FVG
{
  int      type;        //  1 = bullish (gap below price), -1 = bearish (gap above price)
  double   topPrice;         // top edge (higher price)
  double   bottomPrice;      // bottom edge (lower price)
  datetime timebarA;       // time of bar A (older)
  datetime timebarC;       // time of bar C (newer)
  bool     touched;     // whether LTF touched this MTF FVG yet (first-touch)
  datetime touchTime;   // time of first touch (on LowTF)
  double   touchPrice;  // representative touch price (edge)
};

FVG FVGs[];
int   FVG_count = 0;  // number of FVGs found (kept for compatibility)


// last closed bar time per slot (index 0=HighTF,1=MiddleTF,2=LowTF)
datetime lastClosedBarTime[3] = {0,0,0};

// cache last FVG compute time (bar C or bar index 1 time used to detect change)
datetime lastFVGBarTime = 0;

struct MSS {
  bool  found;
  int   direction; //  1 = bearish → bullish | -1 = bullish → bearish

  datetime sweep_time;            // time của nến quét liquidity
  double   sweep_extreme_price;   // GIÁ QUÉT THỰC TẾ

  datetime swept_swing_time;      // time của swing bị quét
  double   swept_swing_price;     // GIÁ swing bị quét (liquidity pool)

  datetime break_time;            // time nến BOS
  double   bos_close_price;       // GIÁ ĐÓNG nến BOS

  datetime broken_swing_time;     // time swing bị phá
  double   broken_swing_price;    // GIÁ swing bị phá (key level)
};

// Kết quả BOS
struct BOSInfo
{
  bool    found;
  bool    isReal;
  int     direction;           // 1 = up, -1 = down
  datetime break_time;         // time của bar xác nhận (bar đóng)
  double  break_price;         // close của bar xác nhận
  double  broken_sw_price;     // giá swing bị phá (sh0 hoặc sl0)
  datetime broken_sw_time;     // time của swing bị phá
  int     confirm_bar_index;   // index (iBarShift) của bar xác nhận
  int     consec_closes;
};

// Bật/tắt BOS detection cho từng TF
input bool DetectBOS_HTF = false;
input bool DetectBOS_MTF = false;
input bool DetectBOS_LTF = true;

// --- BOS storage: lưu tối đa 2 BOS cho mỗi slot (slot 0=HTF,1=MTF,2=LTF)
// Reuse struct BOSInfo (đã khai báo trước đó)
BOSInfo BOSStore[3][2];      // BOSStore[slot][index] : index 0 = older, 1 = newer
string  BOS_Names[3][2];     // tên objects (composite) cho mỗi store entry
int     BOS_Count[3] = {0,0,0}; // số BOS hiện có cho mỗi slot (0..2)
bool    BOS_HaveZone[3][2];  // flag có zone hay không

void UpdateMTFFVGTouched(string symbol)
{
  if(FVG_count <= 0) return;

  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  // scan each stored FVG
  for(int fvgIndex = 0; fvgIndex < FVG_count; fvgIndex++)
  {
    // nếu đã touched trước đó -> bỏ qua luôn (không in gì cả)
    if(FVGs[fvgIndex].touched) continue;

    datetime mtfC = FVGs[fvgIndex].timebarC;
    if(mtfC == 0) continue;

    double top = FVGs[fvgIndex].topPrice;
    double bottom = FVGs[fvgIndex].bottomPrice;
    int dir = FVGs[fvgIndex].type; // 1=bull, -1=bear

    // find index of mtfC on LowTF
    int idxC_on_LTF = iBarShift(symbol, LowTF, mtfC, false);
    if(idxC_on_LTF == -1) idxC_on_LTF = 0;

    bool touchedNow = false;
    datetime touch_time = 0;
    double touch_price = 0.0;

    // scan forward on LowTF (bars newer than mtfC): idx = idxC_on_LTF-1 ... 0
    int barsAvail = iBars(symbol, LowTF);
    for(int idx = idxC_on_LTF - 1; idx >= 0; idx--)
    {
      double hh = iHigh(symbol, LowTF, idx);
      double ll = iLow(symbol, LowTF, idx);
      if(hh == 0 || ll == 0) continue;

      if(dir == 1) // bullish FVG -> touch when LTF high >= top
      {
        if(hh >= top - tol)
        {
          touchedNow = true;
          touch_time = iTime(symbol, LowTF, idx);
          touch_price = top; // representative edge price
          break;
        }
      }
      else // dir == -1 -> bearish FVG -> touch when LTF low <= bottom
      {
        if(ll <= bottom + tol)
        {
          touchedNow = true;
          touch_time = iTime(symbol, LowTF, idx);
          touch_price = bottom;
          break;
        }
      }
    }

    if(touchedNow)
    {
      // chỉ set + print khi trước đó chưa touched (điều kiện đã đảm bảo vì ta continue ở trên nếu touched==true)
      FVGs[fvgIndex].touched = true;
      FVGs[fvgIndex].touchTime = touch_time;
      FVGs[fvgIndex].touchPrice = touch_price;

      // enable watchingMSSMode when any MTF FVG is first touched
      if(!watchingMSSMode)
      {
        watchingMSSMode = true;
        watchingFVGIndex = fvgIndex;
        watchingFVGDir   = dir;
        if(PrintEntryLog)
          PrintFormat("watchingMSSMode ENABLED for FVG idx=%d dir=%d", watchingFVGIndex, watchingFVGDir);
      }
    }
  }
}

// Kiểm tra điều kiện vô hiệu hoá watchingMSSMode:
// 1) last closed candle trên LowTF đóng dưới cạnh dưới của bullish FVG
// 2) last closed candle trên LowTF đóng trên cạnh trên của bearish FVG
void CheckWatchMSSInvalidation(string symbol)
{
  if(!watchingMSSMode || watchingFVGIndex < 0 || watchingFVGIndex >= FVG_count) return;

  // Lấy last closed close trên LowTF (index 1)
  double lastClose = iClose(symbol, LowTF, 1);
  if(lastClose == 0.0) return;

  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  int idx = watchingFVGIndex;
  int dir = watchingFVGDir;

  // bảo đảm FVG arrays còn hợp lệ
  if(idx < 0 || idx >= FVG_count) return;

  double top = FVGs[idx].topPrice;
  double bottom = FVGs[idx].bottomPrice;

  // Nếu bullish FVG (dir == 1): invalid khi đóng dưới bottom
  if(dir == 1)
  {
    if(lastClose < bottom - tol)
    {
      if(PrintEntryLog) PrintFormat("watchingMSSMode DISABLED: bullish FVG idx=%d invalidated by close=%.5f < bottom=%.5f", idx, lastClose, bottom);
      // clear
      watchingMSSMode = false;
      watchingFVGIndex = -1;
      watchingFVGDir = 0;
    }
  }
  else if(dir == -1) // bearish: invalid khi đóng trên top
  {
    if(lastClose > top + tol)
    {
      if(PrintEntryLog) PrintFormat("watchingMSSMode DISABLED: bearish FVG idx=%d invalidated by close=%.5f > top=%.5f", idx, lastClose, top);
      // clear
      watchingMSSMode = false;
      watchingFVGIndex = -1;
      watchingFVGDir = 0;
    }
  }
}

void StoreNewBOS(int slot, const BOSInfo &bos)
{
  // Nếu chưa có BOS nào
  if(BOS_Count[slot] == 0)
  {
    BOSStore[slot][0] = bos;
    // Clear name => DrawBOS sẽ tạo object và lưu tên
    BOS_Names[slot][0] = "";
    BOS_HaveZone[slot][0] = true;
    BOS_Count[slot] = 1;
  }
  else if(BOS_Count[slot] == 1)
  {
    // shift index0 -> index1 (data only), but DO NOT copy names
    BOSStore[slot][1] = BOSStore[slot][0];
    BOS_HaveZone[slot][1] = false;   // will be created by DrawBOS
    BOS_Names[slot][1] = "";

    // store new into index0
    BOSStore[slot][0] = bos;
    BOS_Names[slot][0] = "";
    BOS_HaveZone[slot][0] = true;

    BOS_Count[slot] = 2;
  }
  else // BOS_Count == 2
  {
    // xóa oldest (index1) trước nếu có object name lưu
    if(StringLen(BOS_Names[slot][1]) > 0)
    {
      DeleteCompositeBOS(BOS_Names[slot][1]);
    }

    // shift data index0 -> index1 (but clear names so Draw creates fresh objects)
    BOSStore[slot][1] = BOSStore[slot][0];
    BOS_Names[slot][1] = "";
    BOS_HaveZone[slot][1] = false;

    // store new into index0
    BOSStore[slot][0] = bos;
    BOS_Names[slot][0] = "";
    BOS_HaveZone[slot][0] = true;

    BOS_Count[slot] = 2;
  }

  // Vẽ lại tất cả BOS cho slot (DrawAllBOSForSlot sẽ tạo lại objects và ghi BOS_Names)
  DrawAllBOSForSlot(slot);
}

// Vẽ tất cả BOS đã lưu cho 1 slot (0=HTF,1=MTF,2=LTF)
// SỬA: không xóa theo prefix chung nữa, chỉ xóa các composite names đã lưu trong BOS_Names
void DrawAllBOSForSlot(int slot)
{
  if(!ShowSwingMarkers) return;
  int cnt = BOS_Count[slot];
  if(cnt <= 0) return;
  string sym = Symbol();

  // --- SAFE CLEANUP: xóa composite object cũ mà chúng ta từng lưu tên trong BOS_Names ---
  for(int j = 0; j < 2; j++)
  {
    if(StringLen(BOS_Names[slot][j]) > 0)
    {
      // DeleteCompositeBOS sẽ kiểm tra tồn tại từng object con trước khi xóa
      DeleteCompositeBOS(BOS_Names[slot][j]);
      BOS_Names[slot][j] = "";        // clear saved composite name so DrawBOS will recreate
      BOS_HaveZone[slot][j] = false;
    }
  }

  // draw older first (index1) then newer (index0)
  // Note: DrawBOS sẽ set BOS_Names[slot][storeIndex] after drawing, so we pass storeIndex to persist names
  if(cnt == 2)
  {
    if(BOSStore[slot][1].found)
    {
      DrawBOS(sym, slot, BOSStore[slot][1], 1);
      if(StringLen(BOS_Names[slot][1]) == 0)
      {
        // do nothing special
      }
    }

    if(BOSStore[slot][0].found)
    {
      DrawBOS(sym, slot, BOSStore[slot][0], 0);
      if(StringLen(BOS_Names[slot][0]) == 0)
      {
        // do nothing special
      }
    }
  }
  else // cnt == 1
  {
    if(BOSStore[slot][0].found)
    {
      DrawBOS(sym, slot, BOSStore[slot][0], 0);
    }
  }
}

void HandleBOSDetections(string symbol, ENUM_TIMEFRAMES timeframe, int slot)
{
  // Tôn trọng input bật/tắt cho từng slot (slot 0=HTF,1=MTF,2=LTF)
  bool enabled = false;
  if(slot == 0) enabled = DetectBOS_HTF;
  else if(slot == 1) enabled = DetectBOS_MTF;
  else if(slot == 2) enabled = DetectBOS_LTF;

  if(!enabled) return;

  // Phát hiện BOS trên slot (giữ nguyên tham số bạn muốn)
  BOSInfo bos = DetectBOSOnSlot(symbol, timeframe, slot,
                               ProvisionalBreakPips,
                               ProvisionalConsecCloses,
                               true,
                               5);
  if(bos.found) StoreNewBOS(slot, bos);
}

// DetectBOSOnSlot: detect Break Of Structure based on nearest swing (index 0)
// symbol, timeframe, slot: như EA của bạn
// minBreakPips: số pips tối thiểu vượt swing để gọi là BOS (ví dụ 1..10 tuỳ TF)
// consecRequired: số nến đóng liên tiếp xác nhận (1 = 1 bar close đủ)
// useBodyCheck: nếu true thì yêu cầu bar xác nhận là nến thuận (close>open cho bullish, close<open cho bearish)
// lookForwardBars: số bars mới hơn để scan tìm confirm (thường small: 1..5)
// Trả về BOSInfo
BOSInfo DetectBOSOnSlot(string symbol, ENUM_TIMEFRAMES timeframe, int slot,
                        double minBreakPips = 5.0,
                        int consecRequired = 1,
                        bool useBodyCheck = true,
                        int lookForwardBars = 5)
{
  BOSInfo out;
  out.found = false;
  out.direction = 0;
  out.break_time = 0;
  out.break_price = 0.0;
  out.broken_sw_price = 0.0;
  out.broken_sw_time = 0;
  out.confirm_bar_index = -1;
  out.consec_closes = 0;
  out.isReal = false; // default

  // Cần ít nhất 1 swing high hoặc low (ở slot)
  double sh0 = (SwingHighCountTF[slot] >= 1) ? SwingHighPriceTF[slot][0] : 0.0;
  double sl0 = (SwingLowCountTF[slot] >= 1) ? SwingLowPriceTF[slot][0] : 0.0;

  if(sh0 == 0.0 && sl0 == 0.0) return out;

  double pip = GetPipSize(symbol);
  double minBreakPoints = minBreakPips * pip;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  int barsAvailable = iBars(symbol, timeframe);
  if(barsAvailable < 2) return out;

  // --- BULLISH BOS: first try REAL (close > sh0 + threshold) ---
  if(sh0 != 0.0)
  {
    for(int idx = 1; idx <= MathMin(lookForwardBars, barsAvailable - 1); idx++)
    {
      double c = iClose(symbol, timeframe, idx);
      double o = iOpen(symbol, timeframe, idx);
      double h = iHigh(symbol, timeframe, idx);
      datetime t = iTime(symbol, timeframe, idx);
      if(c == 0 || h == 0) continue;

      // REAL: require close strictly greater than sh0 + minBreakPoints
      if(c > sh0 + minBreakPoints)
      {
        int consec = 0;
        for(int k = idx; k >= 1 && k >= idx - (consecRequired - 1); k--)
        {
          double ck = iClose(symbol, timeframe, k);
          double ok = iOpen(symbol, timeframe, k);
          if(ck == 0) break;
          if(useBodyCheck)
          {
            if(ck > ok && ck > sh0 + minBreakPoints) consec++;
            else break;
          }
          else
          {
            if(ck > sh0 + minBreakPoints) consec++;
            else break;
          }
        }
        if(consec >= consecRequired)
        {
          out.found = true;
          out.direction = 1;
          out.break_time = t;
          out.break_price = c;
          out.broken_sw_price = sh0;
          out.broken_sw_time = SwingHighTimeTF[slot][0];
          out.confirm_bar_index = idx;
          out.consec_closes = consec;
          out.isReal = true;
          return out;
        }
      }
    }

    // If no REAL bullish BOS found, check for FAKE bullish BOS:
    for(int idx = 1; idx <= MathMin(lookForwardBars, barsAvailable - 1); idx++)
    {
      double c = iClose(symbol, timeframe, idx);
      double h = iHigh(symbol, timeframe, idx);
      datetime t = iTime(symbol, timeframe, idx);
      if(h == 0) continue;

      if(h > sh0 + minBreakPoints && c <= sh0 + minBreakPoints)
      {
        // classify as fake BOS
        out.found = true;
        out.direction = 1;
        out.break_time = t;
        out.break_price = c;
        out.broken_sw_price = sh0;
        out.broken_sw_time = SwingHighTimeTF[slot][0];
        out.confirm_bar_index = idx;
        out.consec_closes = 0;
        out.isReal = false;
        return out;
      }
    }
  }

  // --- BEARISH BOS: first try REAL (close < sl0 - threshold) ---
  if(sl0 != 0.0)
  {
    for(int idx = 1; idx <= MathMin(lookForwardBars, barsAvailable - 1); idx++)
    {
      double c = iClose(symbol, timeframe, idx);
      double o = iOpen(symbol, timeframe, idx);
      double l = iLow(symbol, timeframe, idx);
      datetime t = iTime(symbol, timeframe, idx);
      if(c == 0 || l == 0) continue;

      if(c < sl0 - minBreakPoints)
      {
        int consec = 0;
        for(int k = idx; k >= 1 && k >= idx - (consecRequired - 1); k--)
        {
          double ck = iClose(symbol, timeframe, k);
          double ok = iOpen(symbol, timeframe, k);
          if(ck == 0) break;
          if(useBodyCheck)
          {
            if(ck < ok && ck < sl0 - minBreakPoints) consec++;
            else break;
          }
          else
          {
            if(ck < sl0 - minBreakPoints) consec++;
            else break;
          }
        }
        if(consec >= consecRequired)
        {
          out.found = true;
          out.direction = -1;
          out.break_time = t;
          out.break_price = c;
          out.broken_sw_price = sl0;
          out.broken_sw_time = SwingLowTimeTF[slot][0];
          out.confirm_bar_index = idx;
          out.consec_closes = consec;
          out.isReal = true;
          return out;
        }
      }
    }

    // If no REAL bearish BOS found, check for FAKE bearish BOS:
    for(int idx = 1; idx <= MathMin(lookForwardBars, barsAvailable - 1); idx++)
    {
      double c = iClose(symbol, timeframe, idx);
      double l = iLow(symbol, timeframe, idx);
      datetime t = iTime(symbol, timeframe, idx);
      if(l == 0) continue;

      if(l < sl0 - minBreakPoints && c >= sl0 - minBreakPoints)
      {
        // classify as fake BOS
        out.found = true;
        out.direction = -1;
        out.break_time = t;
        out.break_price = c;
        out.broken_sw_price = sl0;
        out.broken_sw_time = SwingLowTimeTF[slot][0];
        out.confirm_bar_index = idx;
        out.consec_closes = 0;
        out.isReal = false;
        return out;
      }
    }
  }

  return out;
}

// DrawBOS: vẽ 1 BOS (không shift/xóa store) — parameters: symbol, slot, bos info, storeIndex (0/1)
// Nếu bạn gọi DrawBOS với storeIndex = -1 thì hàm sẽ chỉ tạo objects tạm (không lưu tên).
void DrawBOS(string symbol, int slot, const BOSInfo &info, int storeIndex = -1)
{
  if(!info.found) return;

  string basePrefix = SwingObjPrefix + "BOS_" + IntegerToString(slot) + "_";

  ENUM_TIMEFRAMES tf = (slot==0 ? HighTF : (slot==1 ? MiddleTF : LowTF));

  // get start time/price (swing broken)
  datetime t_start = info.broken_sw_time;
  double   p_start = info.broken_sw_price;

  if(t_start == 0 || p_start == 0.0)
  {
    if(info.direction == 1) { t_start = SwingHighTimeTF[slot][0]; p_start = SwingHighPriceTF[slot][0]; }
    else { t_start = SwingLowTimeTF[slot][0]; p_start = SwingLowPriceTF[slot][0]; }
  }

  if(t_start == 0 || p_start == 0.0)
  {
    return;
  }

  datetime bar_secs = (datetime)PeriodSeconds(tf);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  datetime touch_time = FindTouchTime(symbol, tf, t_start, p_start, tol, bar_secs);
  if(touch_time <= t_start)
  {
    if(info.break_time != 0 && info.break_time > t_start) touch_time = info.break_time;
    else
    {
      datetime t0 = iTime(symbol, tf, 0);
      touch_time = (t0 != 0) ? (datetime)((long)t0 + (long)bar_secs) : (datetime)TimeCurrent();
    }
  }

  datetime t_h_end = touch_time;
  double p_h = p_start;
  if(t_h_end == t_start) t_h_end = (datetime)((long)t_start + (long)bar_secs);

  // --- TẠO TÊN UNIQUE: bao gồm slot + storeIndex + thời điểm để tránh trùng ---
  int idxPart = (storeIndex >= 0) ? storeIndex : -1;
  int timeStampInt = (info.broken_sw_time != 0) ? (int)info.broken_sw_time : (int)t_start;
  string stamp = StringFormat("%d_%d_%d", slot, idxPart, timeStampInt);

  string nm_line = basePrefix + "HLINE_" + stamp;
  string nm_arrow = basePrefix + "ARW_" + stamp;
  string nm_txt = basePrefix + "LBL_" + stamp;

  // Nếu caller truyền storeIndex >=0 và đã có composite name lưu trước đó:
  if(storeIndex >= 0)
  {
    if(StringLen(BOS_Names[slot][storeIndex]) > 0)
    {
      string parts[];
      int n = StringSplit(BOS_Names[slot][storeIndex], '|', parts);
      bool all_exist = true;
      for(int p = 0; p < n; p++)
      {
        if(StringLen(parts[p]) == 0) continue;
        if(ObjectFind(0, parts[p]) < 0) { all_exist = false; break; }
      }

      if(all_exist)
      {
        return;
      }
      else
      {
        // object cũ bị xóa một phần nào đó -> xóa compositeName cũ khỏi bộ nhớ trước khi vẽ mới
        DeleteCompositeBOS(BOS_Names[slot][storeIndex]);
        BOS_Names[slot][storeIndex] = "";
        BOS_HaveZone[slot][storeIndex] = false;
      }
    }
  }

  // Create horizontal line (trend object used as line)
  if(!ObjectCreate(0, nm_line, OBJ_TREND, 0, t_start, p_h, t_h_end, p_h))
    ; // skip silent
  else
  {
    int lineColor = info.isReal ? ((info.direction==1)?clrLime:clrRed) : clrYellow;
    ObjectSetInteger(0, nm_line, OBJPROP_COLOR, lineColor);
    ObjectSetInteger(0, nm_line, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, nm_line, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, nm_line, OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, nm_line, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, nm_line, OBJPROP_BACK, true);
  }

  // Arrow (or fallback text arrow) at t_h_end,p_h
  if(ObjectCreate(0, nm_arrow, OBJ_ARROW, 0, t_h_end, p_h))
  {
    int code = (info.direction==1) ? 233 : 234;
    #ifdef __MQL5__
      ObjectSetInteger(0, nm_arrow, OBJPROP_ARROWCODE, code);
    #endif
    int arrowColor = info.isReal ? ((info.direction==1)?clrLime:clrRed) : clrYellow;
    ObjectSetInteger(0, nm_arrow, OBJPROP_COLOR, arrowColor);
    ObjectSetInteger(0, nm_arrow, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, nm_arrow, OBJPROP_BACK, true);
  }
  else
  {
    string nm_fallback = basePrefix + "ARW_T_" + stamp;
    if(ObjectCreate(0, nm_fallback, OBJ_TEXT, 0, t_h_end, p_h))
    {
      string arrowTxt = (info.direction==1) ? "▲" : "▼";
      ObjectSetString(0, nm_fallback, OBJPROP_TEXT, arrowTxt);
      int arrowColor = info.isReal ? ((info.direction==1)?clrLime:clrRed) : clrYellow;
      ObjectSetInteger(0, nm_fallback, OBJPROP_COLOR, arrowColor);
      ObjectSetInteger(0, nm_fallback, OBJPROP_FONTSIZE, SwingMarkerFontSize+2);
      ObjectSetInteger(0, nm_fallback, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm_fallback, OBJPROP_BACK, true);
      nm_arrow = nm_fallback;
    }
  }

  double y_offset = SymbolInfoDouble(symbol, SYMBOL_POINT) * 4.0;
  double label_price = (info.direction==1) ? (p_h + y_offset) : (p_h - y_offset);

  // Label text and color depending on real/fake
  string labelText = info.isReal ? "BOS" : "FAKE";
  int labelColor = info.isReal ? ((info.direction==1)?clrLime:clrRed) : clrYellow;

  if(!ObjectCreate(0, nm_txt, OBJ_TEXT, 0, t_h_end, label_price))
    ;
  else
  {
    ObjectSetString(0, nm_txt, OBJPROP_TEXT, labelText);
    ObjectSetInteger(0, nm_txt, OBJPROP_COLOR, labelColor);
    ObjectSetInteger(0, nm_txt, OBJPROP_FONTSIZE, SwingMarkerFontSize + 1);
    ObjectSetInteger(0, nm_txt, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, nm_txt, OBJPROP_BACK, true);
  }

  // Nếu caller truyền storeIndex >=0 thì lưu composite name để quản lý (xóa sau)
  string compositeName = nm_line + "|" + nm_arrow + "|" + nm_txt;
  if(storeIndex >= 0)
  {
    if(StringLen(BOS_Names[slot][storeIndex]) > 0) DeleteCompositeBOS(BOS_Names[slot][storeIndex]);

    BOS_Names[slot][storeIndex] = compositeName;
    BOS_HaveZone[slot][storeIndex] = true;
  }
}

// xóa compositeName dạng "lineName|arrowName|labelName"
void DeleteCompositeBOS(string compositeName)
{
  if(StringLen(compositeName) == 0) return;
  string parts[];
  int n = StringSplit(compositeName, '|', parts);
  for(int i=0; i<n; i++)
  {
    string nm = parts[i];
    if(StringLen(nm) > 0 && ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
  }
}


// ---------------------- Helper: pip size ----------------------
// Trả về 1 "pip" cho symbol (không phải point).
double GetPipSize(string symbol)
{
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if(digits==5 || digits==3) return point * 10.0;
  return point;
}

// Tìm FVG nội bộ (3-candle gap: A = i+2, B = i+1, C = i)
//
// Điều kiện FVG:
//   • Bullish: low(C) > high(A)
//   • Bearish: high(C) < low(A)
//
// Trả về:
//   out_top[]    – cạnh trên của FVG
//   out_bottom[] – cạnh dưới của FVG
//   out_timeA[]  – thời gian bar A
//   out_timeC[]  – thời gian bar C
//   out_type[]   – 1 = bullish, -1 = bearish
//
// Lý do dùng total - 3:
//   Vì index A = i+2 → cần đảm bảo i+2 <= total-1
//   → i <= total - 3
//
// --------------------------------------------------------------
int FindInternalFVG(string symbol, ENUM_TIMEFRAMES timeframe, int lookback,
                    double &out_top[], double &out_bottom[],
                    datetime &out_timeA[], datetime &out_timeC[], int &out_type[])
{
   // clear output arrays
   ArrayFree(out_top); 
   ArrayFree(out_bottom); 
   ArrayFree(out_timeA); 
   ArrayFree(out_timeC); 
   ArrayFree(out_type);

   int found = 0;
   int total = iBars(symbol, timeframe);

   // cần tối thiểu 5 nến để tránh lỗi/truy cập thiếu (an toàn)
   if(total < 5) return 0;

   // maxScan = nhỏ nhất giữa lookback và total - 3 (đảm bảo idxA không vượt array)
   int maxScan = MathMin(lookback, total - 3);
   if(maxScan <= 0) return 0;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tol = (point > 0.0) ? point * 0.5 : 0.0;

   // ----------------------------------------------------------
   // Loop qua từng cấu trúc A–B–C (C = i, B = i+1, A = i+2)
   // ----------------------------------------------------------
   for(int i = 1; i <= maxScan; i++)
   {
      int idxA = i + 2;
      int idxB = i + 1;
      int idxC = i;

      // kiểm tra A không vượt tổng số bar
      if(idxA > total - 1)
         break;

      // lấy giá 3 nến A và C
      double highA = iHigh(symbol, timeframe, idxA);
      double lowA  = iLow(symbol, timeframe, idxA);
      double highC = iHigh(symbol, timeframe, idxC);
      double lowC  = iLow(symbol, timeframe, idxC);

      if(highA == 0 || lowA == 0 || highC == 0 || lowC == 0)
         continue;

      // ------------------------------------------------------
      // ❶ Kiểm tra Bullish Internal FVG
      //    low(C) > high(A)
      // ------------------------------------------------------
      if(lowC > highA + tol)
      {
         double top = lowC;
         double bottom = highA;

         // kiểm tra tránh duplicate FVG
         bool dup = false;
         for(int k = 0; k < found; k++)
         {
            if(MathAbs(out_top[k] - top) <= tol &&
               MathAbs(out_bottom[k] - bottom) <= tol)
            {
               dup = true;
               break;
            }
         }

         if(!dup)
         {
            ArrayResize(out_top, found+1);
            ArrayResize(out_bottom, found+1);
            ArrayResize(out_timeA, found+1);
            ArrayResize(out_timeC, found+1);
            ArrayResize(out_type, found+1);

            out_top[found]    = top;
            out_bottom[found] = bottom;
            out_timeA[found]  = iTime(symbol, timeframe, idxA);
            out_timeC[found]  = iTime(symbol, timeframe, idxC);
            out_type[found]   = 1;   // bullish

            found++;
         }

         continue;
      }

      // ------------------------------------------------------
      // ❷ Kiểm tra Bearish Internal FVG
      //    high(C) < low(A)
      // ------------------------------------------------------
      if(highC < lowA - tol)
      {
         double top = lowA;
         double bottom = highC;

         bool dup = false;
         for(int k = 0; k < found; k++)
         {
            if(MathAbs(out_top[k] - top) <= tol &&
               MathAbs(out_bottom[k] - bottom) <= tol)
            {
               dup = true;
               break;
            }
         }

         if(!dup)
         {
            ArrayResize(out_top, found+1);
            ArrayResize(out_bottom, found+1);
            ArrayResize(out_timeA, found+1);
            ArrayResize(out_timeC, found+1);
            ArrayResize(out_type, found+1);

            out_top[found]    = top;
            out_bottom[found] = bottom;
            out_timeA[found]  = iTime(symbol, timeframe, idxA);
            out_timeC[found]  = iTime(symbol, timeframe, idxC);
            out_type[found]   = -1;  // bearish

            found++;
         }
      }
   }

   return found;
}

// ---------- HasBullFVGBetween & HasBearFVGBetween (gọi FindInternalFVG) ----------
bool HasBullFVGBetween(string symbol, ENUM_TIMEFRAMES timeframe, datetime t_start, datetime t_end, int fvgLookback)
{
   if(t_start == 0 || t_end == 0 || t_end <= t_start) return false;

   double tops[]; double bottoms[];
   datetime timeA[]; datetime timeC[];
   int types[];

   int cnt = FindInternalFVG(symbol, timeframe, fvgLookback, tops, bottoms, timeA, timeC, types);
   if(cnt <= 0) return false;

   for(int i = 0; i < cnt; i++)
   {
      if(types[i] == 1)
      {
         datetime tc = timeC[i];
         if(tc > t_start && tc < t_end) return true;
      }
   }
   return false;
}

bool HasBearFVGBetween(string symbol, ENUM_TIMEFRAMES timeframe, datetime t_start, datetime t_end, int fvgLookback)
{
   if(t_start == 0 || t_end == 0 || t_end <= t_start) return false;

   double tops[]; double bottoms[];
   datetime timeA[]; datetime timeC[];
   int types[];

   int cnt = FindInternalFVG(symbol, timeframe, fvgLookback, tops, bottoms, timeA, timeC, types);
   if(cnt <= 0) return false;

   for(int i = 0; i < cnt; i++)
   {
      if(types[i] == -1)
      {
         datetime tc = timeC[i];
         if(tc > t_start && tc < t_end) return true;
      }
   }
   return false;
}

// Kiểm tra 1 bar tại index i có phải SwingHigh không (xét râu - High)
bool IsSwingHigh(string symbol, ENUM_TIMEFRAMES timeframe, int candleIndex, int swingRange)
{
  double hi = iHigh(symbol, timeframe, candleIndex);
  if(hi == 0.0) return false;

  for(int i = 1; i <= swingRange; i++)
  {
    int idxPrev = candleIndex - i;
    if(idxPrev < 0) return false;
    double hprev = iHigh(symbol, timeframe, idxPrev);
    if(hprev == 0.0) return false;
    if(hprev >= hi) return false;
  }

  for(int k = 1; k <= swingRange; k++)
  {
    int idxNext = candleIndex + k;
    double hnext = iHigh(symbol, timeframe, idxNext);
    if(hnext == 0.0) return false;
    if(hnext >= hi) return false;
  }

  return true;
}

// Kiểm tra 1 bar tại index i có phải SwingLow không (xét râu - Low)
bool IsSwingLow(string symbol, ENUM_TIMEFRAMES timeframe, int i, int X)
{
  double lo = iLow(symbol, timeframe, i);
  if(lo == 0.0) return false;

  for(int j = 1; j <= X; j++)
  {
    int idxPrev = i - j;
    if(idxPrev < 0) return false;
    double lprev = iLow(symbol, timeframe, idxPrev);
    if(lprev == 0.0) return false;
    if(lprev <= lo) return false;
  }

  for(int k = 1; k <= X; k++)
  {
    int idxNext = i + k;
    double lnext = iLow(symbol, timeframe, idxNext);
    if(lnext == 0.0) return false;
    if(lnext <= lo) return false;
  }

  return true;
}

// Cập nhật mảng SwingHighPrice/Time và SwingLowPrice/Time (giữ MaxSwingKeep phần tử gần nhất)
void UpdateSwings(string symbol, ENUM_TIMEFRAMES timeframe, int slot, int SwingRange)
{
  SwingHighCountTF[slot] = 0;
  SwingLowCountTF[slot]  = 0;

  int total = iBars(symbol, timeframe);
  if(total <= SwingRange + 2) return;

  int iStart = SwingRange + 1;
  int iEnd   = total - SwingRange - 1;

  for(int i = iStart; i <= iEnd; i++)
  {
    if(SwingHighCountTF[slot] >= MaxSwingKeep && SwingLowCountTF[slot] >= MaxSwingKeep) break;

    if(SwingHighCountTF[slot] < MaxSwingKeep)
    {
      bool isH = IsSwingHigh(symbol, timeframe, i, SwingRange);
      if(isH)
      {
        double candleI = iHigh(symbol, timeframe, i);
        datetime ti = iTime(symbol, timeframe, i);
        if(SwingHighCountTF[slot] == 0)
        {
          SwingHighPriceTF[slot][0] = candleI;
          SwingHighTimeTF[slot][0]  = ti;
        }
        else
        {
          SwingHighPriceTF[slot][1] = candleI;
          SwingHighTimeTF[slot][1]  = ti;
        }
        SwingHighCountTF[slot]++;
      }
    }

    if(SwingLowCountTF[slot] < MaxSwingKeep)
    {
      bool isL = IsSwingLow(symbol, timeframe, i, SwingRange);
      if(isL)
      {
        double candleI = iLow(symbol, timeframe, i);
        datetime ti2 = iTime(symbol, timeframe, i);
        if(SwingLowCountTF[slot] == 0)
        {
          SwingLowPriceTF[slot][0] = candleI;
          SwingLowTimeTF[slot][0]  = ti2;
        }
        else
        {
          SwingLowPriceTF[slot][1] = candleI;
          SwingLowTimeTF[slot][1]  = ti2;
        }
        SwingLowCountTF[slot]++;
      }
    }
  }
}

//+------------------------------------------------------------------+
//| Vẽ SwingHigh & SwingLow lên chart                                 |
//+------------------------------------------------------------------+
void DrawSwingsOnChart(ENUM_TIMEFRAMES timeframe)
{
  if(!ShowSwingMarkers) return;

  int slot = 0;
  string inChartSwingPrefix = "h";

  if(timeframe == MiddleTF) {
    slot = 1;
    inChartSwingPrefix = "m";
  } else if (timeframe == LowTF) {
    slot = 2;
    inChartSwingPrefix = "l";
  }

  string prefix = SwingObjPrefix + inChartSwingPrefix;

  int total = ObjectsTotal(0);

  for(int i = total - 1; i >= 0; i--)
  {
    string name = ObjectName(0, i);
    if(StringLen(name) >= StringLen(prefix))
    {
        if(StringSubstr(name, 0, StringLen(prefix)) == prefix)
          ObjectDelete(0, name);
    }
  }

   datetime bar_secs = (datetime)PeriodSeconds(timeframe);

   int maxH = (SwingHighCountTF[slot] < MaxSwingKeep) ? SwingHighCountTF[slot] : MaxSwingKeep;
   for(int h = 0; h < maxH; h++)
   {
      string obj = prefix + "H_" + IntegerToString(h);
      datetime t = SwingHighTimeTF[slot][h];
      double price = SwingHighPriceTF[slot][h];
      datetime display_time_h = (datetime)(t + (bar_secs/2));

      if(t == 0 || price == 0.0) continue;
      if(!ObjectCreate(0, obj, OBJ_TEXT, 0, display_time_h, price))
      {
         continue;
      }

      ObjectSetString(0, obj, OBJPROP_TEXT,  "▲ " + inChartSwingPrefix + "H" + IntegerToString(h));
      ObjectSetInteger(0, obj, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, SwingMarkerFontSize);
      ObjectSetInteger(0, obj, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
      ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, obj, OBJPROP_HIDDEN, false);
   }

   int maxL = (SwingLowCountTF[slot] < MaxSwingKeep) ? SwingLowCountTF[slot] : MaxSwingKeep;
   for(int l = 0; l < maxL; l++)
   {
      string obj = prefix + "L_" + IntegerToString(l);
      datetime t = SwingLowTimeTF[slot][l];
      double price = SwingLowPriceTF[slot][l];
      datetime display_time_l = (datetime)(t + (bar_secs/2));
      if(!ObjectCreate(0, obj, OBJ_TEXT, 0, display_time_l, price))
      {
         continue;
      }

      ObjectSetString(0, obj, OBJPROP_TEXT, "▼ " + inChartSwingPrefix +"L" + IntegerToString(l));
      ObjectSetInteger(0, obj, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, SwingMarkerFontSize);
      ObjectSetInteger(0, obj, OBJPROP_ANCHOR, ANCHOR_TOP);
      ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, obj, OBJPROP_HIDDEN, false);
   }
}

// ---------------------------------------------------------------------
// FindTouchTime(): tìm thời điểm bar đầu tiên sau start_time mà bar chạm price
// ---------------------------------------------------------------------
datetime FindTouchTime(string symbol, ENUM_TIMEFRAMES timeframe,
                       datetime start_time, double price, double tol, datetime bar_secs)
{
   int idxStart = iBarShift(symbol, timeframe, start_time, false);
   if(idxStart == -1) idxStart = 0;

   for(int idx = idxStart - 1; idx >= 0; idx--)
   {
      double highM = iHigh(symbol, timeframe, idx);
      double lowM  = iLow(symbol, timeframe, idx);
      if(highM == 0 || lowM == 0) continue;

      if(lowM <= price + tol && highM >= price - tol)
         return iTime(symbol, timeframe, idx);
   }

   datetime t0 = iTime(symbol, timeframe, 0);
   if(t0 != 0) return (datetime)((long)t0 + (long)bar_secs);

   return TimeCurrent();
}

void DrawMss(string symbol, ENUM_TIMEFRAMES tf, const MSS &mss, int slot)
{
  if(!ShowSwingMarkers || !mss.found)
    return;

  string basePrefix = SwingObjPrefix + "MSS_" + IntegerToString(slot) + "_";

  // ===== clear old MSS objects for this slot =====
  int total = ObjectsTotal(0);
  for(int i = total - 1; i >= 0; i--)
  {
    string nm = ObjectName(0, i);
    if(StringFind(nm, basePrefix, 0) == 0)
      ObjectDelete(0, nm);
  }

  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  datetime bar_secs = (datetime)PeriodSeconds(tf);

  // =================================================
  // 1️⃣ DRAW SWEEP LABEL (wick)
  // =================================================
  if(mss.sweep_time != 0 && mss.sweep_extreme_price != 0.0)
  {
    string nmSweep = basePrefix + "SWEEP_" + IntegerToString((int)mss.sweep_time);

    if(ObjectCreate(0, nmSweep, OBJ_TEXT, 0,
                    mss.sweep_time, mss.sweep_extreme_price))
    {
      ObjectSetString(0, nmSweep, OBJPROP_TEXT, "SWEEP");
      ObjectSetInteger(0, nmSweep, OBJPROP_COLOR, clrMagenta);
      ObjectSetInteger(0, nmSweep, OBJPROP_FONTSIZE, SwingMarkerFontSize + 2);
      ObjectSetInteger(0, nmSweep, OBJPROP_BACK, true);
      ObjectSetInteger(0, nmSweep, OBJPROP_SELECTABLE, false);
    }
  }

  // =================================================
  // 2️⃣ DRAW MSS LABEL (BOS close)
  // =================================================
  if(mss.break_time != 0 && mss.bos_close_price != 0.0)
  {
    string nmMSS = basePrefix + "MSS_" + IntegerToString((int)mss.break_time);

    if(ObjectCreate(0, nmMSS, OBJ_TEXT, 0,
                    mss.break_time, mss.bos_close_price))
    {
      ObjectSetString(0, nmMSS, OBJPROP_TEXT, "MSS");
      ObjectSetInteger(0, nmMSS, OBJPROP_COLOR, clrOrange);
      ObjectSetInteger(0, nmMSS, OBJPROP_FONTSIZE, SwingMarkerFontSize + 2);
      ObjectSetInteger(0, nmMSS, OBJPROP_BACK, true);
      ObjectSetInteger(0, nmMSS, OBJPROP_SELECTABLE, false);
    }
  }

  // =================================================
  // 3️⃣ DRAW LIQUIDITY SWEEP GUIDE LINE
  // =================================================
  if(mss.swept_swing_time != 0 &&
     mss.swept_swing_price != 0.0 &&
     mss.sweep_time > mss.swept_swing_time)
  {
    string nmGuide = basePrefix + "GUIDE_" + IntegerToString((int)mss.sweep_time);

    if(ObjectCreate(0, nmGuide, OBJ_TREND, 0,
                    mss.swept_swing_time,
                    mss.swept_swing_price,
                    mss.sweep_time,
                    mss.swept_swing_price))
    {
      ObjectSetInteger(0, nmGuide, OBJPROP_COLOR, clrMagenta);
      ObjectSetInteger(0, nmGuide, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, nmGuide, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, nmGuide, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, nmGuide, OBJPROP_BACK, true);
      ObjectSetInteger(0, nmGuide, OBJPROP_SELECTABLE, false);
    }
  }

  // =================================================
  // 4️⃣ DRAW MSS BREAK (BOS) GUIDE LINE
  // =================================================
  if(mss.broken_swing_time != 0 &&
    mss.broken_swing_price != 0.0 &&
    mss.break_time != 0)
  {
    datetime t_start = mss.broken_swing_time;
    datetime t_end   = mss.break_time;

    // đảm bảo có độ dài để vẽ
    if(t_end == t_start)
      t_end = (datetime)((long)t_end + (long)bar_secs);

    string nmBreak = basePrefix + "BREAK_" + IntegerToString((int)mss.break_time);

    if(ObjectCreate(0, nmBreak, OBJ_TREND, 0,
                    t_start,
                    mss.broken_swing_price,
                    t_end,
                    mss.broken_swing_price))
    {
      ObjectSetInteger(0, nmBreak, OBJPROP_COLOR, clrOrange);
      ObjectSetInteger(0, nmBreak, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, nmBreak, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, nmBreak, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, nmBreak, OBJPROP_BACK, true);
      ObjectSetInteger(0, nmBreak, OBJPROP_SELECTABLE, false);
    }
  }
}

// Hàm tiện ích chuyển giá trị xu hướng thành chuỗi
string TrendToString(int trend)
{
  if(trend==1) return "UPTREND";
  if(trend==-1) return "DOWNTREND";
  return "SIDEWAY";
}

// Cập nhật TrendTF[slot] dựa trên 2 swing gần nhất (không gọi UpdateSwings bên trong)
void UpdateTrendForSlot(int slot, ENUM_TIMEFRAMES timeframe, string symbol)
{
  int oldTrend = TrendTF[slot];

  double pip = GetPipSize(symbol);
  double provisionalThresh = (double)ProvisionalBreakPips * pip;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  bool haveTwoSwings = (SwingHighCountTF[slot] >= 2 && SwingLowCountTF[slot] >= 2);

  double sh0 = (SwingHighCountTF[slot] >= 1) ? SwingHighPriceTF[slot][0] : 0.0;
  double sh1 = (SwingHighCountTF[slot] >= 2) ? SwingHighPriceTF[slot][1] : 0.0;
  double sl0 = (SwingLowCountTF[slot] >= 1) ? SwingLowPriceTF[slot][0] : 0.0;
  double sl1 = (SwingLowCountTF[slot] >= 2) ? SwingLowPriceTF[slot][1] : 0.0;

  int newTrend = oldTrend;

  if(haveTwoSwings)
  {
    if(sh0 > sh1 && sl0 > sl1) newTrend = 1;
    else if(sh0 < sh1 && sl0 < sl1) newTrend = -1;
    else newTrend = 0;
  }
  else
  {
    newTrend = oldTrend;
  }

  double lastClosedClose = iClose(symbol, timeframe, 1);
  if(lastClosedClose == 0.0) lastClosedClose = iClose(symbol, timeframe, 0);

  int provisionalTrend = 0;
  if(sh0 != 0.0 && lastClosedClose > sh0 + provisionalThresh)
    provisionalTrend = 1;
  else if(sl0 != 0.0 && lastClosedClose < sl0 - provisionalThresh)
    provisionalTrend = -1;

  if(provisionalTrend != 0)
  {
    int countClosers = 0;
    for(int i = 1; i <= ProvisionalConsecCloses; i++)
    {
      double c = iClose(symbol, timeframe, i);
      if(c == 0.0) break;
      if(provisionalTrend == 1)
      {
        if(c > sh0 + provisionalThresh) countClosers++;
        else break;
      }
      else
      {
        if(c < sl0 - provisionalThresh) countClosers++;
        else break;
      }
    }

    if(countClosers >= ProvisionalConsecCloses)
    {
      if(!haveTwoSwings || newTrend == 0)
      {
        newTrend = provisionalTrend;
      }
    }
  }

  TrendTF[slot] = newTrend;
}

int FindFVG(string symbol, ENUM_TIMEFRAMES timeframe, int lookback)
{
  // clear old array
  ArrayFree(FVGs);
  FVG_count = 0;

  int total = iBars(symbol, timeframe);
  if(total < 5) return 0;

  int maxScan = MathMin(lookback, total - 3);
  if(maxScan <= 0) return 0;

  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  for(int i = 1; i <= maxScan; i++)
  {
    int idxA = i + 2;
    int idxC = i;

    if(idxA > total - 1) break;

    double highA = iHigh(symbol, timeframe, idxA);
    double lowA  = iLow(symbol, timeframe, idxA);
    double highC = iHigh(symbol, timeframe, idxC);
    double lowC  = iLow(symbol, timeframe, idxC);

    if(highA == 0 || lowA == 0 || highC == 0 || lowC == 0) continue;

    // bullish FVG (lowC > highA)
    if(lowC > highA + tol)
    {
      double top = lowC;
      double bottom = highA;
      bool dup = false;
      for(int k = 0; k < FVG_count; k++)
      {
        if(MathAbs(FVGs[k].topPrice - top) <= tol && MathAbs(FVGs[k].bottomPrice - bottom) <= tol) { dup = true; break; }
      }
      if(!dup)
      {
        ArrayResize(FVGs, FVG_count+1);
        FVGs[FVG_count].type      = 1;
        FVGs[FVG_count].topPrice       = top;
        FVGs[FVG_count].bottomPrice    = bottom;
        FVGs[FVG_count].timebarA     = iTime(symbol, timeframe, idxA);
        FVGs[FVG_count].timebarC     = iTime(symbol, timeframe, idxC);
        FVGs[FVG_count].touched   = false;
        FVGs[FVG_count].touchTime = 0;
        FVGs[FVG_count].touchPrice= 0.0;
        FVG_count++;
      }
      continue;
    }

    // bearish FVG (highC < lowA)
    if(highC < lowA - tol)
    {
      double top = lowA;
      double bottom = highC;
      bool dup = false;
      for(int k = 0; k < FVG_count; k++)
      {
        if(MathAbs(FVGs[k].topPrice - top) <= tol && MathAbs(FVGs[k].bottomPrice - bottom) <= tol) { dup = true; break; }
      }
      if(!dup)
      {
        ArrayResize(FVGs, FVG_count+1);
        FVGs[FVG_count].type      = -1;
        FVGs[FVG_count].topPrice       = top;
        FVGs[FVG_count].bottomPrice    = bottom;
        FVGs[FVG_count].timebarA     = iTime(symbol, timeframe, idxA);
        FVGs[FVG_count].timebarC     = iTime(symbol, timeframe, idxC);
        FVGs[FVG_count].touched   = false;
        FVGs[FVG_count].touchTime = 0;
        FVGs[FVG_count].touchPrice= 0.0;
        FVG_count++;
      }
    }
  }

  return FVG_count;
}

uint MakeARGB(int a, uint clr)
{
  if(a < 0) a = 0; if(a > 255) a = 255;
  return ((uint)a << 24) | (clr & 0x00FFFFFF);
}

void DrawFVG(string symbol, ENUM_TIMEFRAMES timeframe, bool startFromCBar = true)
{
  if(!ShowSwingMarkers) return;
  string prefix = SwingObjPrefix + "FVG_";

  int tot = ObjectsTotal(0);
  for(int i = tot - 1; i >= 0; i--)
  {
    string nm = ObjectName(0, i);
    if(StringFind(nm, prefix, 0) == 0)
      ObjectDelete(0, nm);
  }

  if(FVG_count <= 0) return;

  datetime bar_secs = (datetime)PeriodSeconds(timeframe);

  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  for(int k = 0; k < FVG_count; k++)
  {
    double top = FVGs[k].topPrice;
    double bottom = FVGs[k].bottomPrice;
    datetime timeC = FVGs[k].timebarC;
    datetime timeA = FVGs[k].timebarA;

    datetime start_time = startFromCBar ? timeC : timeA;

    int idxC = iBarShift(symbol, timeframe, timeC, false);
    if(idxC == -1) idxC = 0;

    bool touched = false;
    datetime end_time = TimeCurrent();

    for(int idx = idxC - 1; idx >= 0; idx--)
    {
      double highM = iHigh(symbol, timeframe, idx);
      double lowM  = iLow(symbol, timeframe, idx);
      if(highM == 0 || lowM == 0) continue;

      if(lowM <= top + tol && highM >= bottom - tol)
      {
        touched = true;
        end_time = iTime(symbol, timeframe, idx);
        break;
      }
    }

    if(!touched)
    {
      datetime t0 = iTime(symbol, timeframe, 0);
      if(t0 != 0) end_time = t0 + bar_secs;
      else end_time = TimeCurrent();
    }

    if(end_time <= start_time) end_time = (datetime)( (long)start_time + (long)bar_secs );

    string obj = prefix + IntegerToString(k);

    if(!ObjectCreate(0, obj, OBJ_RECTANGLE, 0, start_time, top, end_time, bottom))
    {
      continue;
    }

    ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, obj, OBJPROP_HIDDEN, false);
    ObjectSetInteger(0, obj, OBJPROP_BACK, true);

    uint fill_alpha = 80;
    uint border_alpha = 0;

    uint color_fill;
    if(FVGs[k].type == 1) color_fill = MakeARGB((int)fill_alpha, clrDodgerBlue);
    else color_fill = MakeARGB((int)fill_alpha, clrCrimson);

    uint col_border = MakeARGB((int)border_alpha, clrBlack);

    ObjectSetInteger(0, obj, OBJPROP_COLOR, (int)col_border);
    ObjectSetInteger(0, obj, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, obj, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, obj, OBJPROP_COLOR, (int)color_fill);
  }
}

// ------------------------------------------------------------
// UpdateLabel: vẽ label cho 1 timeframe bất kỳ
// ------------------------------------------------------------
void UpdateLabel(string labelName, ENUM_TIMEFRAMES timeframe, int trend)
{
    if(!ShowSwingMarkers) return;

    string txt = StringFormat("%s: %s", EnumToString(timeframe), TrendToString(trend));

    int corner = CORNER_LEFT_UPPER;
    int xdist  = 10;
    int ydist_default = 20;
    int ydist = ydist_default;

    int offset_down = 30;
    if (timeframe == MiddleTF) ydist = ydist_default + offset_down;
    else if(timeframe == LowTF) ydist = ydist_default + offset_down * 2;

    if(ObjectFind(0, labelName) >= 0)
    {
        ObjectSetString(0, labelName, OBJPROP_TEXT, txt);
        if(trend == 1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrLime);
        else if(trend == -1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
        else ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrGray);
    }
    else
    {
        if(!ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0))
        {
            return;
        }
        ObjectSetInteger(0, labelName, OBJPROP_CORNER, corner);
        ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, xdist);
        ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, ydist);
        ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, SwingMarkerFontSize);
        ObjectSetString(0, labelName, OBJPROP_TEXT, txt);

        if(trend == 1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrLime);
        else if(trend == -1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
        else ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrGray);
    }
}

// Trả true nếu bar đóng mới xuất hiện (dựa vào iTime(...,1))
bool IsNewClosedBar(string symbol, ENUM_TIMEFRAMES tf, int slot)
{
  datetime t = iTime(symbol, tf, 1);
  if(t == -1 || t == 0) return false;
  if(t != lastClosedBarTime[slot])
  {
    lastClosedBarTime[slot] = t;
    return true;
  }
  return false;
}

void EnsureFVGUpToDate(string symbol, ENUM_TIMEFRAMES tf, int lookback)
{
  if(tf != MiddleTF) return;
  datetime currentClosed = iTime(symbol, tf, 1);
  if(currentClosed == -1 || currentClosed == 0) return;
  if(currentClosed != lastFVGBarTime)
  {
    FindFVG(symbol, tf, lookback);
    lastFVGBarTime = currentClosed;
  }
}

// VẼ các internal FVG trên timeframe tf nếu timeC nằm giữa sweep_time và break_time
void DrawInternalFVGMatches(string sym, ENUM_TIMEFRAMES tf, datetime sweep_time, datetime break_time, double pmin, double pmax, int lookback)
{
  // lấy tất cả internal FVG trên tf
  double tops[]; double bottoms[]; datetime timeA[]; datetime timeC[]; int types[];
  int cnt = FindInternalFVG(sym, tf, lookback, tops, bottoms, timeA, timeC, types);
  if(cnt <= 0) return;

  double point = SymbolInfoDouble(sym, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;
  datetime bar_secs = (datetime)PeriodSeconds(tf);

  for(int i=0; i<cnt; i++)
  {
    datetime tc = timeC[i];
    if(tc < sweep_time || tc > break_time) continue; // đảm bảo timeC strictly giữa sweep & break

    double top = tops[i];
    double bottom = bottoms[i];

    // kiểm tra overlap phần giá (nếu hoàn toàn ngoài cửa sổ pmin..pmax thì bỏ)
    if(bottom > pmax + tol || top < pmin - tol) continue;

    // tạo tên object duy nhất dựa trên timeC và index
    string nm = SwingObjPrefix + "INTFVG_" + IntegerToString(types[i]) + "_" + IntegerToString(i) + "_" + IntegerToString((int)tc);

    // Nếu đã tồn tại thì bỏ qua (tránh duplicate)
    if(ObjectFind(0, nm) >= 0) continue;

    // start từ bar A tới bar C + 1 bar để hiển thị rõ (tùy bạn có thể dùng timeA[i] hoặc timeC[i])
    datetime start_time = timeA[i];
    datetime end_time   = (datetime)((long)tc + (long)bar_secs); // show zone tới C bar end

    // Tạo rectangle
    if(!ObjectCreate(0, nm, OBJ_RECTANGLE, 0, start_time, top, end_time, bottom))
      continue;

    // set style similar DrawFVG
    uint fill_alpha = 80;
    uint color_fill = (types[i] == 1) ? MakeARGB((int)fill_alpha, C'229,255,30') : MakeARGB((int)fill_alpha, clrCrimson);
    uint col_border = MakeARGB(0, clrBlack);

    ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, nm, OBJPROP_HIDDEN, false);
    ObjectSetInteger(0, nm, OBJPROP_BACK, true);
    ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, nm, OBJPROP_STYLE, STYLE_SOLID);
    // fill color
    ObjectSetInteger(0, nm, OBJPROP_COLOR, (int)color_fill); // MQL may reuse OBJPROP_COLOR for fill here like in DrawFVG
  }
}

void DetectMSSOnTimeframe(
    string sym,
    ENUM_TIMEFRAMES tf,
    int slot,
    bool enabled,
    bool requireFVG,
    double minBreakPips,
    int consecRequired,
    int lookForwardBars,
    int fvgLookback
) {
  if(!enabled) return;
  if(BOS_Count[slot] < 2) return;

  // ===============================
  // 1️⃣ LẤY 2 BOS GẦN NHẤT & SẮP THỨ TỰ THỜI GIAN
  // ===============================
  BOSInfo b0 = BOSStore[slot][0];
  BOSInfo b1 = BOSStore[slot][1];

  BOSInfo olderBOS, newerBOS;
  if(b0.break_time < b1.break_time)
  {
      olderBOS = b0;
      newerBOS = b1;
  }
  else
  {
      olderBOS = b1;
      newerBOS = b0;
  }

  if(!olderBOS.found || !newerBOS.found) return;
  if(olderBOS.direction == newerBOS.direction) return;

  datetime sweep_time = olderBOS.break_time;
  datetime break_time = newerBOS.break_time;
  if(sweep_time == 0 || break_time == 0 || break_time <= sweep_time)
      return;

  // ===============================
  // 2️⃣ XÁC ĐỊNH GIÁ QUÉT THỰC (WICK)
  // ===============================
  int sweepIdx = iBarShift(sym, tf, sweep_time, false);
  if(sweepIdx < 0) return;

  double sweepExtreme = 0.0;
  if(newerBOS.direction == 1)
      sweepExtreme = iLow(sym, tf, sweepIdx);   // bullish MSS → quét LOW
  else
      sweepExtreme = iHigh(sym, tf, sweepIdx);  // bearish MSS → quét HIGH

  if(sweepExtreme == 0.0) return;

  // ===============================
  // 3️⃣ SWING BỊ QUÉT & SWING BỊ PHÁ
  // ===============================
  double sweptSwingPrice   = olderBOS.broken_sw_price;
  datetime sweptSwingTime  = olderBOS.broken_sw_time;

  double brokenSwingPrice  = newerBOS.broken_sw_price;
  datetime brokenSwingTime = newerBOS.broken_sw_time;
  if(sweptSwingPrice == 0.0 || brokenSwingPrice == 0.0)
      return;

  // ===============================
  // 4️⃣ KIỂM TRA MSS HỢP LỆ (ICT CORE)
  // ===============================
  double tol = GetPipSize(sym) * 0.1;

  if(newerBOS.direction == 1)
  {
      // Bullish MSS:
      // - Wick quét sâu hơn swing low
      // - Sau đó phá swing high
      if(sweepExtreme >= sweptSwingPrice - tol)
          return;
  }
  else
  {
      // Bearish MSS
      if(sweepExtreme <= sweptSwingPrice + tol)
          return;
  }

  // ===============================
  // 5️⃣ REQUIRE FVG (GIỮ LOGIC CŨ)
  // ===============================
  if(requireFVG)
  {
    if(tf == MiddleTF)
      EnsureFVGUpToDate(sym, tf, fvgLookback);

    bool hasFVG = false;
    if(newerBOS.direction == 1)
      hasFVG = HasBullFVGBetween(sym, tf, sweep_time, break_time, fvgLookback);
    else
      hasFVG = HasBearFVGBetween(sym, tf, sweep_time, break_time, fvgLookback);

    if(!hasFVG)
      return;
  }

  // ===============================
  // 6️⃣ TẠO MSS (STRUCT MỚI – CLEAN)
  // ===============================
  MSS mss;
  mss.found = true;
  mss.direction = newerBOS.direction;

  mss.sweep_time = sweep_time;
  mss.sweep_extreme_price = sweepExtreme;

  mss.swept_swing_time  = sweptSwingTime;
  mss.swept_swing_price = sweptSwingPrice;

  mss.break_time = break_time;
  mss.bos_close_price = newerBOS.break_price;

  mss.broken_swing_time  = brokenSwingTime;
  mss.broken_swing_price = brokenSwingPrice;

  // ===============================
  // 7️⃣ WATCHING MODE → ENTRY CHECK
  // ===============================
  if(watchingMSSMode && watchingFVGIndex >= 0)
  {
    if(mss.direction == watchingFVGDir)
    {
      bool valid = CheckValidEntry(
        mss.direction,
        TrendTF[0],   // HTF
        TrendTF[1],   // MTF
        watchingFVGIndex
      );

      if(valid)
      {
        if(PrintEntryLog)
          Print(">>> ENTRY CONDITIONS PASSED → SETUP ENTRY");

        watchingMSSMode = false;
        watchingFVGIndex = -1;
        watchingFVGDir = 0;

        SetUpPendingEntryForMSS(mss, slot);
      }
      else
      {
        if(PrintEntryLog)
          Print(">>> ENTRY BLOCKED by CheckValidEntry()");
      }
    }
  }

  // ===============================
  // 8️⃣ VẼ MSS
  // ===============================
  DrawMss(sym, tf, mss, slot);
}

bool CheckValidEntry(
  int mssDirection,
  int htfTrend,
  int mtfTrend,
  int fvgIndex
)
{
  // =============================
  // 0. Sanity check
  // =============================
  if(mssDirection == 0)
    return false;

  // HTF phải có trend rõ ràng
  if(htfTrend == 0)
  {
    if(PrintEntryLog)
      Print("CheckValidEntry FAIL: HTF is SIDEWAY");
    return false;
  }

  if(fvgIndex < 0 || fvgIndex >= FVG_count)
  {
    if(PrintEntryLog)
      Print("CheckValidEntry: invalid FVG index");
    return false;
  }

  int fvgDir = FVGs[fvgIndex].type; // 1 bull, -1 bear

  // =============================
  // 1. MSS direction == FVG direction
  // (thường đã đúng do watchingMSSMode,
  // nhưng giữ lại cho chắc)
  // =============================
  if(mssDirection != fvgDir)
  {
    if(PrintEntryLog)
      PrintFormat(
        "CheckValidEntry FAIL: MSS dir=%d != FVG dir=%d",
        mssDirection, fvgDir
      );
    return false;
  }

  // =============================
  // 2. FVG direction thuận MTF trend
  // =============================
  if(mtfTrend != 0 && fvgDir != mtfTrend)
  {
    if(PrintEntryLog)
      PrintFormat(
        "CheckValidEntry FAIL: FVG dir=%d not aligned with MTF trend=%d",
        fvgDir, mtfTrend
      );
    return false;
  }

  // =============================
  // 3. MTF trend thuận HTF trend
  // =============================
  if(htfTrend != 0 && mtfTrend != 0 && htfTrend != mtfTrend)
  {
    if(PrintEntryLog)
      PrintFormat(
        "CheckValidEntry FAIL: MTF trend=%d not aligned with HTF trend=%d",
        mtfTrend, htfTrend
      );
    return false;
  }

  // =============================
  // PASS ALL CONDITIONS
  // =============================
  if(PrintEntryLog)
  {
    PrintFormat(
      "CheckValidEntry PASS: dir=%d | FVG=%d | MTF trend=%d | HTF trend=%d",
      mssDirection, fvgDir, mtfTrend, htfTrend
    );
  }

  return true;
}

void HandleLogicForTimeframe(string sym, ENUM_TIMEFRAMES tf, int slot, bool detectMSS,
                                     int swingRange, bool requireFVG,
                                     double minBreakPips, int minConsec,
                                     int lookbackBarsForSweep, int fvgLookback)
{
  UpdateSwings(sym, tf, slot, swingRange);
  UpdateTrendForSlot(slot, tf, sym);
  HandleBOSDetections(sym, tf, slot);

  if(tf == MiddleTF) EnsureFVGUpToDate(sym, MiddleTF, fvgLookback);
  DetectMSSOnTimeframe(sym, tf, slot, detectMSS, requireFVG, minBreakPips, minConsec, lookbackBarsForSweep, fvgLookback);

  if(ShowSwingMarkers)
  {
    if (tf == LowTF) DrawSwingsOnChart(tf);
    if(tf == MiddleTF) DrawFVG(sym, MiddleTF, true);
  }

  UpdateLabel((tf == HighTF) ? "LBL_HTF" : (tf == MiddleTF) ? "LBL_MTF" : "LBL_LTF", tf, TrendTF[slot]);
}

// Clear & reset pending entry (xóa visuals nếu có)
void ClearPendingEntry()
{
  if(!pendingEntry.active && StringLen(pendingEntry.compositeName)==0)
  {
    return;
  }

  if(StringLen(pendingEntry.compositeName) > 0)
  {
    string parts[];
    int n = StringSplit(pendingEntry.compositeName, '|', parts);
    for(int i=0;i<n;i++)
    {
      string nm = parts[i];
      if(StringLen(nm) > 0 && ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
    }
  }

  pendingEntry.active = false;
  pendingEntry.direction = 0;
  pendingEntry.price = 0.0;
  pendingEntry.fvgIndex = -1;
  pendingEntry.compositeName = "";
  pendingEntry.created_time = 0;
  pendingEntry.source_slot = -1;

  if(PrintEntryLog) Print("PendingEntry CLEARED");
}

// CalculateLotSizeForRisk:
// - symbol: symbol
// - entryPrice, slPrice: điểm entry và sl (giá thực tế)
// - riskPercent: ví dụ 1.0 cho 1% equity
// Trả về lotsize phù hợp (đã được clamp theo min/max/step)
double CalculateLotSizeForRisk(string symbol, double entryPrice, double slPrice, double riskPercent)
{
  double pipValue = GetPipSize(symbol); // 1 pip in price units
  double distance = MathAbs(entryPrice - slPrice); // in price units
  if(distance <= 0.0) return 0.0;

  // Use account equity as base
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  if(equity <= 0.0) equity = AccountInfoDouble(ACCOUNT_BALANCE);
  if(equity <= 0.0) return 0.0;

  double riskAmount = equity * (riskPercent / 100.0);

  // Obtain tick size/value info from symbol
  double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
  double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

  // Defensive fallback: if tick_size/tick_value unavailable, try point-based approximation
  double valuePerPointPerLot = 0.0;
  if(tick_size > 0.0 && tick_value > 0.0)
  {
    valuePerPointPerLot = tick_value / tick_size;
  }
  else
  {
    // approximate: use point and contract size
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    // assume valuePerPointPerLot ~ 10 (very rough) -> but better to abort
    // safer: abort by returning 0 if we don't have reliable tick info
    return 0.0;
  }

  // value risk per lot = distance (price units) * valuePerPointPerLot
  double valueRiskPerLot = distance * valuePerPointPerLot;
  if(valueRiskPerLot <= 0.0) return 0.0;

  double lots = riskAmount / valueRiskPerLot;

  // clamp to symbol lot limits and step
  double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
  double stepLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

  if(minLot <= 0.0 || stepLot <= 0.0)
  {
    // fallback defaults if broker info missing
    minLot = 0.01;
    stepLot = 0.01;
    maxLot = 100.0;
  }

  // Normalize lots to nearest step
  double stepInv = MathRound(lots / stepLot);
  double lotsNorm = stepInv * stepLot;

  // ensure within min/max
  if(lotsNorm < minLot) lotsNorm = minLot;
  if(lotsNorm > maxLot) lotsNorm = maxLot;

  // final safety: round to allowed decimals (step determines decimals)
  int stepDigits = 0;
  {
    double tmp = stepLot;
    while(tmp < 1.0 && stepDigits < 8)
    {
      tmp *= 10.0;
      stepDigits++;
    }
  }
  lotsNorm = NormalizeDouble(lotsNorm, stepDigits);

  return lotsNorm;
}

// PlacePendingOrderFromPendingEntry:
// - Gọi DrawPendingEntryVisuals để vẽ entry/sl/tp
// - Gửi pending order (BUY_LIMIT nếu pendingEntry.direction==1, SELL_LIMIT nếu -1)
// - Lưu ticket vào pendingEntry.order_ticket nếu thành công
// - Trả về true nếu order đặt thành công, false nếu lỗi
bool PlacePendingOrderFromPendingEntry()
{
  string sym = Symbol();

  if(!pendingEntry.active)
  {
    if(PrintEntryLog) Print("PlacePendingOrderFromPendingEntry: abort - pendingEntry.active == false");
    return false;
  }

  if(pendingEntry.price <= 0.0 || pendingEntry.lotSize <= 0.0)
  {
    if(PrintEntryLog) PrintFormat("PlacePendingOrderFromPendingEntry: abort - invalid price/lotsize (price=%.10f lots=%.4f)", pendingEntry.price, pendingEntry.lotSize);
    return false;
  }

  // Chuẩn bị trade request
  MqlTradeRequest request;
  MqlTradeResult  result;
  ZeroMemory(request);
  ZeroMemory(result);

  request.action   = TRADE_ACTION_PENDING; // đặt lệnh pending
  request.symbol   = sym;
  request.volume   = pendingEntry.lotSize;
  request.deviation= 10; // acceptable slippage in points (bạn chỉnh nếu muốn)
  request.magic    = 123456; // chỉnh magic number nếu bạn dùng khác
  request.comment  = "PEND_BY_MSS_OB";

  // normalize prices
  int digs = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
  double price = NormalizeDouble(pendingEntry.price, digs);
  double sl    = (pendingEntry.sl_price != 0.0) ? NormalizeDouble(pendingEntry.sl_price, digs) : 0.0;
  double tp    = (pendingEntry.tp_price != 0.0) ? NormalizeDouble(pendingEntry.tp_price, digs) : 0.0;

  if(pendingEntry.direction == 1)
  {
    request.type = ORDER_TYPE_BUY_LIMIT;
    request.price = price;
  }
  else
  {
    request.type = ORDER_TYPE_SELL_LIMIT;
    request.price = price;
  }

  // set stoploss/takeprofit as absolute prices
  request.sl = sl;
  request.tp = tp;

  // optional: set expiration (0 = good till canceled)
  request.expiration = 0;

  // 3) Send request
  if(!OrderSend(request, result))
  {
    // OrderSend failed to execute (interface error)
    if(PrintEntryLog) PrintFormat("PlacePendingOrderFromPendingEntry: OrderSend() returned false. result.retcode=%d retcode_external=%d", result.retcode, result.retcode_external);
    return false;
  }

  // 4) Check result.retcode for success codes (10009 etc.)
  // Success for pending order is typically TRADE_RETCODE_DONE (10008) or TRADE_RETCODE_DONE_REMAINDER etc.
  if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED || result.retcode == 10006 || result.retcode == 10008 || result.retcode == 10009)
  {
    // store ticket
    pendingEntry.orderTicket = result.order;
    if(PrintEntryLog) PrintFormat("PlacePendingOrderFromPendingEntry: SUCCESS ticket=%I64u (retcode=%d) entry=%.10f sl=%.10f tp=%.10f lots=%.4f",
                                  pendingEntry.orderTicket, result.retcode, price, sl, tp, pendingEntry.lotSize);
    return true;
  }
  else
  {
    // failure; log reason
    if(PrintEntryLog)
    {
      PrintFormat("PlacePendingOrderFromPendingEntry: FAILED retcode=%d retval=%d result_comment=%s",
                  result.retcode, result.retcode, result.comment);
    }
    return false;
  }
}

// SetUpPendingEntryForMSS: new implementation using OrderBlock (last opposite-color candle before break)
// - mss: MSS found
// - slot: slot where MSS detected
// Logic:
// 1) Find OrderBlock (OB) = first opposite-color candle when scanning backward from mss.break_time (exclusive).
//    - bullish MSS (mss.direction == 1): find first bearish candle (close < open) when scanning backward from break_time
//    - bearish MSS (mss.direction == -1): find first bullish candle (close > open) when scanning backward from break_time
// 2) Entry = OB edge (high for bearish candle (bullish OB), low for bullish candle (bearish OB))
// 3) SL = Entry +/- 300 pips (bullish: SL = entry - 300 pips; bearish: SL = entry + 300 pips)
// 4) TP computed using RiskRewardRatio as before (TP = entry ± R:R*|entry-sl|)
// 5) Calculate lotsize such that risk = 1% equity (use CalculateLotSizeForRisk)
// 6) Store into pendingEntry and draw visuals
void SetUpPendingEntryForMSS(const MSS &mss, int slot)
{
  string sym = Symbol();

  if(PrintEntryLog)
    PrintFormat("==> SetUpPendingEntryForMSS (NEW) START: mss.found=%d dir=%d sweep_time=%d sweep_price=%.10f break_time=%d break_price=%.10f",
                mss.found ? 1 : 0, mss.direction, (int)mss.sweep_time, mss.sweep_extreme_price, (int)mss.break_time, mss.bos_close_price);

  if(!mss.found)
  {
    if(PrintEntryLog) Print("-> abort: mss.found == false");
    return;
  }
  if(mss.break_time == 0)
  {
    if(PrintEntryLog) Print("-> abort: invalid break_time");
    return;
  }

  // 1) Find OrderBlock (scan backward on LowTF from break_time - 1 bar)
  int idxStart = iBarShift(sym, LowTF, mss.break_time, false);
  if(idxStart == -1) idxStart = 0;

  int foundIdx = -1;
  double obEdgePrice = 0.0; // entry price (edge)
  int obDirection = 0; // 1 = bullish candle (close>open), -1 = bearish candle (close<open)

  // Start scanning previous bars strictly before break_time -> start at idxStart (bar whose time == break_time) then go idxStart+1 ??? 
  // iBarShift returns index (0 = current), bar with time==break_time likely index > 0. We want bars older than break_time so begin idx = idxStart (if that bar equals break_time) then idx = idxStart
  // Safer: we want bars with time < break_time, so shift to idx = idxStart (if that index's time == break_time then idx++), but iBarShift(...,false) returns exact index.
  // We'll start scanning from idx = idxStart (which should point to the bar with time==break_time) and step forward (older) idx+1, idx+2...
  int scanIdx = idxStart;
  // move one bar older to ensure strictly before break_time
  scanIdx = scanIdx + 1;

  int maxScan = 50; // cap scanning to avoid infinite loops (you can adjust)
  int scanned = 0;
  for(int idx = scanIdx; idx < iBars(sym, LowTF) && scanned < maxScan; idx++, scanned++)
  {
    double o = iOpen(sym, LowTF, idx);
    double c = iClose(sym, LowTF, idx);
    if(o == 0.0 || c == 0.0) continue;

    if(mss.direction == 1)
    {
      // bullish MSS: find first bearish candle going backward => candle where close < open (bearish)
      if(c < o)
      {
        foundIdx = idx;
        obDirection = -1;
        obEdgePrice = iHigh(sym, LowTF, idx); // use high of that bearish candle as OB edge
        break;
      }
    }
    else if(mss.direction == -1)
    {
      // bearish MSS: find first bullish candle (close > open)
      if(c > o)
      {
        foundIdx = idx;
        obDirection = 1;
        obEdgePrice = iLow(sym, LowTF, idx); // use low of that bullish candle as OB edge
        break;
      }
    }
  }

  if(foundIdx == -1)
  {
    if(PrintEntryLog) Print("-> abort: no suitable OrderBlock (opposite-color candle) found before break_time on LowTF");
    return;
  }

  // Normalize entry price to symbol digits
  int digs = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
  double entryPrice = NormalizeDouble(obEdgePrice, digs);

  if(PrintEntryLog)
    PrintFormat("-> Found OB at index=%d time=%s dir=%d edge=%.10f (normalized=%.10f)",
                foundIdx, TimeToString(iTime(sym, LowTF, foundIdx), TIME_DATE|TIME_MINUTES), obDirection, obEdgePrice, entryPrice);

  // 2) Set SL = entry +/- 300 pips
  double pip = GetPipSize(sym);
  double sl;
  double slDistancePoints = 300.0 * pip;
  if(mss.direction == 1)
  {
    // bullish MSS -> we will BUY at entry=OB(high) -> SL below OB
    sl = entryPrice - slDistancePoints;
  }
  else
  {
    // bearish MSS -> SELL at entry=OB(low) -> SL above OB
    sl = entryPrice + slDistancePoints;
  }
  sl = NormalizeDouble(sl, digs);

  // 3) Compute TP using RiskRewardRatio (existing input)
  double tp = 0.0;
  double diff = MathAbs(entryPrice - sl);
  if(diff > 0.0)
  {
    if(mss.direction == 1)
      tp = entryPrice + RiskRewardRatio * diff;
    else
      tp = entryPrice - RiskRewardRatio * diff;
    tp = NormalizeDouble(tp, digs);
  }
  else
  {
    if(PrintEntryLog) Print("-> abort: computed diff==0 between entry and SL");
    return;
  }

  // 4) Calculate lotsize based on 1% equity risk (hard-coded 1% per your request)
  double lots = CalculateLotSizeForRisk(sym, entryPrice, sl, 1.0); // 1% equity
  if(lots <= 0.0)
  {
    if(PrintEntryLog) Print("-> abort: CalculateLotSizeForRisk returned 0.0 (cannot determine lotsize)");
    return;
  }

  // 5) Clear previous pending and populate new pendingEntry
  ClearPendingEntry();

  pendingEntry.active = true;
  pendingEntry.direction = (mss.direction == 1) ? 1 : -1;
  pendingEntry.price = entryPrice;
  pendingEntry.fvgIndex = -1; // not using FVG for this method
  pendingEntry.created_time = TimeCurrent();
  pendingEntry.compositeName = "";
  pendingEntry.source_slot = slot;
  pendingEntry.sl_price = sl;
  pendingEntry.tp_price = tp;
  pendingEntry.lotSize = lots;
  pendingEntry.orderTicket = 0;

    // attempt to place pending order immediately
  if(PrintEntryLog) Print("Attempting to place pending order from pendingEntry...");
  bool ok = PlacePendingOrderFromPendingEntry();
  if(!ok)
    Print("Failed to place pending order (check broker settings, tick/tickvalue availability, volume limits).");


  if(PrintEntryLog)
  {
    PrintFormat("-> PendingEntry populated (OB method): dir=%d entry=%.10f sl=%.10f tp=%.10f lots=%.4f created=%s",
                pendingEntry.direction, pendingEntry.price, pendingEntry.sl_price, pendingEntry.tp_price,
                pendingEntry.lotSize, TimeToString(pendingEntry.created_time, TIME_DATE|TIME_SECONDS));
  }

  if(PrintEntryLog) Print("==> SetUpPendingEntryForMSS (NEW) END");
}

void MoveStoploss()
{
  string sym = Symbol();

  // EA chỉ quản lý 1 position cho symbol hiện tại
  if(!PositionSelect(sym))
    return;

  ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
  ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

  double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  double sl    = PositionGetDouble(POSITION_SL);
  double tp    = PositionGetDouble(POSITION_TP);

  if(entry <= 0.0 || sl <= 0.0)
    return;

  // Nếu SL đã >= entry (BUY) hoặc <= entry (SELL) → đã BE rồi
  if(type == POSITION_TYPE_BUY && sl >= entry)
    return;
  if(type == POSITION_TYPE_SELL && sl <= entry)
    return;

  double R = MathAbs(entry - sl);
  if(R <= 0.0)
    return;

  double bid = SymbolInfoDouble(sym, SYMBOL_BID);
  double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

  bool shouldMove = false;

  // ======= ĐIỀU KIỆN BE DỰA TRÊN moveSLRange =======
  if(type == POSITION_TYPE_BUY)
  {
    if(bid >= entry + moveSLRange * R)
      shouldMove = true;
  }
  else if(type == POSITION_TYPE_SELL)
  {
    if(ask <= entry - moveSLRange * R)
      shouldMove = true;
  }

  if(!shouldMove)
    return;

  // ---- MODIFY POSITION SL -> ENTRY ----
  MqlTradeRequest req;
  MqlTradeResult  res;
  ZeroMemory(req);
  ZeroMemory(res);

  req.action   = TRADE_ACTION_SLTP;
  req.position = ticket;
  req.symbol   = sym;
  req.sl       = NormalizeDouble(entry, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
  req.tp       = tp; // giữ nguyên TP

  if(!OrderSend(req, res))
  {
    if(PrintEntryLog)
      PrintFormat("MoveStoploss: OrderSend failed ticket=%I64u", ticket);
    return;
  }

  if(res.retcode == TRADE_RETCODE_DONE)
  {
    if(PrintEntryLog)
      PrintFormat("MoveStoploss: SL moved to BE at %.5f (%.2fR), ticket=%I64u",
                  entry, moveSLRange, ticket);
  }
  else
  {
    if(PrintEntryLog)
      PrintFormat("MoveStoploss: failed retcode=%d ticket=%I64u",
                  res.retcode, ticket);
  }
}

void CancelExpiredLimitOrder()
{
  if(!pendingEntry.active) return;
  if(pendingEntry.orderTicket == 0) return;
  if(pendingEntry.created_time == 0) return;

  ulong ticket = pendingEntry.orderTicket;

  // Nếu order không còn tồn tại → đã khớp hoặc bị xóa
  if(!OrderSelect(ticket))
  {
    if(PrintEntryLog)
      Print("Pending LIMIT no longer exists → cleared");

    ClearPendingEntry();
    return;
  }

  ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

  // Chỉ xử lý LIMIT
  if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT)
    return;

  datetime now = TimeCurrent();
  int aliveSec = (int)(now - pendingEntry.created_time);
  int maxSec   = MaxLimitOrderTime * 60;

  if(aliveSec < maxSec)
    return; // chưa quá hạn

  // ---- HỦY LỆNH LIMIT ----
  MqlTradeRequest req;
  MqlTradeResult  res;
  ZeroMemory(req);
  ZeroMemory(res);

  req.action = TRADE_ACTION_REMOVE;
  req.order  = ticket;

  if(!OrderSend(req, res))
  {
    if(PrintEntryLog)
      PrintFormat("Cancel LIMIT failed (OrderSend=false), ticket=%I64u", ticket);
    return;
  }

  if(res.retcode == TRADE_RETCODE_DONE)
  {
    if(PrintEntryLog)
      PrintFormat("LIMIT cancelled after %d minutes, ticket=%I64u",
                  MaxLimitOrderTime, ticket);

    ClearPendingEntry();
  }
  else
  {
    if(PrintEntryLog)
      PrintFormat("Cancel LIMIT failed retcode=%d ticket=%I64u",
                  res.retcode, ticket);
  }
}

void MoveStoplossAdvanced()
{
  string sym = Symbol();

  // chỉ quản lý 1 position cho symbol
  if(!PositionSelect(sym))
    return;

  ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
  ENUM_POSITION_TYPE type =
    (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

  double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  double sl    = PositionGetDouble(POSITION_SL);
  double tp    = PositionGetDouble(POSITION_TP);

  if(entry <= 0.0 || sl <= 0.0)
    return;

  // ===== R BAN ĐẦU =====
  double R = MathAbs(entry - sl);
  if(R <= 0.0)
    return;

  double bid = SymbolInfoDouble(sym, SYMBOL_BID);
  double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

  // ===== PROFIT HIỆN TẠI (theo R) =====
  double profitR = 0.0;
  if(type == POSITION_TYPE_BUY)
    profitR = (bid - entry) / R;
  else
    profitR = (entry - ask) / R;

  // ===== CHƯA ĐỦ ĐIỀU KIỆN BE =====
  if(profitR < moveSLStartR)
    return;

  int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
  double newSL = sl;

  // =========================================================
  // 1️⃣ BE PHASE
  // =========================================================
  if(profitR >= moveSLStartR && profitR < (moveSLStartR + trailOffsetR))
  {
    newSL = entry;
  }
  else
  {
    // =========================================================
    // 2️⃣ STEP TRAIL PHASE (theo bậc R)
    // =========================================================
    int step = (int)MathFloor(
      (profitR - moveSLStartR) / trailOffsetR
    );

    double targetR = step * trailOffsetR;

    if(type == POSITION_TYPE_BUY)
      newSL = entry + targetR * R;
    else
      newSL = entry - targetR * R;
  }

  newSL = NormalizeDouble(newSL, digits);

  // ===== KHÔNG CHO SL ĐI LÙI =====
  if(type == POSITION_TYPE_BUY && newSL <= sl)
    return;
  if(type == POSITION_TYPE_SELL && newSL >= sl)
    return;

  // ===== GỬI MODIFY =====
  MqlTradeRequest req;
  MqlTradeResult  res;
  ZeroMemory(req);
  ZeroMemory(res);

  req.action   = TRADE_ACTION_SLTP;
  req.position = ticket;
  req.symbol   = sym;
  req.sl       = newSL;
  req.tp       = tp;

  if(!OrderSend(req, res))
  {
    if(PrintEntryLog)
      PrintFormat("MoveSL ICT-C: OrderSend failed ticket=%I64u", ticket);
    return;
  }

  if(res.retcode == TRADE_RETCODE_DONE && PrintEntryLog)
  {
    PrintFormat(
      "MoveSL ICT-C: SL -> %.5f | profitR=%.2fR | step=%d",
      newSL, profitR, 
      (int)MathFloor((profitR - moveSLStartR) / trailOffsetR)
    );
  }
}

void OnTick()
{
  string sym = Symbol();

  CancelExpiredLimitOrder();
  if (moveSLRange > 0) {
    // MoveStoploss();
    // MoveStoplossAdvanced();
  }

  if(IsNewClosedBar(sym, HighTF, 0)) {
    HandleLogicForTimeframe(sym, HighTF, 0, DetectMSS_HTF, htfSwingRange, false, 10.0, 2, 50, FVGLookback);
  }

  if(IsNewClosedBar(sym, MiddleTF, 1)) {
    HandleLogicForTimeframe(sym, MiddleTF, 1, DetectMSS_MTF, mtfSwingRange, true, 10.0, 2, 50, FVGLookback);
  }

  if(IsNewClosedBar(sym, LowTF, 2)) {
    HandleLogicForTimeframe(sym, LowTF, 2, DetectMSS_LTF, ltfSwingRange, true, 10.0, 2, 50, FVGLookback);
    if (watchingMSSMode) {
      CheckWatchMSSInvalidation(sym);
    }
  }

  UpdateMTFFVGTouched(sym);
}

int OnInit()
{
  string sym = Symbol();
  HandleLogicForTimeframe(sym, HighTF, 0, false, htfSwingRange, false, 10.0, 2, 50, FVGLookback);
  HandleLogicForTimeframe(sym, MiddleTF, 1, false, mtfSwingRange, true, 10.0, 2, 50, FVGLookback);
  HandleLogicForTimeframe(sym, LowTF, 2, false, ltfSwingRange, false, 10.0, 2, 50, FVGLookback);

  return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
  for(int s=0; s<3; s++)
  {
    for(int j=0; j<2; j++)
    {
      if(StringLen(BOS_Names[s][j]) > 0) DeleteCompositeBOS(BOS_Names[s][j]);
      BOS_Names[s][j] = "";
      BOS_Count[s] = 0;
      BOSStore[s][j].found = false;
      BOS_HaveZone[s][j] = false;
    }
  }

  if(ObjectFind(0, "LBL_HTF") >= 0) ObjectDelete(0, "LBL_HTF");
  if(ObjectFind(0, "LBL_MTF") >= 0) ObjectDelete(0, "LBL_MTF");
  if(ObjectFind(0, "LBL_LTF") >= 0) ObjectDelete(0, "LBL_LTF");

  int tot = ObjectsTotal(0);
  for(int i = tot - 1; i >= 0; i--)
  {
    string nm = ObjectName(0, i);
    if(StringFind(nm, SwingObjPrefix, 0) == 0)
      ObjectDelete(0, nm);
  }
}
