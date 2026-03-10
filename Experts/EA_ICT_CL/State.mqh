#ifndef EA_ICT_CL__STATE_MQH
#define EA_ICT_CL__STATE_MQH  // Tránh include trùng

// Module: State – enums và struct dùng chung toàn EA

//====================================================
// ENUMS
//====================================================
enum EAState
{
  EA_IDLE,         // Chờ chọn FVG tốt nhất
  EA_WAIT_TOUCH,   // Chờ giá chạm vào vùng FVG
  EA_WAIT_TRIGGER, // Đã touch FVG, chờ M5 MSS
  EA_IN_TRADE      // Đã gửi pending / đang giữ position
};

enum HTFBias    { BIAS_NONE=0, BIAS_UP=1, BIAS_DOWN=-1, BIAS_SIDEWAY=2 };  // Bias D1
enum MarketDir  { DIR_NONE=0,  DIR_UP=1,  DIR_DOWN=-1                  };  // Hướng trend H1/M5
enum BlockReason
{
  BLOCK_NONE, BLOCK_SESSION, BLOCK_DAILY_LOSS,   // Không chặn / chặn session / chặn daily loss
  BLOCK_BIAS_MISMATCH, BLOCK_NO_BIAS            // Bias không khớp H1 / không có bias
};
enum FVGStatus
{
  FVG_PENDING,   // Chưa bị giá chạm
  FVG_TOUCHED,   // Đã chạm, chờ MSS
  FVG_USED       // Đã dùng (broken/expired/triggered)
};

//====================================================
// STRUCTS
//====================================================
struct BiasContext
{
  HTFBias  bias;           // UP/DOWN/SIDEWAY/NONE
  double   rangeHigh, rangeLow;  // Vùng sideway (nếu có)
  datetime lastBarTime;    // Thời gian bar D1 đã xử lý (tránh cập nhật trùng)
};

struct TFTrendContext
{
  MarketDir trend;         // DIR_UP / DIR_DOWN / DIR_NONE
  double    h0, h1, l0, l1;   // Giá 2 swing high, 2 swing low gần nhất
  int       idxH0, idxH1, idxL0, idxL1;  // Chỉ số bar tương ứng
  double    keyLevel;      // Mức key (l0 hoặc h0 tùy trend)
  datetime  lastBarTime;  // Bar đã cập nhật (tránh cập nhật lại mỗi tick)

  datetime  lastMssTime;   // Thời gian MSS gần nhất (chỉ M5)
  double    lastMssLevel;  // Giá entry MSS (tH0 hoặc tL0)
  MarketDir lastMssBreak;  // Hướng break (UP/DOWN)
  double    mssSLSwing;   // Giá SL tương ứng (tL0 hoặc tH0)
};

struct FVGRecord
{
  int       id;            // ID FVG trong pool
  FVGStatus status;        // PENDING / TOUCHED / USED
  int       usedCase;      // 0=expired, 1=broken, 2=triggered by MSS
  MarketDir direction;    // DIR_UP (bull FVG) / DIR_DOWN (bear FVG)
  double    high, low, mid;  // Vùng gap và điểm giữa
  datetime  createdTime;   // Thời điểm tạo FVG
  datetime  touchTime;     // Thời điểm giá chạm (nếu TOUCHED)
  datetime  usedTime;      // Thời điểm chuyển USED
  MarketDir triggerTrendAtTouch;  // Trend M5 lúc touch (debug)

  datetime  mssTime;       // Thời điểm MSS (nếu usedCase==2)
  double    mssEntry;      // Entry level từ MSS
  double    mssSL;         // SL level từ MSS
};

struct OrderPlan
{
  bool   valid;            // Plan có hợp lệ không
  int    direction;        // +1 buy, -1 sell
  double entry, stopLoss, takeProfit, lot;  // Giá và khối lượng
  int    parentFVGId;      // ID FVG gốc (để trace)
};

struct DailyRiskContext
{
  double   startBalance, currentBalance;  // Balance đầu ngày và hiện tại
  datetime dayStartTime;   // Mốc đầu ngày D1
  bool     limitHit;       // Đã chạm max daily loss chưa
};

#endif // EA_ICT_CL__STATE_MQH
