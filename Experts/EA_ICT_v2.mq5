//+------------------------------------------------------------------+
//| EA: ICT v2                                                       |
//| Mục đích: Setup ICT đồng thuận trend 3 timeframes                |
//| Người tạo: Bell CW                                     |
//+------------------------------------------------------------------+
#property copyright "Bell CW"
#property version   "2.00"
#property strict

// --- Watch MSS mode (user requested) ---
bool watchMSSMode = false;      // mặc định false
int  watchedFVGIndex = -1;      // index trong FVG_* arrays (khi watchMSSMode==true)
int  watchedFVGDir = 0;         // 1 = bullish FVG, -1 = bearish FVG

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
input int           ltfSwingRange = 2;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           MaxSwingKeep = 2;            // Số đỉnh/đáy gần nhất cần lưu (bạn yêu cầu 2)

// Cấu hình vẽ Swing trên chart
input bool   ShowSwingMarkers = true;      // Hiển thị các marker swing trên chart
input string SwingObjPrefix   = "Swing_"; // Tiền tố tên object (dễ xóa/điều chỉnh)
input int    SwingMarkerFontSize    = 10;        // Kích thước font cho label

input int FVGLookback = 200;   // Số nến lookback khi tính FVG (dùng ở EnsureFVGUpToDate)

input bool   PrintToExperts = true;    // In log ra Expert

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

// FVG results (global)
double FVG_top[];        // giá trên của zone (lớn hơn)
double FVG_bottom[];     // giá dưới của zone (nhỏ hơn)
datetime FVG_timeA[];    // time của bar A (older)
datetime FVG_timeC[];    // time của bar C (newer)
int    FVG_type[];       //  1 = bullish, -1 = bearish
int    FVG_count = 0;

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

// -----------------------------------------------------------------
// - Dùng mảng global FVG_top/FVG_bottom/FVG_timeC/FVG_type
// - Quét từng FVG và kiểm tra trên LowTF xem có bar nào *sau* FVG_timeC
//   chạm zone không. Nếu có -> đánh dấu touched + lưu thời gian/giá
// - Gọi hàm này sau khi EnsureFVGUpToDate() được gọi
// -----------------------------------------------------------------
void UpdateMTFFVGTouched(string symbol)
{
  // ensure global FVG arrays exist
  if(FVG_count <= 0) 
  {
    // ensure arrays are empty if none
    ArrayFree(MTF_FVG_Touched); ArrayFree(MTF_FVG_TouchTime); ArrayFree(MTF_FVG_TouchPrice);
    return;
  }

  // ensure arrays sized to FVG_count
  int oldSize = ArraySize(MTF_FVG_Touched);
  if(oldSize != FVG_count)
  {
    ArrayResize(MTF_FVG_Touched, FVG_count);
    ArrayResize(MTF_FVG_TouchTime, FVG_count);
    ArrayResize(MTF_FVG_TouchPrice, FVG_count);
    // init new slots false/0
    for(int i=0;i<FVG_count;i++)
    {
      if(oldSize <= 0 || i >= oldSize)
      {
        MTF_FVG_Touched[i] = false;
        MTF_FVG_TouchTime[i] = 0;
        MTF_FVG_TouchPrice[i] = 0.0;
      }
    }
  }

  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  // scan each MTF FVG
  for(int k = 0; k < FVG_count; k++)
  {
    // if already touched, skip (keeps first-touch)
    if(MTF_FVG_Touched[k]) continue;

    datetime mtfC = FVG_timeC[k];
    if(mtfC == 0) continue;

    double top = FVG_top[k];
    double bottom = FVG_bottom[k];
    int dir = FVG_type[k]; // 1=bull, -1=bear

    // find index of mtfC on LowTF
    int idxC_on_LTF = iBarShift(symbol, LowTF, mtfC, false);
    if(idxC_on_LTF == -1) idxC_on_LTF = 0;

    bool touched = false;
    datetime touch_time = 0;
    double touch_price = 0.0;

    // scan forward on LowTF (bars newer than mtfC): idx = idxC_on_LTF-1 ... 0
    int barsAvail = iBars(symbol, LowTF);
    for(int idx = idxC_on_LTF - 1; idx >= 0; idx--)
    {
      double hh = iHigh(symbol, LowTF, idx);
      double ll = iLow(symbol, LowTF, idx);
      if(hh == 0 || ll == 0) continue;

      // --- NEW: touch only on specific edge depending on FVG direction ---
      if(dir == 1) // bullish FVG -> touch only when price reaches the UPPER edge (top)
      {
        // if the bar's high reaches or exceeds the top (allow small tol)
        if(hh >= top - tol)
        {
          touched = true;
          touch_time = iTime(symbol, LowTF, idx);
          // representative price: use the exact edge price (top)
          touch_price = top;
          break;
        }
      }
      else // dir == -1 -> bearish FVG -> touch only when price reaches the LOWER edge (bottom)
      {
        // if the bar's low reaches or goes below the bottom (allow small tol)
        if(ll <= bottom + tol)
        {
          touched = true;
          touch_time = iTime(symbol, LowTF, idx);
          // representative price: use the exact edge price (bottom)
          touch_price = bottom;
          break;
        }
      }
    }

    if(touched)
    {
      MTF_FVG_Touched[k] = true;
      MTF_FVG_TouchTime[k] = touch_time;
      MTF_FVG_TouchPrice[k] = touch_price;
      if(PrintToExperts)
        PrintFormat("UpdateMTFFVGTouched: MTF FVG idx=%d dir=%d touched at %s price=%.5f", k, dir, TimeToString(touch_time, TIME_DATE|TIME_MINUTES), touch_price);

      // --- NEW: enable watchMSSMode when any MTF FVG is first touched ---
      if(!watchMSSMode)
      {
        watchMSSMode = true;
        watchedFVGIndex = k;
        watchedFVGDir   = dir;
        if(PrintToExperts)
          PrintFormat("watchMSSMode ENABLED for FVG idx=%d dir=%d", watchedFVGIndex, watchedFVGDir);
      }
    }
  } // end for each FVG
}

// Kiểm tra điều kiện vô hiệu hoá watchMSSMode:
// 1) last closed candle trên LowTF đóng dưới cạnh dưới của bullish FVG
// 2) last closed candle trên LowTF đóng trên cạnh trên của bearish FVG
void CheckWatchMSSInvalidation(string symbol)
{
  if(!watchMSSMode || watchedFVGIndex < 0 || watchedFVGIndex >= FVG_count) return;

  // Lấy last closed close trên LowTF (index 1)
  double lastClose = iClose(symbol, LowTF, 1);
  if(lastClose == 0.0) return;

  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  int idx = watchedFVGIndex;
  int dir = watchedFVGDir;

  // bảo đảm FVG arrays còn hợp lệ
  if(idx < 0 || idx >= FVG_count) return;

  double top = FVG_top[idx];
  double bottom = FVG_bottom[idx];

  // Nếu bullish FVG (dir == 1): invalid khi đóng dưới bottom
  if(dir == 1)
  {
    if(lastClose < bottom - tol)
    {
      if(PrintToExperts) PrintFormat("CheckWatchMSSInvalidation: bullish FVG idx=%d invalidated by close=%.5f < bottom=%.5f", idx, lastClose, bottom);
      // clear
      watchMSSMode = false;
      watchedFVGIndex = -1;
      watchedFVGDir = 0;
    }
  }
  else if(dir == -1) // bearish: invalid khi đóng trên top
  {
    if(lastClose > top + tol)
    {
      if(PrintToExperts) PrintFormat("CheckWatchMSSInvalidation: bearish FVG idx=%d invalidated by close=%.5f > top=%.5f", idx, lastClose, top);
      // clear
      watchMSSMode = false;
      watchedFVGIndex = -1;
      watchedFVGDir = 0;
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
      if(PrintToExperts) PrintFormat("DrawAllBOSForSlot: slot=%d cleared old composite index=%d", slot, j);
    }
  }

  // draw older first (index1) then newer (index0)
  // Note: DrawBOS sẽ set BOS_Names[slot][storeIndex] after drawing, so we pass storeIndex to persist names
  if(cnt == 2)
  {
    if(BOSStore[slot][1].found)
    {
      DrawBOS(sym, slot, BOSStore[slot][1], 1);
      // If DrawBOS for some reason didn't set BOS_Names (e.g. missing data), ensure we don't leave inconsistent state
      if(StringLen(BOS_Names[slot][1]) == 0)
      {
        // attempt fallback: create minimal line to mark BOS to avoid total disappearance
        BOS_Names[slot][1] = ""; // keep empty; optional: log
        if(PrintToExperts) PrintFormat("DrawAllBOSForSlot: slot=%d index1 drawn but composite name empty", slot);
      }
    }

    if(BOSStore[slot][0].found)
    {
      DrawBOS(sym, slot, BOSStore[slot][0], 0);
      if(StringLen(BOS_Names[slot][0]) == 0)
      {
        if(PrintToExperts) PrintFormat("DrawAllBOSForSlot: slot=%d index0 drawn but composite name empty", slot);
      }
    }
  }
  else // cnt == 1
  {
    if(BOSStore[slot][0].found)
    {
      DrawBOS(sym, slot, BOSStore[slot][0], 0);
      if(StringLen(BOS_Names[slot][0]) == 0)
      {
        if(PrintToExperts) PrintFormat("DrawAllBOSForSlot: slot=%d single drawn but composite name empty", slot);
      }
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
    // condition: high > sh0 + threshold (wick exceeded), but close <= sh0 + threshold
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
        if(PrintToExperts)
          PrintFormat("DetectBOSOnSlot: slot=%d FAKE BULL detected idx=%d time=%s high=%.5f close=%.5f sh0=%.5f",
                      slot, idx, TimeToString(t, TIME_DATE|TIME_MINUTES), h, c, sh0);
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
    // condition: low < sl0 - threshold (wick exceeded downward), but close >= sl0 - threshold
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
        if(PrintToExperts)
          PrintFormat("DetectBOSOnSlot: slot=%d FAKE BEAR detected idx=%d time=%s low=%.5f close=%.5f sl0=%.5f",
                      slot, idx, TimeToString(t, TIME_DATE|TIME_MINUTES), l, c, sl0);
        return out;
      }
    }
  }

  return out;
}

// DrawBOS: vẽ 1 BOS (không shift/xóa store) — parameters: symbol, slot, bos info, storeIndex (0/1)
// Nếu bạn gọi DrawBOS với storeIndex = -1 thì hàm sẽ chỉ tạo objects tạm (không lưu tên).
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
    if(PrintToExperts) PrintFormat("DrawBOS: missing start info for slot=%d -> skip", slot);
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
  // - nếu tất cả object con còn trên chart -> skip redraw (giữ như swing)
  // - nếu composite name tồn tại nhưng 1 trong các object đã bị xóa -> xóa entry cũ rồi vẽ lại
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
        if(PrintToExperts) PrintFormat("DrawBOS: slot=%d storeIndex=%d -> already drawn, skip redraw", slot, storeIndex);
        return;
      }
      else
      {
        // object cũ bị xóa một phần nào đó -> xóa compositeName cũ khỏi bộ nhớ trước khi vẽ mới
        DeleteCompositeBOS(BOS_Names[slot][storeIndex]);
        BOS_Names[slot][storeIndex] = "";
        BOS_HaveZone[slot][storeIndex] = false;
        if(PrintToExperts) PrintFormat("DrawBOS: slot=%d storeIndex=%d -> old composite missing parts, recreating", slot, storeIndex);
      }
    }
  }

  // Create horizontal line (trend object used as line)
  if(!ObjectCreate(0, nm_line, OBJ_TREND, 0, t_start, p_h, t_h_end, p_h))
    PrintFormat("DrawBOS: Cannot create %s", nm_line);
  else
  {
    // line color: real use green/red, fake use yellow
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
    // fallback to text arrow if arrow object cannot be created
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
    PrintFormat("DrawBOS: Cannot create %s", nm_txt);
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

  if(PrintToExperts)
    PrintFormat("DrawBOS: slot=%d drew BOS at storeIndex=%d kind=%s names=(%s)", slot, storeIndex, (info.isReal ? "REAL":"FAKE"), compositeName);
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
// Lý do: nhiều broker dùng 5 chữ số (0.00001) => pip = point*10; 4 chữ số => pip = point.
double GetPipSize(string symbol)
{
  // Lấy số chữ số (digits) và point của symbol
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

  // Quy ước phổ biến:
  // - digits 5 hoặc 3 => broker dùng extra digit -> 1 pip = point * 10
  // - digits 4 hoặc 2 => 1 pip = point
  // Việc dùng pip (không phải point) thuận tiện để người dùng nhập ngưỡng theo pips (ví dụ 30 pips).
  if(digits==5 || digits==3) return point * 10.0;
  return point;
}

// ---------- FindInternalFVG ----------
// Tìm FVG (local scan) mà KHÔNG dùng/viết vào các mảng global.
// symbol, timeframe: như mọi khi
// lookback: số nến tối đa quét (số triple = lookback)
// OUT arrays (dynamic) sẽ được ArrayResize tới số phần tử tìm được:
//   out_top[], out_bottom[] : giá top/bottom của zone
//   out_timeA[], out_timeC[] : thời điểm bar A (older) và C (newer)
//   out_type[] :  1 = bullish, -1 = bearish
// Return: số FVG tìm được (>=0)
int FindInternalFVG(string symbol, ENUM_TIMEFRAMES timeframe, int lookback,
                    double &out_top[], double &out_bottom[],
                    datetime &out_timeA[], datetime &out_timeC[], int &out_type[])
{
   // reset out
   ArrayFree(out_top); ArrayFree(out_bottom); ArrayFree(out_timeA); ArrayFree(out_timeC); ArrayFree(out_type);
   int found = 0;

   int total = iBars(symbol, timeframe);
   if(total < 5) return 0;

   int maxScan = MathMin(lookback, total - 3); // need at least 3 bars per triple
   if(maxScan <= 0) return 0;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tol = (point > 0.0) ? point * 0.5 : 0.0;

   // scan triples: A = i+2 (older), B = i+1, C = i (newer) for i = 1..maxScan
   for(int i = 1; i <= maxScan; i++)
   {
      int idxA = i + 2;
      int idxB = i + 1;
      int idxC = i;

      if(idxA > total - 1) break;

      double highA = iHigh(symbol, timeframe, idxA);
      double lowA  = iLow(symbol, timeframe, idxA);
      double highC = iHigh(symbol, timeframe, idxC);
      double lowC  = iLow(symbol, timeframe, idxC);

      if(highA == 0 || lowA == 0 || highC == 0 || lowC == 0) continue;

      // Bullish FVG: low(C) > high(A)
      if(lowC > highA + tol)
      {
         // avoid duplicates: if a similar top/bottom already recorded -> skip
         bool dup = false;
         for(int k = 0; k < found; k++)
         {
            if(MathAbs(out_top[k] - lowC) <= tol && MathAbs(out_bottom[k] - highA) <= tol) { dup = true; break; }
         }
         if(!dup)
         {
            ArrayResize(out_top, found+1);
            ArrayResize(out_bottom, found+1);
            ArrayResize(out_timeA, found+1);
            ArrayResize(out_timeC, found+1);
            ArrayResize(out_type, found+1);

            out_top[found]    = lowC;
            out_bottom[found] = highA;
            out_timeA[found]  = iTime(symbol, timeframe, idxA);
            out_timeC[found]  = iTime(symbol, timeframe, idxC);
            out_type[found]   = 1;
            found++;
         }
         continue; // next triple
      }

      // Bearish FVG: high(C) < low(A)
      if(highC < lowA - tol)
      {
         bool dup = false;
         for(int k = 0; k < found; k++)
         {
            if(MathAbs(out_top[k] - lowA) <= tol && MathAbs(out_bottom[k] - highC) <= tol) { dup = true; break; }
         }
         if(!dup)
         {
            ArrayResize(out_top, found+1);
            ArrayResize(out_bottom, found+1);
            ArrayResize(out_timeA, found+1);
            ArrayResize(out_timeC, found+1);
            ArrayResize(out_type, found+1);

            out_top[found]    = lowA;
            out_bottom[found] = highC;
            out_timeA[found]  = iTime(symbol, timeframe, idxA);
            out_timeC[found]  = iTime(symbol, timeframe, idxC);
            out_type[found]   = -1;
            found++;
         }
      }
   } // end scan

   return found;
}

// ---------- HasBullFVGBetween & HasBearFVGBetween (gọi FindInternalFVG) ----------
// Kiểm tra Bullish FVG có FVG_timeC thuộc (t_start, t_end) không
bool HasBullFVGBetween(string symbol, ENUM_TIMEFRAMES timeframe, datetime t_start, datetime t_end, int fvgLookback)
{
   if(t_start == 0 || t_end == 0 || t_end <= t_start) return false;

   // local arrays to receive FVGs
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
         if(tc > t_start && tc < t_end) return true; // strictly between
      }
   }
   return false;
}

// Kiểm tra Bearish FVG có FVG_timeC thuộc (t_start, t_end) không
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
         if(tc > t_start && tc < t_end) return true; // strictly between
      }
   }
   return false;
}

// Kiểm tra 1 bar tại index i có phải SwingHigh không (xét râu - High)
bool IsSwingHigh(string symbol, ENUM_TIMEFRAMES timeframe, int candleIndex, int swingRange)
{
  double hi = iHigh(symbol, timeframe, candleIndex);
  if(hi == 0.0) return false;

  // So sánh với X nến trước (index giảm)
  for(int i = 1; i <= swingRange; i++)
  {
    int idxPrev = candleIndex - i;
    if(idxPrev < 0) return false; // không đủ dữ liệu
    double hprev = iHigh(symbol, timeframe, idxPrev);
    if(hprev == 0.0) return false; // dữ liệu thiếu
    if(hprev >= hi) // nếu có râu high trước >= hi -> không phải swing high
      return false;
  }

  // So sánh với X nến sau (index tăng)
  for(int k = 1; k <= swingRange; k++)
  {
    int idxNext = candleIndex + k;
    // nếu idxNext vượt quá bars available -> không có dữ liệu đủ -> return false
    double hnext = iHigh(symbol, timeframe, idxNext);
    if(hnext == 0.0) return false;
    if(hnext >= hi) // nếu có râu high sau >= hi -> không phải swing high
      return false;
  }

  return true;
}

// Kiểm tra 1 bar tại index i có phải SwingLow không (xét râu - Low)
bool IsSwingLow(string symbol, ENUM_TIMEFRAMES timeframe, int i, int X)
{
  double lo = iLow(symbol, timeframe, i);
  if(lo == 0.0) return false;

  // So sánh với X nến trước (index giảm)
  for(int j = 1; j <= X; j++)
  {
    int idxPrev = i - j;
    if(idxPrev < 0) return false; // không đủ dữ liệu
    double lprev = iLow(symbol, timeframe, idxPrev);
    if(lprev == 0.0) return false; // dữ liệu thiếu
    if(lprev <= lo) // nếu râu low trước <= lo -> không phải swing low
      return false;
  }

  // So sánh với X nến sau (index tăng)
  for(int k = 1; k <= X; k++)
  {
    int idxNext = i + k;
    double lnext = iLow(symbol, timeframe, idxNext);
    if(lnext == 0.0) return false;
    if(lnext <= lo) // nếu râu low sau <= lo -> không phải swing low
      return false;
  }

  return true;
}

// Cập nhật mảng SwingHighPrice/Time và SwingLowPrice/Time (giữ MaxSwingKeep phần tử gần nhất)
// UpdateSwings vào slot (0 = HighTF, 1 = MiddleTF)
void UpdateSwings(string symbol, ENUM_TIMEFRAMES timeframe, int slot, int SwingRange)
{
  // Reset slot
  SwingHighCountTF[slot] = 0;
  SwingLowCountTF[slot]  = 0;

  int total = iBars(symbol, timeframe);
  if(total <= SwingRange + 2) return; // dữ liệu không đủ

  int iStart = SwingRange + 1;
  int iEnd   = total - SwingRange - 1;

  // Duyệt từ index nhỏ (gần nhất) tới xa để tìm Swing gần nhất trước
  for(int i = iStart; i <= iEnd; i++)
  {
    // nếu đã đủ cả 2 loại thì dừng
    if(SwingHighCountTF[slot] >= MaxSwingKeep && SwingLowCountTF[slot] >= MaxSwingKeep) break;

    // Kiểm tra SwingHigh bằng hàm tiện ích
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

    // Kiểm tra SwingLow bằng hàm tiện ích
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
// Draw swings for the given timeframe (uses stored slot arrays)
// Draw swings for the given timeframe (uses stored slot arrays)
// Updated: use explicit prefixes "htf_" and "MTF_" and delete only matching objects
void DrawSwingsOnChart(ENUM_TIMEFRAMES timeframe)
{
  if(!ShowSwingMarkers) return;

  // mapping chung: 0=HTF, 1=MTF, 2=LTF
  int slot = 0; // default 0=HTF
  string inChartSwingPrefix = "h";

  if(timeframe == MiddleTF) {
    slot = 1;
    inChartSwingPrefix = "m";
  } else if (timeframe == LowTF) {
    slot = 2;
    inChartSwingPrefix = "l";
  }

  string prefix = SwingObjPrefix + inChartSwingPrefix;

  // Xóa các marker cũ chỉ theo prefix này (không xóa chung tất cả SwingObjPrefix)
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

   // Thời lượng bar (giây)
   datetime bar_secs = (datetime)PeriodSeconds(timeframe);

   // Vẽ Swing High
   int maxH = (SwingHighCountTF[slot] < MaxSwingKeep) ? SwingHighCountTF[slot] : MaxSwingKeep;
   for(int h = 0; h < maxH; h++)
   {
      string obj = prefix + "H_" + IntegerToString(h); // e.g. "HTF_SW_mid_H_0"
      datetime t = SwingHighTimeTF[slot][h];
      double price = SwingHighPriceTF[slot][h];
      datetime display_time_h = (datetime)(t + (bar_secs/2));

      if(t == 0 || price == 0.0) continue; 
      if(!ObjectCreate(0, obj, OBJ_TEXT, 0, display_time_h, price))
      {
         Print("Cannot create object: ", obj);
         continue;
      }

      ObjectSetString(0, obj, OBJPROP_TEXT,  "▲ " + inChartSwingPrefix + "H" + IntegerToString(h));
      ObjectSetInteger(0, obj, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, SwingMarkerFontSize);
      ObjectSetInteger(0, obj, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
      ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, obj, OBJPROP_HIDDEN, false);
   }

   // Vẽ Swing Low
   int maxL = (SwingLowCountTF[slot] < MaxSwingKeep) ? SwingLowCountTF[slot] : MaxSwingKeep;
   for(int l = 0; l < maxL; l++)
   {
      string obj = prefix + "L_" + IntegerToString(l);
      datetime t = SwingLowTimeTF[slot][l];
      double price = SwingLowPriceTF[slot][l];
      datetime display_time_l = (datetime)(t + (bar_secs/2));
      if(!ObjectCreate(0, obj, OBJ_TEXT, 0, display_time_l, price))
      {
         Print("Cannot create object: ", obj);
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
   // Lấy index bar tại thời điểm start_time
   int idxStart = iBarShift(symbol, timeframe, start_time, false);
   if(idxStart == -1) idxStart = 0;

   // Quét các bar mới hơn (index nhỏ hơn)
   for(int idx = idxStart - 1; idx >= 0; idx--)
   {
      double highM = iHigh(symbol, timeframe, idx);
      double lowM  = iLow(symbol, timeframe, idx);
      if(highM == 0 || lowM == 0) continue;

      // Nếu bar chạm price
      if(lowM <= price + tol && highM >= price - tol)
         return iTime(symbol, timeframe, idx);
   }

   // Không tìm thấy → kéo đến bar hiện tại + 1 bar
   datetime t0 = iTime(symbol, timeframe, 0);
   if(t0 != 0) return (datetime)((long)t0 + (long)bar_secs);

   return TimeCurrent();
}

void DrawMss(string symbol, ENUM_TIMEFRAMES tf, const MSSInfo &mss, int slot)
{
    if(!ShowSwingMarkers || !mss.found) 
        return;

    string basePrefix = SwingObjPrefix + "MSS_" + IntegerToString(slot) + "_";

    // XÓA TẤT CẢ MSS CŨ CỦA SLOT NÀY
    int total = ObjectsTotal(0);
    for(int i = total - 1; i >= 0; i--)
    {
        string nm = ObjectName(0, i);
        if(StringFind(nm, basePrefix, 0) == 0)
            ObjectDelete(0, nm);
    }

    // Thời lượng bar (giây) để dùng khi cần
    datetime bar_secs = (datetime)PeriodSeconds(tf);

    // VẼ LABEL SWEEP tại chính xác sweep_time và sweep_price (không offset)
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
        else
        {
            PrintFormat("DrawMss: Cannot create %s", lblSweep);
        }
    }

    // VẼ LABEL MSS tại chính xác break_time và break_price (không offset)
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
        else
        {
            PrintFormat("DrawMss: Cannot create %s", lblMss);
        }
    }

    // --------- NEW: draw horizontal guide line from swept swing to sweep candle ----------
    // Use swept_swing_time & swept_swing_price (from MSSInfo). If missing, try fallback to broken_swing_time/price or sweep_time.
    datetime t_swing = mss.swept_swing_time;
    double   p_swing = mss.swept_swing_price;

    // fallback if missing
    if(t_swing == 0 || p_swing == 0.0)
    {
        // try broken swing
        if(mss.broken_swing_time != 0 && mss.low_sweap_price != 0.0)
        {
            t_swing = mss.broken_swing_time;
            p_swing = mss.low_sweap_price;
        }
        else if(mss.sweep_time != 0 && mss.sweep_price != 0.0)
        {
            // last resort: draw small mark at sweep time & price
            t_swing = mss.sweep_time - bar_secs; // place a little earlier
            p_swing = mss.sweep_price;
        }
    }

    // Only draw if we've got valid time & price
    if(t_swing != 0 && p_swing != 0.0 && mss.sweep_time != 0)
    {
        // name with slot stamp to ensure uniqueness
        string lineName = basePrefix + "GUIDE_" + IntegerToString((int)mss.sweep_time);

        // We want a horizontal visual guide at the swing price from swing time -> sweep time.
        // Use OBJ_TREND with two points: (t_swing, p_swing) -> (mss.sweep_time, p_swing)
        if(!ObjectCreate(0, lineName, OBJ_TREND, 0, t_swing, p_swing, mss.sweep_time, p_swing))
        {
            PrintFormat("DrawMss: Cannot create guide line %s", lineName);
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

        // Optional: small label at the sweep_time to show swing price value
        string valLabel = basePrefix + "GUIDE_VAL_" + IntegerToString((int)mss.sweep_time);
        if(!ObjectCreate(0, valLabel, OBJ_TEXT, 0, mss.sweep_time, p_swing))
        {
            // ignore if cannot create
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

    if(PrintToExperts)
      PrintFormat("DrawMss: slot=%d drew MSS visuals (sweep_time=%s sweep_price=%.5f swept_swing_time=%s swept_swing_price=%.5f)",
                  slot, TimeToString(mss.sweep_time, TIME_DATE|TIME_MINUTES), mss.sweep_price,
                  TimeToString(mss.swept_swing_time, TIME_DATE|TIME_MINUTES), mss.swept_swing_price);
}

// Hàm tiện ích chuyển giá trị xu hướng thành chuỗi
string TrendToString(int trend)
{
  if(trend==1) return "UPTREND";
  if(trend==-1) return "DOWNTREND";
  return "SIDEWAY";
}

// Cập nhật TrendTF[slot] dựa trên 2 swing gần nhất (không gọi UpdateSwings bên trong)
// Bổ sung: phát hiện sớm (provisional) dựa trên các nến đóng gần nhất nếu swing chưa hoàn chỉnh
void UpdateTrendForSlot(int slot, ENUM_TIMEFRAMES timeframe, string symbol)
{
  // mặc định giữ trend hiện tại (không reset về 0 ngay lập tức để tránh flicker)
  int oldTrend = TrendTF[slot];

  // Tolerances / thresholds
  double pip = GetPipSize(symbol);
  double provisionalThresh = (double)ProvisionalBreakPips * pip;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  // Nếu không có đủ dữ liệu swing, ta vẫn sẽ thử provisional detection
  bool haveTwoSwings = (SwingHighCountTF[slot] >= 2 && SwingLowCountTF[slot] >= 2);

  // Lấy giá swing (index 0 = nearest, 1 = older). Có thể = 0 nếu chưa có.
  double sh0 = (SwingHighCountTF[slot] >= 1) ? SwingHighPriceTF[slot][0] : 0.0;
  double sh1 = (SwingHighCountTF[slot] >= 2) ? SwingHighPriceTF[slot][1] : 0.0;
  double sl0 = (SwingLowCountTF[slot] >= 1) ? SwingLowPriceTF[slot][0] : 0.0;
  double sl1 = (SwingLowCountTF[slot] >= 2) ? SwingLowPriceTF[slot][1] : 0.0;

  int newTrend = oldTrend; // default giữ trend cũ nếu không xác định được

  // 1) Rule "cứng" nếu có đủ 2 swings (như trước)
  if(haveTwoSwings)
  {
    if(sh0 > sh1 && sl0 > sl1) newTrend = 1;      // uptrend
    else if(sh0 < sh1 && sl0 < sl1) newTrend = -1; // downtrend
    else newTrend = 0; // không rõ
  }
  else
  {
    // nếu chưa có đủ swings, tạm giữ oldTrend (sẽ có chance bị override bởi provisional)
    newTrend = oldTrend;
  }

  // 2) Provisional / early detection:
  // Nếu swing "cứng" không xác định được (newTrend == 0) hoặc chúng ta thiếu swings,
  // thử kiểm tra xem last closed candle(s) đã đóng vượt sh0/sl0 chưa => áp provisional.
  // Lấy last closed candle close (index 1)
  double lastClosedClose = iClose(symbol, timeframe, 1);
  if(lastClosedClose == 0.0) lastClosedClose = iClose(symbol, timeframe, 0); // fallback

  int provisionalTrend = 0;
  if(sh0 != 0.0 && lastClosedClose > sh0 + provisionalThresh)
    provisionalTrend = 1;
  else if(sl0 != 0.0 && lastClosedClose < sl0 - provisionalThresh)
    provisionalTrend = -1;

  if(provisionalTrend != 0)
  {
    // Nếu chúng ta có provisionalTrend, xác nhận bằng số nến đóng liên tiếp (ProvisionalConsecCloses)
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
      else // provisionalTrend == -1
      {
        if(c < sl0 - provisionalThresh) countClosers++;
        else break;
      }
    }

    if(countClosers >= ProvisionalConsecCloses)
    {
      // Áp provisional nếu: (a) không có trend cứng (newTrend==0) hoặc (b) thiếu swings (haveTwoSwings==false)
      // hoặc bạn muốn provisional override cả khi newTrend khác (cẩn trọng) - ở đây ta chỉ override khi newTrend == 0 hoặc không đủ swings
      if(!haveTwoSwings || newTrend == 0)
      {
        newTrend = provisionalTrend;
        if(PrintToExperts)
          PrintFormat("UpdateTrendForSlot slot=%d tf=%s: provisionalTrend applied=%d (sh0=%.5f sl0=%.5f lastClose=%.5f thresh=%.5f count=%d)",
                      slot, EnumToString(timeframe), newTrend, sh0, sl0, lastClosedClose, provisionalThresh, countClosers);
      }
      else
      {
        // Nếu bạn muốn provisional override ngay cả khi haveTwoSwings==true && newTrend != 0,
        // uncomment dòng dưới đây (cẩn thận: có thể gây false positives)
        // newTrend = provisionalTrend;
        if(PrintToExperts)
          PrintFormat("UpdateTrendForSlot slot=%d tf=%s: provisional candidate=%d but two-swing trend exists=%d -> not applied",
                      slot, EnumToString(timeframe), provisionalTrend, newTrend);
      }
    }
    else
    {
      if(PrintToExperts)
        PrintFormat("UpdateTrendForSlot slot=%d tf=%s: provisional candidate=%d NOT confirmed, consecutive closes=%d (required %d)",
                    slot, EnumToString(timeframe), provisionalTrend, countClosers, ProvisionalConsecCloses);
    }
  }

  // Ghi kết quả vào biến global TrendTF
  TrendTF[slot] = newTrend;

  if(PrintToExperts)
    PrintFormat("UpdateTrendForSlot slot=%d tf=%s -> TrendTF=%d (haveTwoSwings=%s sh0=%.5f sh1=%.5f sl0=%.5f sl1=%.5f lastClose=%.5f)",
                slot, EnumToString(timeframe), TrendTF[slot], (haveTwoSwings ? "true":"false"),
                sh0, sh1, sl0, sl1, lastClosedClose);
}

//+------------------------------------------------------------------+
//| FindFVG - tìm Fair Value Gaps trên timeframe cho symbol         |
//| symbol: chuỗi symbol (Symbol())                                  |
//| timeframe: ENUM_TIMEFRAMES (ví dụ PERIOD_H1)                     |
//| lookback: số nến đóng (ví dụ 200)                                |
//| returns: số FVG tìm được (và ghi vào mảng global FVG_*)           |
//+------------------------------------------------------------------+
int FindFVG(string symbol, ENUM_TIMEFRAMES timeframe, int lookback)
{
  // reset kết quả cũ
  ArrayFree(FVG_top); ArrayFree(FVG_bottom); ArrayFree(FVG_timeA); ArrayFree(FVG_timeC); ArrayFree(FVG_type);
  FVG_count = 0;

  // total closed bars available
  int total = iBars(symbol, timeframe);
  if(total < 5) return 0;

  // lấy số nến tối đa quét (chỉ nến đóng: index >=1)
  int maxScan = MathMin(lookback, total - 3); // cần ít nhất 3 bar cho một triple
  if(maxScan <= 0) return 0;

  // tolerance nhỏ theo pip để tránh noise
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  // quét: i = index của bar C (mới nhất trong triple), i từ 1..maxScan
  // triple: A = i+2 (older), B = i+1 (middle), C = i (newer) --- tất cả là nến đã đóng
  for(int i = 1; i <= maxScan; i++)
  {
    int idxA = i + 2;
    int idxB = i + 1;
    int idxC = i;

    if(idxA > total - 1) break; // không đủ bars

    // lấy giá High/Low (dùng râu để FVG)
    double highA = iHigh(symbol, timeframe, idxA);
    double lowA  = iLow(symbol, timeframe, idxA);
    double highC = iHigh(symbol, timeframe, idxC);
    double lowC  = iLow(symbol, timeframe, idxC);

    if(highA == 0 || lowA == 0 || highC == 0 || lowC == 0) continue; // skip nếu dữ liệu thiếu

    // --- Bullish FVG: low(C) > high(A) ---
    if(lowC > highA + tol)
    {
      double top = lowC;
      double bottom = highA;
      // tránh trùng lặp: nếu đã có zone với top/bottom tương tự -> skip
      bool dup = false;
      for(int k = 0; k < FVG_count; k++)
      {
        if(MathAbs(FVG_top[k] - top) <= tol && MathAbs(FVG_bottom[k] - bottom) <= tol) { dup = true; break; }
      }
      if(!dup)
      {
        // append
        ArrayResize(FVG_top, FVG_count+1);
        ArrayResize(FVG_bottom, FVG_count+1);
        ArrayResize(FVG_timeA, FVG_count+1);
        ArrayResize(FVG_timeC, FVG_count+1);
        ArrayResize(FVG_type, FVG_count+1);

        FVG_top[FVG_count] = top;
        FVG_bottom[FVG_count] = bottom;
        FVG_timeA[FVG_count] = iTime(symbol, timeframe, idxA);
        FVG_timeC[FVG_count] = iTime(symbol, timeframe, idxC);
        FVG_type[FVG_count] = 1;
        FVG_count++;
      }
      continue; // không cần kiểm tra bearish nếu đã bullish cho triple này
    }

    // --- Bearish FVG: high(C) < low(A) ---
    if(highC < lowA - tol)
    {
      double top = lowA;    // top > bottom
      double bottom = highC;
      bool dup = false;
      for(int k = 0; k < FVG_count; k++)
      {
        if(MathAbs(FVG_top[k] - top) <= tol && MathAbs(FVG_bottom[k] - bottom) <= tol) { dup = true; break; }
      }
      if(!dup)
      {
        ArrayResize(FVG_top, FVG_count+1);
        ArrayResize(FVG_bottom, FVG_count+1);
        ArrayResize(FVG_timeA, FVG_count+1);
        ArrayResize(FVG_timeC, FVG_count+1);
        ArrayResize(FVG_type, FVG_count+1);

        FVG_top[FVG_count] = top;
        FVG_bottom[FVG_count] = bottom;
        FVG_timeA[FVG_count] = iTime(symbol, timeframe, idxA);
        FVG_timeC[FVG_count] = iTime(symbol, timeframe, idxC);
        FVG_type[FVG_count] = -1;
        FVG_count++;
      }
    }
  }

  return FVG_count;
}

//+------------------------------------------------------------------+
//| Make ARGB color with alpha (0..255)                              |
//+------------------------------------------------------------------+
uint MakeARGB(int a, uint clr)
{
  if(a < 0) a = 0; if(a > 255) a = 255;
  return ((uint)a << 24) | (clr & 0x00FFFFFF);
}

//+------------------------------------------------------------------+
//| DrawFVG: vẽ tất cả FVG đã tìm được cho symbol & timeframe        |
//| symbol: chuỗi symbol (ví dụ Symbol())                            |
//| timeframe: ENUM_TIMEFRAMES (ví dụ MiddleTF)                      |
//| startFromCBar: nếu true thì vẽ start time = FVG_timeC (mặc định) |
//+------------------------------------------------------------------+
void DrawFVG(string symbol, ENUM_TIMEFRAMES timeframe, bool startFromCBar = true)
{
  if(!ShowSwingMarkers) return;
  // prefix object để dễ xóa
  string prefix = SwingObjPrefix + "FVG_";

  // Xóa các FVG cũ (theo prefix)
  int tot = ObjectsTotal(0);
  for(int i = tot - 1; i >= 0; i--)
  {
    string nm = ObjectName(0, i);
    if(StringFind(nm, prefix, 0) == 0)
      ObjectDelete(0, nm);
  }

  // Nếu không có FVG nào thì return
  if(FVG_count <= 0) return;

  // Thời gian bar (giây) — dùng kiểu datetime để không gây cảnh báo cast
  datetime bar_secs = (datetime)PeriodSeconds(timeframe);

  // Tolerance cho việc detect touch
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  // Mỗi FVG: xác định thời điểm kết thúc (time2) khi price chạm zone, hoặc thời điểm hiện tại
  for(int k = 0; k < FVG_count; k++)
  {
    double top = FVG_top[k];
    double bottom = FVG_bottom[k];
    datetime timeC = FVG_timeC[k]; // bar C (mới hơn) - dùng làm start
    datetime timeA = FVG_timeA[k];

    // start time: chọn timeC (bar C) hoặc timeA tùy flag
    datetime start_time = startFromCBar ? timeC : timeA;

    // tìm bar sau timeC (index nhỏ hơn) mà chạm zone (quét forward)
    // xác định index của bar C
    int idxC = iBarShift(symbol, timeframe, timeC, false);
    if(idxC == -1) idxC = 0; // fallback

    bool touched = false;
    datetime end_time = TimeCurrent(); // fallback -> hiện tại

    // quét các bar mới hơn (idx = idxC-1, idxC-2, ..., 0)
    for(int idx = idxC - 1; idx >= 0; idx--)
    {
      double highM = iHigh(symbol, timeframe, idx);
      double lowM  = iLow(symbol, timeframe, idx);
      if(highM == 0 || lowM == 0) continue;

      // Nếu bar này *chạm* zone: nghĩa là phạm vi bar overlap zone
      if(lowM <= top + tol && highM >= bottom - tol)
      {
        touched = true;
        end_time = iTime(symbol, timeframe, idx);
        break;
      }
    }

    // Nếu không tìm thấy bar chạm, set end_time = thời điểm đóng bar hiện tại của timeframe
    if(!touched)
    {
      // lấy time của bar index 0 (nến đóng gần nhất)
      datetime t0 = iTime(symbol, timeframe, 0);
      if(t0 != 0) end_time = t0 + bar_secs; // kéo tới đầu nến hiện tại + 1 bar để dễ nhìn
      else end_time = TimeCurrent();
    }

    // chuẩn hoá: nếu end_time <= start_time thì kéo end_time = start_time + 1 bar
    if(end_time <= start_time) end_time = (datetime)( (long)start_time + (long)bar_secs );

    // Tạo object rectangle name
    string obj = prefix + IntegerToString(k);

    // MQL5 rectangle: ObjectCreate(..., OBJ_RECTANGLE, 0, time1, price1, time2, price2)
    // Tôi đặt (time1= start_time, price1= top) và (time2 = end_time, price2 = bottom)
    // (hàm sẽ tự vẽ vùng giữa top & bottom và thời gian start->end)
    if(!ObjectCreate(0, obj, OBJ_RECTANGLE, 0, start_time, top, end_time, bottom))
    {
      PrintFormat("DrawFVG: Không thể tạo rectangle %s", obj);
      continue;
    }

    // Set properties: không selectable, show in background
    ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, obj, OBJPROP_HIDDEN, false);
    ObjectSetInteger(0, obj, OBJPROP_BACK, true);

    // Màu: bullish = xanh mờ, bearish = đỏ mờ
    uint fill_alpha = 80; // 0..255 (0 trong suốt, 255 đặc)
    uint border_alpha = 0; // border trong suốt

    uint color_fill;
    if(FVG_type[k] == 1) // bullish
    {
      color_fill = MakeARGB((int)fill_alpha, clrDodgerBlue);
    }
    else // bearish
    {
      color_fill = MakeARGB((int)fill_alpha, clrCrimson);
    }

    uint col_border = MakeARGB((int)border_alpha, clrBlack);

    // Gán màu (một số terminal dùng OBJPROP_COLOR cho fill khi màu có alpha)
    ObjectSetInteger(0, obj, OBJPROP_COLOR, (int)col_border);
    // Một số terminal/phiên bản chấp nhận OBJPROP_FILL - nếu không có, property sẽ bị bỏ qua
    // Cố gắng set cả những thuộc tính khả dĩ:
    ObjectSetInteger(0, obj, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, obj, OBJPROP_WIDTH, 1);
    // OBJPROP_COLOR đã set cho border; set màu fill bằng property OBJPROP_BACKGROUND_COLOR nếu có
    // Một số build MQL5 hỗ trợ OBJPROP_BACKCOLOR (không chuẩn), ta thử set tên sau (nếu không hợp lệ compiler sẽ báo)
    // Dùng ObjectSetInteger/Set to attempt; nếu compiler báo lỗi bạn có thể xóa những dòng thử nghiệm này.
    #ifdef __MQL5__
    // try to set fill via OBJPROP_COLOR with alpha (already set), also attempt OBJPROP_COLOR by ObjectSetInteger above
    #endif

    // Set fill by using ObjectSetInteger for OBJPROP_COLOR (again) - terminals usually honor alpha channel
    ObjectSetInteger(0, obj, OBJPROP_COLOR, (int)color_fill);

    // Nếu terminal hỗ trợ OBJPROP_FILL (some do), bật nó:
    // Note: if your compiler complains about OBJPROP_FILL, remove the following line.
    // ObjectSetInteger(0, obj, OBJPROP_FILL, 1);

    // Done for this zone
  } // end for FVG
}

// ------------------------------------------------------------
// UpdateLabel: vẽ label cho 1 timeframe bất kỳ
// labelName  : tên object label muốn hiển thị
// timeframe  : timeframe cần hiển thị (HighTF / MiddleTF / LowTF ...)
// trend      : giá trị trend 1 / 0 / -1
// ------------------------------------------------------------
// ------------------------------------------------------------
// UpdateLabel: vẽ label cho 1 timeframe bất kỳ (không còn hardcode)
// labelName  : tên object label muốn hiển thị (ví dụ "LBL_HTF", "LBL_MTF")
// timeframe  : timeframe cần hiển thị (HighTF / MiddleTF / ...)
// trend      : giá trị trend 1 / 0 / -1
// ------------------------------------------------------------
void UpdateLabel(string labelName, ENUM_TIMEFRAMES timeframe, int trend)
{
    if(!ShowSwingMarkers) return;

    string txt = StringFormat("%s: %s", EnumToString(timeframe), TrendToString(trend));

    // vị trí chung (corner + distance mặc định)
    int corner = CORNER_LEFT_UPPER;
    int xdist  = 10;
    int ydist_default = 20;
    int ydist = ydist_default;

    // nếu timeframe giống MiddleTF (khung nhỏ hơn) -> dịch xuống thêm 1 hàng
    // bạn có thể tinh chỉnh offset_down tuỳ ý (ví dụ 20 px)
    int offset_down = 30;
    if (timeframe == MiddleTF) ydist = ydist_default + offset_down;
    else if(timeframe == LowTF) ydist = ydist_default + offset_down * 2;


    // Nếu object đã tồn tại -> cập nhật text và giữ vị trí
    if(ObjectFind(0, labelName) >= 0)
    {
        ObjectSetString(0, labelName, OBJPROP_TEXT, txt);
        // cập nhật màu (giữ vị trí)
        if(trend == 1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrLime);
        else if(trend == -1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
        else ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrGray);
    }
    else
    {
        // Tạo label mới với vị trí xác định
        if(!ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0))
        {
            Print("UpdateLabel: Không thể tạo object label: ", labelName);
            return;
        }
        ObjectSetInteger(0, labelName, OBJPROP_CORNER, corner);
        ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, xdist);
        ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, ydist);
        ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, SwingMarkerFontSize);
        ObjectSetString(0, labelName, OBJPROP_TEXT, txt);

        // Set màu theo trend
        if(trend == 1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrLime);
        else if(trend == -1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
        else ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrGray);
    }
}

// Trả true nếu bar đóng mới xuất hiện (dựa vào iTime(...,1))
bool IsNewClosedBar(string symbol, ENUM_TIMEFRAMES tf, int slot)
{
  datetime t = iTime(symbol, tf, 1); // time of last closed bar
  if(t == -1 || t == 0) return false;
  if(t != lastClosedBarTime[slot])
  {
    lastClosedBarTime[slot] = t;
    return true;
  }
  return false;
}

// Tính FVG cho MiddleTF chỉ khi bar C (hoặc bar 1) thay đổi
void EnsureFVGUpToDate(string symbol, ENUM_TIMEFRAMES tf, int lookback)
{
  if(tf != MiddleTF) return; // chỉ cache cho MiddleTF (theo EA bạn)
  datetime currentClosed = iTime(symbol, tf, 1);
  if(currentClosed == -1 || currentClosed == 0) return;
  if(currentClosed != lastFVGBarTime)
  {
    // bar vừa thay -> recompute FVG
    FindFVG(symbol, tf, lookback);
    lastFVGBarTime = currentClosed;
    if(PrintToExperts) PrintFormat("EnsureFVGUpToDate: recomputed FVG at %s", TimeToString(currentClosed, TIME_DATE|TIME_MINUTES));
  }
}

// ---------- DetectMSSOnTimeframe (fixed) ----------
void DetectMSSOnTimeframe(string sym, ENUM_TIMEFRAMES tf, int slot, bool enabled,
                       bool requireFVG,
                       double minBreakPips,
                       int consecRequired,
                       int lookForwardBars,
                       int fvgLookback)
{
    if(!enabled) return;
    if(BOS_Count[slot] < 2) return;

    // Chuẩn hoá older/newer theo break_time (older = earlier)
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
    if(older.direction == newer.direction) return; // phải ngược chiều

    // FVG check nếu cần: Yêu cầu FVG phải xuất hiện giữa sweep_time (older.break_time) và break_time (newer.break_time)
    if(requireFVG)
    {
      // recompute FVG nếu cần (cache chỉ cho MiddleTF)
      if(tf == MiddleTF) EnsureFVGUpToDate(sym, tf, fvgLookback);

      // xác định sweep_time (older.break_time) và break_time (newer.break_time)
      datetime sweep_time = older.break_time;
      datetime break_time = newer.break_time;

      // nếu không có sweep_time hoặc break_time -> skip
      if(sweep_time == 0 || break_time == 0 || break_time <= sweep_time)
      {
          if(PrintToExperts) PrintFormat("DetectMSSOnTimeframe: slot=%d requireFVG but invalid times sweep=%s break=%s -> skip",
                                          slot, TimeToString(sweep_time, TIME_DATE|TIME_MINUTES), TimeToString(break_time, TIME_DATE|TIME_MINUTES));
          return;
      }

      bool ok = false;
      if(newer.direction == 1)
          ok = HasBullFVGBetween(sym, tf, sweep_time, break_time, fvgLookback);
      else
          ok = HasBearFVGBetween(sym, tf, sweep_time, break_time, fvgLookback);

      if(!ok)
      {
          if(PrintToExperts) PrintFormat("DetectMSSOnTimeframe: slot=%d requireFVG FAILED between %s and %s for dir=%d -> skip",
                                          slot, TimeToString(sweep_time, TIME_DATE|TIME_MINUTES), TimeToString(break_time, TIME_DATE|TIME_MINUTES), newer.direction);
          return;
      }
    }

    // Lấy giá sweep (swing bị sweep) và break (close của bar phá)
    double pip = GetPipSize(sym);
    double tol = pip * 0.1; // tolerance nhỏ
    double sweep_price = older.broken_sw_price; // **important**
    double break_price = newer.broken_sw_price;  // **important**
    double low_sweap_price = sweep_price;

    if(sweep_price == 0.0 || break_price == 0.0)
    {
      if(PrintToExperts) PrintFormat("DetectMSSOnTimeframe: slot=%d invalid prices sweep=%.5f break=%.5f -> skip", slot, sweep_price, break_price);
      return;
    }

    // Điều kiện MSS theo hướng
    if(newer.direction == 1) // bullish: sweep < break
    {
      if(!(sweep_price + tol < break_price))
      {
        if(PrintToExperts) PrintFormat("DetectMSSOnTimeframe: slot=%d BULL rejected sweep(%.5f) >= break(%.5f)", slot, sweep_price, break_price);
        return;
      }
    }
    else // bearish: sweep > break
    {
      if(!(sweep_price - tol > break_price))
      {
        if(PrintToExperts) PrintFormat("DetectMSSOnTimeframe: slot=%d BEAR rejected sweep(%.5f) <= break(%.5f)", slot, sweep_price, break_price);
        return;
      }
    }

    // Passed -> build MSSInfo
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

    if(PrintToExperts)
      PrintFormat("DetectMSSOnTimeframe: slot=%d MSS PASSED dir=%d sweep=%.5f break=%.5f (olderTime=%s newerTime=%s)",
                  slot, mss.direction, mss.sweep_price, mss.break_price,
                  TimeToString(older.break_time, TIME_DATE|TIME_MINUTES),
                  TimeToString(newer.break_time, TIME_DATE|TIME_MINUTES));

    // Giá vừa chạm MTF FVG (vùng vào lệnh tiềm năng)
    if(watchMSSMode && watchedFVGIndex >= 0)
    {
      // Nếu MSS direction trùng với FVG direction -> MSS thuận chiều
      if(mss.found && mss.direction == watchedFVGDir)
      {
        if(PrintToExperts) PrintFormat("DetectMSSOnTimeframe: MSS direction %d matches watchedFVGDir %d -> disabling watchMSSMode", mss.direction, watchedFVGDir);
        watchMSSMode = false;
        watchedFVGIndex = -1;
        watchedFVGDir = 0;

        SetUpPendingEntryForMSS(mss, slot);
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
    // vẽ tất cả BOS cho slot này (sẽ gọi DrawBOS cho index 0..BOS_Count-1)
  }

  UpdateLabel((tf == HighTF) ? "LBL_HTF" : (tf == MiddleTF) ? "LBL_MTF" : "LBL_LTF", tf, TrendTF[slot]);
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
    CheckWatchMSSInvalidation(sym);
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

  // Xoá 3 label
  if(ObjectFind(0, "LBL_HTF") >= 0) ObjectDelete(0, "LBL_HTF");
  if(ObjectFind(0, "LBL_MTF") >= 0) ObjectDelete(0, "LBL_MTF");
  if(ObjectFind(0, "LBL_LTF") >= 0) ObjectDelete(0, "LBL_LTF");

  // Xóa tất cả object dùng tiền tố SwingObjPrefix (bao gồm htf_/mtf_/ltf_ và FVG)
  int tot = ObjectsTotal(0);
  for(int i = tot - 1; i >= 0; i--)
  {
    string nm = ObjectName(0, i);
    if(StringFind(nm, SwingObjPrefix, 0) == 0)
      ObjectDelete(0, nm);
  }
}
