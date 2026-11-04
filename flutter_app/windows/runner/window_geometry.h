#ifndef RUNNER_WINDOW_GEOMETRY_H_
#define RUNNER_WINDOW_GEOMETRY_H_

/*
 * window_geometry.h - pure maximize placement used by the Win32 runner.
 *
 * Windows' MINMAXINFO.ptMaxPosition is relative to the monitor origin, while
 * rcWork/rcMonitor are virtual-desktop screen coordinates. A secondary or
 * negative-origin monitor therefore must use work - monitor, not work directly.
 *
 * Kept as a small C-compatible header so the geometry can be unit tested without
 * a GPU/window and reused from the C++ runner.
 */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TsPixelRect {
    long left;
    long top;
    long right;
    long bottom;
} TsPixelRect;

typedef struct TsMaximizePlacement {
    long x;
    long y;
    long width;
    long height;
} TsMaximizePlacement;

static inline TsMaximizePlacement ts_maximize_placement(TsPixelRect monitor,
                                                        TsPixelRect work)
{
    TsMaximizePlacement placement;
    placement.x = work.left - monitor.left;
    placement.y = work.top - monitor.top;
    placement.width = work.right - work.left;
    placement.height = work.bottom - work.top;
    return placement;
}

#ifdef __cplusplus
}
#endif

#endif /* RUNNER_WINDOW_GEOMETRY_H_ */
