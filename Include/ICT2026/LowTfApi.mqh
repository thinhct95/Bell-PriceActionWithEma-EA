//+------------------------------------------------------------------+
//| LowTfApi.mqh — shared state cho Low TF pipeline (anti-cycle)     |
//+------------------------------------------------------------------+
//| Tách g_ictLowTf khỏi LowTfTrend.mqh để các module MssSetup /      |
//| MssEntry / FvgDraw / MssDraw / EaState có thể include shared    |
//| state mà KHÔNG tạo vòng phụ thuộc với LowTfTrend.mqh.             |
//|                                                                   |
//| Globals owned:                                                    |
//|   g_ictLowTf  — IctLowTfState {                                   |
//|     lastBarTime, lastConfirmBarTime,                              |
//|     mss (IctMssState — phase, h1FvgId, chochLocked, …),          |
//|     activeCount, availableCount, confirmFvgCount,                |
//|     displayReason                                                 |
//|   }                                                               |
//|                                                                   |
//| Helpers chính:                                                    |
//|   ENUM_ICT_FVG_SIDE IctFvgSideFromBias(bias)                      |
//|   string IctFvgSideText(side) / IctMarketSideText(side)           |
//+------------------------------------------------------------------+
#ifndef ICT2026_LOWTFAPI_MQH
#define ICT2026_LOWTFAPI_MQH

#include <ICT2026/Types.mqh>

IctLowTfState g_ictLowTf;

ulong IctLowTf_MssM5FvgId() { return g_ictLowTf.mss.m5FvgId; }

ENUM_ICT_MSS_PHASE IctLowTf_MssPhase() { return g_ictLowTf.mss.phase; }

#endif
