#ifndef RUNNER_WINDOW_REGION_H_
#define RUNNER_WINDOW_REGION_H_

/*
 * window_region.h - the top-level window's outer outline, shared by the Win32
 * runner and the offline C tests.
 *
 * Why a polygon builder instead of PathToRegion:
 *   - The outline is four straight edges joined by one explicit cubic Bezier
 *     per corner (the standard quarter-circle approximation, k = 0.5522847...).
 *   - Flutter clips and strokes the *same* mathematical path, so both layers
 *     must agree exactly. Flattening the cubic here with a fixed, DPI-safe
 *     segment count keeps the sampled polygon within 0.05 physical pixels of
 *     the Dart path (see ts_window_region_build) and makes the geometry
 *     unit-testable without a GDI device or a window.
 *
 * Coordinates are physical pixels relative to the window's top-left corner,
 * which is the same origin SetWindowRgn uses. The runner must pass the
 * *applied* window rectangle, not a requested or suggested one.
 *
 * All functions are static inline so the runner and tests share one copy and
 * the test target needs no extra object file.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Standard quarter-circle cubic Bezier coefficient: 4/3 * (sqrt(2) - 1). */
#define TS_WINDOW_REGION_BEZIER_K 0.5522847498307936

/*
 * Samples per corner arc. A quarter arc of radius 48 physical pixels is split
 * into 16 chords; the largest sagitta is r * (1 - cos(pi / 64)) ~= 0.058 px, so
 * the rasterised outline is visually identical to the analytic curve while
 * staying small enough to build on every size/DPI change.
 */
#define TS_WINDOW_REGION_SEGMENTS 16

/* 4 corners x TS_WINDOW_REGION_SEGMENTS samples; the polygon closes itself. */
#define TS_WINDOW_REGION_MAX_POINTS (4 * TS_WINDOW_REGION_SEGMENTS)

typedef struct TsWindowRegionPoint {
    long x;
    long y;
} TsWindowRegionPoint;

static inline long ts_window_region_round(double value)
{
    /* llround() equivalent without <math.h>: half away from zero. */
    return (long)(value >= 0.0 ? (value + 0.5) : (value - 0.5));
}

/*
 * Corner radius in physical pixels from a DIP radius and the window's own DPI.
 * Returns 0 for degenerate input so callers can fall back to an unrounded
 * rectangle instead of creating an invisible region.
 */
static inline int ts_window_region_radius_px(int width, int height,
                                             unsigned int dpi,
                                             double radius_dip)
{
    if (width <= 0 || height <= 0 || dpi == 0 || !(radius_dip > 0.0)) {
        return 0;
    }
    double px = radius_dip * (double)dpi / 96.0;
    const double limit = (double)(width < height ? width : height) / 2.0;
    if (px > limit) px = limit;
    /* A corner needs at least one whole physical pixel of arc; below that the
     * outline degenerates to a rectangle instead of an invisible region. */
    if (px < 1.0) return 0;
    return (int)ts_window_region_round(px);
}

/*
 * Fills |out| with the closed outline polygon and returns the number of points.
 *
 * Returns:
 *     > 0  point count (always TS_WINDOW_REGION_MAX_POINTS for a valid radius)
 *       0  degenerate radius: caller should use a plain rectangle
 *      -1  invalid input (non-positive size, null buffer, too small capacity)
 *
 * The polygon starts on the top edge at (r, 0), walks clockwise (top edge is
 * implicit, then the top-right, bottom-right, bottom-left and top-left arcs)
 * and closes back onto the start point. Straight edges are represented by the
 * implicit polygon segments between arc endpoints, so the outline is tangent
 * continuous: the first sample of each arc stays within one pixel of the edge.
 */
static inline int ts_window_region_build(int width, int height,
                                         double radius_px,
                                         TsWindowRegionPoint *out,
                                         int capacity)
{
    if (width <= 0 || height <= 0 || out == 0) return -1;
    if (!(radius_px > 0.0)) return 0;

    double r = radius_px;
    const double limit = (double)(width < height ? width : height) / 2.0;
    if (r > limit) r = limit;
    if (r < 1.0) return 0;
    if (capacity < TS_WINDOW_REGION_MAX_POINTS) return -1;

    const double w = (double)width;
    const double c = r * TS_WINDOW_REGION_BEZIER_K;
    int count = 0;

    /*
     * Only the top-right arc is evaluated as a curve; the other three corners
     * are exact integer mirrors of it. That keeps the outline bit-for-bit
     * symmetric (independent rounding of each corner would not) and halves the
     * per-resize work.
     */
    long arc_x[TS_WINDOW_REGION_SEGMENTS];
    long arc_y[TS_WINDOW_REGION_SEGMENTS];
    {
        const double x0 = w - r, y0 = 0.0;
        const double x1 = w - r + c, y1 = 0.0;
        const double x2 = w, y2 = r - c;
        const double x3 = w, y3 = r;
        for (int step = 1; step <= TS_WINDOW_REGION_SEGMENTS; ++step) {
            const double t = (double)step / (double)TS_WINDOW_REGION_SEGMENTS;
            const double u = 1.0 - t;
            /* Cubic Bezier: B(t) = u^3*P0 + 3u^2t*P1 + 3ut^2*P2 + t^3*P3. */
            const double a = u * u * u;
            const double b = 3.0 * u * u * t;
            const double d = 3.0 * u * t * t;
            const double e = t * t * t;
            arc_x[step - 1] = ts_window_region_round(a * x0 + b * x1 + d * x2 + e * x3);
            arc_y[step - 1] = ts_window_region_round(a * y0 + b * y1 + d * y2 + e * y3);
        }
    }

    /* Top-right: (w-r,0) -> (w,r), as sampled; the polygon starts here. */
    for (int i = 0; i < TS_WINDOW_REGION_SEGMENTS; ++i) {
        out[count].x = arc_x[i];
        out[count].y = arc_y[i];
        count++;
    }
    /* Bottom-right: (w,h-r) -> (w-r,h): the top-right arc mirrored vertically
     * and traversed backwards. */
    for (int i = TS_WINDOW_REGION_SEGMENTS - 1; i >= 0; --i) {
        out[count].x = arc_x[i];
        out[count].y = (long)height - arc_y[i];
        count++;
    }
    /* Bottom-left: (r,h) -> (0,h-r): mirrored on both axes, forward. */
    for (int i = 0; i < TS_WINDOW_REGION_SEGMENTS; ++i) {
        out[count].x = (long)width - arc_x[i];
        out[count].y = (long)height - arc_y[i];
        count++;
    }
    /* Top-left: (0,r) -> (r,0): mirrored horizontally, backwards. The last
     * sample closes the polygon onto out[0]. */
    for (int i = TS_WINDOW_REGION_SEGMENTS - 1; i >= 0; --i) {
        out[count].x = (long)width - arc_x[i];
        out[count].y = arc_y[i];
        count++;
    }
    return count;
}

#ifdef __cplusplus
}
#endif

#endif /* RUNNER_WINDOW_REGION_H_ */
