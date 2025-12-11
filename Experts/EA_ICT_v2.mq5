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

// --- Cấu hình Risk:Reward ---
input double RiskRewardRatio = 3.0;   // tỉ lệ R:R mặc định (TP = entry ± RiskRewardRatio * |entry - SL|)

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

// Cấu hình Swing
input int           htfSwingRange = 2;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           mtfSwingRange = 3;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           ltfSwingRange = 5;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           MaxSwingKeep = 2;            // Số đỉnh/đáy gần nhất cần lưu (bạn yêu cầu 2)

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

// struct dùng để trả thông tin khi phát hiện MSS
struct MSSInfo {
  bool  found;                 // true nếu tìm thấy MSS
  int   direction;             //  1 = down->up (bull MSS), -1 = up->down (bear MSS)
  datetime sweep_time;         // thời điểm bar "sweep" (bar quét thanh khoản)
  double sweep_price;          // giá swing gốc bị phá
  // --- thêm: swing gốc đã bị swept (time/price) ---
  datetime swept_swing_time;   // time của swing bar trước khi bị sweep (ví dụ l0/h0 tại thời điểm detect)
  double   swept_swing_price;  // giá swing gốc

  double key_level;            // mức key level (swing cần phá)
  datetime break_time;         // thời điểm bar phá key level (thỏa điều kiện break)
  double   break_price;        // **giá đóng của bar breaker** (mới thêm)

  // --- thêm: swing gốc bị broken (time/price) ---
  datetime broken_swing_time;  // time của swing bar bị phá (ví dụ sh0/sl0 tại thời điểm detect)
  double   low_sweap_price; // giá đóng nến của bos
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
      int idxB = i + 1; // thực ra không cần B trong phép tính nhưng vẫn để đúng mô hình
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

void DrawMss(string symbol, ENUM_TIMEFRAMES tf, const MSSInfo &mss, int slot)
{
    if(!ShowSwingMarkers || !mss.found)
        return;

    string basePrefix = SwingObjPrefix + "MSS_" + IntegerToString(slot) + "_";

    int total = ObjectsTotal(0);
    for(int i = total - 1; i >= 0; i--)
    {
        string nm = ObjectName(0, i);
        if(StringFind(nm, basePrefix, 0) == 0)
            ObjectDelete(0, nm);
    }

    datetime bar_secs = (datetime)PeriodSeconds(tf);

    if(mss.sweep_time != 0 && mss.sweep_price != 0.0)
    {
        string lblSweep = basePrefix + "SWEEP";
        datetime t_sweep = mss.sweep_time;

        if(ObjectCreate(0, lblSweep, OBJ_TEXT, 0, t_sweep, mss.sweep_price))
        {
            ObjectSetString(0,  lblSweep, OBJPROP_TEXT, "SWEEP");
            ObjectSetInteger(0, lblSweep, OBJPROP_COLOR, clrMagenta);
            ObjectSetInteger(0, lblSweep, OBJPROP_FONTSIZE, SwingMarkerFontSize + 2);
            ObjectSetInteger(0, lblSweep, OBJPROP_BACK, true);
            ObjectSetInteger(0, lblSweep, OBJPROP_SELECTABLE, false);
        }
    }

    if(mss.break_time != 0 && mss.break_price != 0.0)
    {
        string lblMss = basePrefix + "MSS";
        datetime t_mss = mss.break_time;

        if(ObjectCreate(0, lblMss, OBJ_TEXT, 0, t_mss, mss.break_price))
        {
            ObjectSetString(0, lblMss, OBJPROP_TEXT, "MSS");
            ObjectSetInteger(0, lblMss, OBJPROP_COLOR, clrOrange);
            ObjectSetInteger(0, lblMss, OBJPROP_FONTSIZE, SwingMarkerFontSize + 2);
            ObjectSetInteger(0, lblMss, OBJPROP_BACK, true);
            ObjectSetInteger(0, lblMss, OBJPROP_SELECTABLE, false);
        }
    }

    datetime t_swing = mss.swept_swing_time;
    double   p_swing = mss.swept_swing_price;

    if(t_swing == 0 || p_swing == 0.0)
    {
        if(mss.broken_swing_time != 0 && mss.low_sweap_price != 0.0)
        {
            t_swing = mss.broken_swing_time;
            p_swing = mss.low_sweap_price;
        }
        else if(mss.sweep_time != 0 && mss.sweep_price != 0.0)
        {
            t_swing = mss.sweep_time - bar_secs;
            p_swing = mss.sweep_price;
        }
    }

    if(t_swing != 0 && p_swing != 0.0 && mss.sweep_time != 0)
    {
        string lineName = basePrefix + "GUIDE_" + IntegerToString((int)mss.sweep_time);

        if(!ObjectCreate(0, lineName, OBJ_TREND, 0, t_swing, p_swing, mss.sweep_time, p_swing))
        {
            // silent
        }
        else
        {
            ObjectSetInteger(0, lineName, OBJPROP_COLOR, clrMagenta);
            ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, lineName, OBJPROP_BACK, true);
        }

        string valLabel = basePrefix + "GUIDE_VAL_" + IntegerToString((int)mss.sweep_time);
        if(!ObjectCreate(0, valLabel, OBJ_TEXT, 0, mss.sweep_time, p_swing))
        {
            // ignore
        }
        else
        {
            string txt = DoubleToString(p_swing, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
            ObjectSetString(0, valLabel, OBJPROP_TEXT, txt);
            ObjectSetInteger(0, valLabel, OBJPROP_COLOR, clrMagenta);
            ObjectSetInteger(0, valLabel, OBJPROP_FONTSIZE, SwingMarkerFontSize - 1);
            ObjectSetInteger(0, valLabel, OBJPROP_BACK, true);
            ObjectSetInteger(0, valLabel, OBJPROP_SELECTABLE, false);
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
    if(tc <= sweep_time || tc >= break_time) continue; // đảm bảo timeC strictly giữa sweep & break

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
    uint color_fill = (types[i] == 1) ? MakeARGB((int)fill_alpha, clrDodgerBlue) : MakeARGB((int)fill_alpha, clrCrimson);
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

void DetectMSSOnTimeframe(string sym, ENUM_TIMEFRAMES tf, int slot, bool enabled,
                       bool requireFVG,
                       double minBreakPips,
                       int consecRequired,
                       int lookForwardBars,
                       int fvgLookback)
{
    if(!enabled) return;
    if(BOS_Count[slot] < 2) return;

    BOSInfo a = BOSStore[slot][0];
    BOSInfo b = BOSStore[slot][1];
    BOSInfo older = a, newer = b;
    if(a.break_time == 0 || b.break_time == 0)
    {
      older = BOSStore[slot][1];
      newer = BOSStore[slot][0];
    }
    else
    {
      if(a.break_time <= b.break_time) { older = a; newer = b; }
      else { older = b; newer = a; }
    }

    if(!older.found || !newer.found) return;
    if(older.direction == newer.direction) return;

    // Lấy sweep/break price sớm (phải có trước khi dùng pmin/pmax)
    double sweep_price = older.broken_sw_price;
    double break_price = newer.broken_sw_price;

    if(requireFVG)
    {
      // nếu TF là MiddleTF thì đảm bảo danh sách MTF FVG mới nhất
      if(tf == MiddleTF) EnsureFVGUpToDate(sym, tf, fvgLookback);

      datetime sweep_time = older.break_time;
      datetime break_time = newer.break_time;

      if(sweep_time == 0 || break_time == 0 || break_time <= sweep_time)
      {
          return;
      }

      // price window: cần sweep_price/break_price phải đã có
      if(sweep_price == 0.0 || break_price == 0.0) return;
      double pmin = MathMin(sweep_price, break_price);
      double pmax = MathMax(sweep_price, break_price);

      // Kiểm tra tồn tại FVG trên MTF (giữ logic cũ)
      bool ok = false;
      if(newer.direction == 1)
          ok = HasBullFVGBetween(sym, tf, sweep_time, break_time, fvgLookback);
      else
          ok = HasBearFVGBetween(sym, tf, sweep_time, break_time, fvgLookback);

      if(!ok)
      {
        // nếu requireFVG yêu cầu MTF FVG bắt buộc thì abort
        return;
      }

      // --- VẼ các internal FVG trên LTF nằm giữa sweep_time & break_time ---
      DrawInternalFVGMatches(sym, LowTF, sweep_time, break_time, pmin, pmax, FVGLookback);
    }

    // tiếp tục các kiểm tra MSS như trước
    double pip = GetPipSize(sym);
    double tol = pip * 0.1;
    double low_sweap_price = sweep_price;

    if(sweep_price == 0.0 || break_price == 0.0) return;

    if(newer.direction == 1)
    {
      if(!(sweep_price + tol < break_price)) return;
    }
    else
    {
      if(!(sweep_price - tol > break_price)) return;
    }

    MSSInfo mss;
    mss.found = true;
    mss.direction = newer.direction;
    mss.sweep_time = older.break_time;
    mss.sweep_price = sweep_price;
    mss.break_time = newer.break_time;
    mss.break_price = break_price;
    mss.swept_swing_time = older.broken_sw_time;
    mss.swept_swing_price = older.broken_sw_price;
    mss.broken_swing_time = newer.broken_sw_time;
    mss.low_sweap_price = low_sweap_price;
    mss.key_level = newer.broken_sw_price;

    // Nếu đang watch và MSS direction trùng với FVG direction -> xử lý pending
    if(watchingMSSMode && watchingFVGIndex >= 0)
    {
      if(mss.found && mss.direction == watchingFVGDir)
      {
        if(PrintEntryLog) PrintFormat("MSS matched watched FVG dir=%d -> creating pending", mss.direction);
        watchingMSSMode = false;
        watchingFVGIndex = -1;
        watchingFVGDir = 0;

        // SetUpPendingEntryForMSS(mss, slot);
      }
    }

    DrawMss(sym, tf, mss, slot);
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

// Draw pending entry visuals and save composite name inside struct
void DrawPendingEntryVisuals(string symbol)
{
  if(!pendingEntry.active) return;
  if(pendingEntry.price == 0.0) return;

  // xóa objects cũ nếu có
  if(StringLen(pendingEntry.compositeName) > 0)
  {
    string partsOld[];
    int no = StringSplit(pendingEntry.compositeName, '|', partsOld);
    for(int j=0;j<no;j++)
    {
      if(StringLen(partsOld[j])>0 && ObjectFind(0, partsOld[j])>=0)
        ObjectDelete(0, partsOld[j]);
    }
    pendingEntry.compositeName = "";
  }

  // use created_time as anchor (fallback to TimeCurrent if not set)
  datetime created = pendingEntry.created_time;
  if(created == 0) created = TimeCurrent();

  // chuẩn bị tên unique dựa trên created_time (ổn định khi redraw)
  int timeStamp = (int)created;
  string base = SwingObjPrefix + "PEND_";
  string lineEntry = base + "LINE_E_" + IntegerToString(timeStamp);
  string lblEntry  = base + "LBL_E_"  + IntegerToString(timeStamp);
  string lineSL    = base + "LINE_SL_" + IntegerToString(timeStamp);
  string lblSL     = base + "LBL_SL_"  + IntegerToString(timeStamp);
  string lineTP    = base + "LINE_TP_" + IntegerToString(timeStamp);
  string lblTP     = base + "LBL_TP_"  + IntegerToString(timeStamp);

  // time để vẽ tia ngang: bắt đầu tại created, tia hướng sang phải => sử dụng OBJPROP_RAY_RIGHT
  datetime barSecs = (datetime)PeriodSeconds(LowTF);
  datetime left_time = created;
  datetime right_time = (datetime)((long)created + (long)barSecs); // điểm phụ (không quan trọng vì ray_right=true)

  // ENTRY line (trend object as horizontal ray)
  if(ObjectCreate(0, lineEntry, OBJ_TREND, 0, left_time, pendingEntry.price, right_time, pendingEntry.price))
  {
    int col = (pendingEntry.direction == 1) ? clrLime : clrRed;
    ObjectSetInteger(0, lineEntry, OBJPROP_COLOR, col);
    ObjectSetInteger(0, lineEntry, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, lineEntry, OBJPROP_STYLE, STYLE_DASH);
    ObjectSetInteger(0, lineEntry, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, lineEntry, OBJPROP_BACK, true);
    ObjectSetInteger(0, lineEntry, OBJPROP_RAY_RIGHT, true);   // <-- make it a ray to the right
    ObjectSetInteger(0, lineEntry, OBJPROP_RAY_LEFT, false);
  }

  // ENTRY label (đặt tại created_time để hiện đúng khi pending tạo)
  double yoffset = SymbolInfoDouble(symbol, SYMBOL_POINT) * 6.0;
  int digs = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  double entryLabelPrice = (pendingEntry.direction == 1) ? (pendingEntry.price + yoffset) : (pendingEntry.price - yoffset);
  if(ObjectCreate(0, lblEntry, OBJ_TEXT, 0, left_time, entryLabelPrice))
  {
    string txtE = "PEND " + ((pendingEntry.direction==1) ? "BUY" : "SELL") + " " + DoubleToString(pendingEntry.price, digs);
    ObjectSetString(0, lblEntry, OBJPROP_TEXT, txtE);
    ObjectSetInteger(0, lblEntry, OBJPROP_FONTSIZE, SwingMarkerFontSize);
    ObjectSetInteger(0, lblEntry, OBJPROP_COLOR, (pendingEntry.direction==1)?clrLime:clrRed);
    ObjectSetInteger(0, lblEntry, OBJPROP_BACK, true);
    ObjectSetInteger(0, lblEntry, OBJPROP_SELECTABLE, false);
  }

  // SL line + label (nếu có)
  if(pendingEntry.sl_price != 0.0)
  {
    if(ObjectCreate(0, lineSL, OBJ_TREND, 0, left_time, pendingEntry.sl_price, right_time, pendingEntry.sl_price))
    {
      ObjectSetInteger(0, lineSL, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, lineSL, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, lineSL, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, lineSL, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lineSL, OBJPROP_BACK, true);
      ObjectSetInteger(0, lineSL, OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, lineSL, OBJPROP_RAY_LEFT, false);
    }

    double slLabelPrice = (pendingEntry.sl_price - yoffset);
    if(ObjectCreate(0, lblSL, OBJ_TEXT, 0, left_time, slLabelPrice))
    {
      string txtSL = "SL " + DoubleToString(pendingEntry.sl_price, digs);
      ObjectSetString(0, lblSL, OBJPROP_TEXT, txtSL);
      ObjectSetInteger(0, lblSL, OBJPROP_FONTSIZE, SwingMarkerFontSize - 1);
      ObjectSetInteger(0, lblSL, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, lblSL, OBJPROP_BACK, true);
      ObjectSetInteger(0, lblSL, OBJPROP_SELECTABLE, false);
    }
  }
  else
  {
    // clear names so composite keeps consistent ordering
    lineSL = ""; lblSL = "";
  }

  // TP line + label (nếu có)
  if(pendingEntry.tp_price != 0.0)
  {
    if(ObjectCreate(0, lineTP, OBJ_TREND, 0, left_time, pendingEntry.tp_price, right_time, pendingEntry.tp_price))
    {
      ObjectSetInteger(0, lineTP, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, lineTP, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, lineTP, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, lineTP, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lineTP, OBJPROP_BACK, true);
      ObjectSetInteger(0, lineTP, OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, lineTP, OBJPROP_RAY_LEFT, false);
    }

    double tpLabelPrice = (pendingEntry.tp_price + yoffset);
    if(ObjectCreate(0, lblTP, OBJ_TEXT, 0, left_time, tpLabelPrice))
    {
      string txtTP = "TP " + DoubleToString(pendingEntry.tp_price, digs);
      ObjectSetString(0, lblTP, OBJPROP_TEXT, txtTP);
      ObjectSetInteger(0, lblTP, OBJPROP_FONTSIZE, SwingMarkerFontSize - 1);
      ObjectSetInteger(0, lblTP, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, lblTP, OBJPROP_BACK, true);
      ObjectSetInteger(0, lblTP, OBJPROP_SELECTABLE, false);
    }
  }
  else
  {
    lineTP = ""; lblTP = "";
  }

  // Lưu compositeName theo thứ tự: entryLine|entryLbl|slLine|slLbl|tpLine|tpLbl
  string comp = lineEntry + "|" + lblEntry + "|" + lineSL + "|" + lblSL + "|" + lineTP + "|" + lblTP;
  pendingEntry.compositeName = comp;

  if(PrintEntryLog)
  {
    PrintFormat("PendingEntry VISUAL DRAWN: created=%s dir=%d entry=%.5f sl=%.5f tp=%.5f composite=(%s)",
                TimeToString(created, TIME_DATE|TIME_MINUTES),
                pendingEntry.direction, pendingEntry.price, pendingEntry.sl_price, pendingEntry.tp_price, pendingEntry.compositeName);
  }
}

// Set up pending entry when MSS confirmed and direction matches watched FVG
// - mss: MSSInfo found
// - slot: slot where MSS was detected
void SetUpPendingEntryForMSS(const MSSInfo &mss, int slot)
{
  string sym = Symbol();

  if(PrintEntryLog)
    PrintFormat("==> SetUpPendingEntryForMSS START: mss.found=%d dir=%d sweep_time=%d sweep_price=%.10f break_time=%d break_price=%.10f",
                mss.found ? 1 : 0, mss.direction, (int)mss.sweep_time, mss.sweep_price, (int)mss.break_time, mss.break_price);

  if(!mss.found)
  {
    if(PrintEntryLog) Print("-> abort: mss.found == false");
    return;
  }
  if(mss.sweep_time == 0 || mss.break_time == 0 || mss.sweep_time >= mss.break_time)
  {
    if(PrintEntryLog) PrintFormat("-> abort: invalid times (sweep_time=%d break_time=%d)", (int)mss.sweep_time, (int)mss.break_time);
    return;
  }

  double lfgtop[]; double lfgbottom[];
  datetime lfgA[]; datetime lfgC[];
  int lfgtype[];

  int cnt = FindInternalFVG(sym, LowTF, FVGLookback, lfgtop, lfgbottom, lfgA, lfgC, lfgtype);
  if(PrintEntryLog) PrintFormat("-> FindInternalFVG returned cnt=%d (FVGLookback=%d)", cnt, FVGLookback);

  if(cnt <= 0)
  {
    if(PrintEntryLog) Print("-> abort: no internal LTF FVG found");
    return;
  }

  // Log all FVGs found for debug
  double point = SymbolInfoDouble(sym, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;
  for(int i=0; i<cnt; i++)
  {
    string timestrA = TimeToString(lfgA[i], TIME_DATE|TIME_MINUTES);
    string timestrC = TimeToString(lfgC[i], TIME_DATE|TIME_MINUTES);
    if(PrintEntryLog)
      PrintFormat("   FVG[%d]: type=%d top=%.10f bottom=%.10f timeA=%s timeC=%s", i, lfgtype[i], lfgtop[i], lfgbottom[i], timestrA, timestrC);
  }

  double pmin = MathMin(mss.sweep_price, mss.break_price);
  double pmax = MathMax(mss.sweep_price, mss.break_price);
  if(PrintEntryLog) PrintFormat("-> Price window between sweep & break: pmin=%.10f pmax=%.10f tol=%.10g", pmin, pmax, tol);

  int chosenIdx = -1;
  for(int i=0; i<cnt; i++)
  {
    datetime tc = lfgC[i];
    // ensure candidate FVG C bar is strictly between sweep_time and break_time
    if(tc <= mss.sweep_time)
    {
      if(PrintEntryLog) PrintFormat("   skip FVG[%d] because timeC(%s) <= sweep_time(%s)", i, TimeToString(tc, TIME_DATE|TIME_MINUTES), TimeToString(mss.sweep_time, TIME_DATE|TIME_MINUTES));
      continue;
    }
    if(tc >= mss.break_time)
    {
      if(PrintEntryLog) PrintFormat("   skip FVG[%d] because timeC(%s) >= break_time(%s)", i, TimeToString(tc, TIME_DATE|TIME_MINUTES), TimeToString(mss.break_time, TIME_DATE|TIME_MINUTES));
      continue;
    }

    double top = lfgtop[i];
    double bottom = lfgbottom[i];

    // check overlap: bottom..top overlap with sweep..break price window
    if(bottom + tol >= pmin && top - tol <= pmax)
    {
      chosenIdx = i;
      if(PrintEntryLog) PrintFormat("-> chosen FVG index=%d (type=%d top=%.10f bottom=%.10f)", chosenIdx, lfgtype[i], top, bottom);
      break;
    }
    else
    {
      if(PrintEntryLog) PrintFormat("   FVG[%d] does not overlap window: bottom+tol=%.10f top-tol=%.10f (need bottom+tol >= pmin && top-tol <= pmax)", i, bottom+tol, top-tol);
    }
  }

  if(chosenIdx == -1)
  {
    if(PrintEntryLog) Print("-> abort: no matching LTF internal FVG found between sweep and break (chosenIdx == -1)");
    return;
  }

  // Determine entry price from chosen FVG
  double entPrice = 0.0;
  int fvgDir = lfgtype[chosenIdx];
  if(fvgDir == 1)
    entPrice = lfgbottom[chosenIdx];
  else
    entPrice = lfgtop[chosenIdx];

  // Normalize entry to symbol digits
  int digs = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
  double entPriceNorm = NormalizeDouble(entPrice, digs);

  if(PrintEntryLog)
  {
    PrintFormat("-> entry raw=%.10f normalized=%.10f digits=%d fvgDir=%d", entPrice, entPriceNorm, digs, fvgDir);
  }

  // Clear previous pending
  ClearPendingEntry();

  // Fill pendingEntry fields
  pendingEntry.active = true;
  pendingEntry.direction = (mss.direction == 1) ? 1 : -1;
  pendingEntry.price = entPriceNorm;
  pendingEntry.fvgIndex = chosenIdx;
  pendingEntry.created_time = TimeCurrent();
  pendingEntry.compositeName = "";
  pendingEntry.source_slot = slot;

  // Use MSS sweep price as SL (as before)
  pendingEntry.sl_price = mss.sweep_price;

  // compute TP using RiskRewardRatio
  double entry = pendingEntry.price;
  double sl = pendingEntry.sl_price;
  pendingEntry.tp_price = 0.0;

  if(sl == 0.0)
  {
    if(PrintEntryLog) PrintFormat("-> warning: SL==0. TP not set (entry=%.10f)", entry);
  }
  else
  {
    double diff = MathAbs(entry - sl);
    if(diff <= 0.0)
    {
      if(PrintEntryLog) PrintFormat("-> warning: diff==0 (entry=%.10f sl=%.10f) TP not set", entry, sl);
    }
    else
    {
      double tp = (pendingEntry.direction == 1) ? (entry + RiskRewardRatio * diff)
                                                : (entry - RiskRewardRatio * diff);
      pendingEntry.tp_price = NormalizeDouble(tp, digs);
      if(PrintEntryLog)
        PrintFormat("-> computed TP: entry=%.10f sl=%.10f diff=%.10f R:R=%.2f tp=%.10f", entry, sl, diff, RiskRewardRatio, pendingEntry.tp_price);
    }
  }

  if(PrintEntryLog) PrintFormat("-> PendingEntry populated: dir=%d entry=%.10f sl=%.10f tp=%.10f fvgIndex=%d created=%s",
                                pendingEntry.direction, pendingEntry.price, pendingEntry.sl_price, pendingEntry.tp_price, pendingEntry.fvgIndex, TimeToString(pendingEntry.created_time, TIME_DATE|TIME_SECONDS));

  // Draw visuals
  DrawPendingEntryVisuals(sym);

  // After drawing, log compositeName and check each object exists
  if(StringLen(pendingEntry.compositeName) > 0)
  {
    if(PrintEntryLog) PrintFormat("-> DrawPendingEntryVisuals set compositeName=(%s)", pendingEntry.compositeName);

    string parts[];
    int n = StringSplit(pendingEntry.compositeName, '|', parts);
    for(int i=0; i<n; i++)
    {
      string nm = parts[i];
      if(StringLen(nm) == 0)
      {
        if(PrintEntryLog) PrintFormat("   part[%d] is empty", i);
        continue;
      }
      int found = ObjectFind(0, nm);
      if(found >= 0)
        PrintFormat("   OBJECT FOUND: part[%d] name='%s' ObjectFind returned=%d", i, nm, found);
      else
        PrintFormat("   OBJECT MISSING: part[%d] name='%s' ObjectFind returned=%d", i, nm, found);
    }
  }
  else
  {
    if(PrintEntryLog) Print("-> WARNING: pendingEntry.compositeName is empty AFTER DrawPendingEntryVisuals()");
    // As extra debug, attempt to reconstruct expected entry object names using created_time
    int timeStamp = (int)pendingEntry.created_time;
    string base = SwingObjPrefix + "PEND_";
    string expect_line = base + "LINE_E_" + IntegerToString(timeStamp);
    string expect_lbl = base + "LBL_E_" + IntegerToString(timeStamp);
    int found_line = ObjectFind(0, expect_line);
    int found_lbl  = ObjectFind(0, expect_lbl);
    if(PrintEntryLog) PrintFormat("-> Reconstructed expected names: %s(found=%d), %s(found=%d)", expect_line, found_line, expect_lbl, found_lbl);
  }

  if(PrintEntryLog) Print("==> SetUpPendingEntryForMSS END");
}

void OnTick()
{
  string sym = Symbol();

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
