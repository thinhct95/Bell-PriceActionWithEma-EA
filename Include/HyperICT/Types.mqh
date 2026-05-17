//+------------------------------------------------------------------+
//| Types.mqh                                                        |
//| Mô hình dữ liệu cho toàn bộ HyperICT (map trực tiếp spec §1–1.4) |
//+------------------------------------------------------------------+
//| ĐÃ GIẢI QUYẾT (ánh xạ spec → code):                              |
//|  • H0,H1,L0,L1 — SwingSet + SwingPoint                          |
//|  • §1.1 trạng thái: ENUM_HTF_STATE (Pullback/CHoCH/Continue/…)    |
//|  • §1.2 Key LV1/L2 + vùng OB — KeyLevelPair, OrderBlockZone     |
//|  • §1.4 update tăng dần — UpdateContext (newH0, newL0, newL02)  |
//|  • Khóa snapshot HTF — HtfContext.snapshotReady, lockedAt       |
//| CHƯA CÓ TRONG FILE NÀY: logic tính toán (nằm ở module khác)     |
//+------------------------------------------------------------------+
#ifndef HYPERICT_TYPES_MQH
#define HYPERICT_TYPES_MQH

//--- §1.1 tiên quyết cấu trúc: HH-HL (bull) / LH-LL (bear)
enum ENUM_STRUCT_BIAS
{
   STRUCT_NONE  = 0,
   STRUCT_BULL  = 1,
   STRUCT_BEAR  = -1
};

//--- §1.1 các trạng thái trend HTF (+ Fib pending, không phải Neutral)
enum ENUM_HTF_STATE
{
   HTF_NEUTRAL           = 0,   // không phân loại được 4 swing / cấu trúc lẫn lộn
   HTF_BULL_INCOMPLETE   = 1,   // HH-HL nhưng Fib hồi H1→L0 chưa đủ (§ tiên quyết)
   HTF_BEAR_INCOMPLETE   = 2,
   HTF_BULL_PULLBACK     = 3,   // Fib OK + giá giữa L0–H0
   HTF_BULL_CHOCH        = 4,   // body phá L0 (Key LV1) hoặc đang phase CHoCH
   HTF_BULL_CONTINUE     = 5,   // body phá H0 (Key LV2) hoặc đang phase Continue
   HTF_BEAR_PULLBACK     = 6,
   HTF_BEAR_CHOCH        = 7,
   HTF_BEAR_CONTINUE     = 8
};

//--- §1.2 / §1.4: sự kiện phá Key level (body close trên bar HTF đóng)
enum ENUM_UPDATE_EVENT
{
   UPD_NONE      = 0,
   UPD_CHOCH     = 1,   // phá Key LV1 → Change of Character
   UPD_CONTINUE  = 2    // phá Key LV2 → tiếp diễn xu hướng
};

//--- §1.4 các giai đoạn sau khi phá Key (không quét lại full lookback)
enum ENUM_UPDATE_PHASE
{
   UPD_PHASE_IDLE          = 0,
   UPD_PHASE_BUILD         = 1,   // P1: track newH0/newL0; P2 CHoCH: xác nhận pivot
   UPD_PHASE_CHOCH_RESOLVE = 2    // CHoCH P3: case1 về bull / case2 confirm bear
};

enum ENUM_CHOCH_BRANCH
{
   CHOCH_BRANCH_NONE = 0,
   CHOCH_BRANCH_BACK_TO_BULL = 1,
   CHOCH_BRANCH_CONFIRM_BEAR = 2
};

//--- Đỉnh/đáy pivot (từ hiện tại về trước: H0/L0 mới nhất)
struct SwingPoint
{
   double   price;
   datetime time;
   int      shift;
   void Clear()
   {
      price = 0.0;
      time  = 0;
      shift = -1;
   }
   bool Valid() const { return shift >= 0 && price > 0.0; }
};

//--- §1.2 vùng cung/cầu: swing → biên OB (nến đỏ @ L0 / nến xanh @ H0)
struct OrderBlockZone
{
   double   swingPrice;
   double   obHigh;
   double   obLow;
   datetime obTime;
   int      obShift;
   bool     valid;
   void Clear()
   {
      swingPrice = obHigh = obLow = 0.0;
      obTime = 0;
      obShift = -1;
      valid = false;
   }
};

//--- §1.2 Key LV1 / Key LV2 (giá + zone vẽ rectangle)
struct KeyLevelPair
{
   double         price;
   OrderBlockZone zone;
};

//--- Bộ swing khóa: H0,H1,L0,L1
struct SwingSet
{
   SwingPoint h0, h1, l0, l1;
   bool       hasH0, hasH1, hasL0, hasL1;
   bool       IsComplete() const
   {
      return hasH0 && hasH1 && hasL0 && hasL1;
   }
   void Clear()
   {
      h0.Clear(); h1.Clear(); l0.Clear(); l1.Clear();
      hasH0 = hasH1 = hasL0 = hasL1 = false;
   }
};

//--- §1.4 ngữ cảnh cập nhật incremental (newH0/newL0/newL02, khóa khi pivot confirm)
struct UpdateContext
{
   ENUM_UPDATE_EVENT   event;
   ENUM_UPDATE_PHASE   phase;
   ENUM_CHOCH_BRANCH   chochBranch;
   SwingPoint          newH0;
   SwingPoint          newL0;
   SwingPoint          newL02;      // CHoCH bull case2 → roll thành L0
   bool                newH0Locked; // ngừng track high khi swing confirm
   bool                newLLocked;
   bool                case1TrackingH0; // CHoCH P3 case1: đang tạo đỉnh mới
   void Clear()
   {
      event = UPD_NONE;
      phase = UPD_PHASE_IDLE;
      chochBranch = CHOCH_BRANCH_NONE;
      newH0.Clear(); newL0.Clear(); newL02.Clear();
      newH0Locked = newLLocked = false;
      case1TrackingH0 = false;
   }
};

//--- Trạng thái runtime toàn EA (một snapshot HTF tại thời điểm bot chạy / sau roll)
struct HtfContext
{
   string            symbol;
   ENUM_TIMEFRAMES   htf;
   SwingSet          swings;
   ENUM_STRUCT_BIAS  structBias;
   bool              fibOk;         // § tiên quyết Fib (chỉ ý nghĩa pullback hợp lệ)
   KeyLevelPair      keyLv1;
   KeyLevelPair      keyLv2;
   ENUM_HTF_STATE    state;
   UpdateContext     update;
   datetime          lockedAt;
   datetime          lastHtfBar;
   bool              snapshotReady;
};

#endif // HYPERICT_TYPES_MQH
