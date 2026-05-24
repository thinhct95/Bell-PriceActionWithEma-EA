//+------------------------------------------------------------------+
//| LowTfApi.mqh — state Low TF / MSS (tránh include vòng)           |
//+------------------------------------------------------------------+
#ifndef ICT2026_LOWTFAPI_MQH
#define ICT2026_LOWTFAPI_MQH

#include <ICT2026/Types.mqh>

IctLowTfState g_ictLowTf;

ulong IctLowTf_MssM5FvgId() { return g_ictLowTf.mss.m5FvgId; }

ENUM_ICT_MSS_PHASE IctLowTf_MssPhase() { return g_ictLowTf.mss.phase; }

#endif
