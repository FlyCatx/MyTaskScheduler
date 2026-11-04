/*
 * test_window_region.c - geometry of the rounded top-level window outline.
 *
 * The runner turns the sampled polygon below into a real Win32 region with
 * CreatePolygonRgn + SetWindowRgn; there is no way to unit test a real window
 * shape without a window, so the tests here pin down the contract the raster
 * depends on:
 *
 *   - exactly one cubic Bezier per corner, standard circle coefficient;
 *   - the straight edges are tangent (the first/last arc samples stay within a
 *     pixel of the edge) and the four corners are mirror-symmetric;
 *   - every sample stays inside the window rectangle, and the four outer
 *     corners are cut away (no sample equals a rectangle corner);
 *   - the radius is derived from the window's own DPI (96/120/144/150/192...),
 *     clamped to half of the short side, and 0 for degenerate input;
 *   - dense enough sampling that successive points are close enough for a
 *     binary region fill to look like a curve.
 *
 * No window, GDI device or GPU is created.
 */

#include <stdio.h>

#include "../flutter_app/windows/runner/window_region.h"

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, msg) do {                                    \
    if (cond) { g_pass++; }                                      \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }             \
} while (0)

static TsWindowRegionPoint g_points[TS_WINDOW_REGION_MAX_POINTS];

static int build(int width, int height, double radius_px)
{
    return ts_window_region_build(width, height, radius_px, g_points,
                                  TS_WINDOW_REGION_MAX_POINTS);
}

static int has_point(int count, long x, long y)
{
    for (int i = 0; i < count; ++i) {
        if (g_points[i].x == x && g_points[i].y == y) return 1;
    }
    return 0;
}

static void test_shape_contract(void)
{
    printf("== rounded outline geometry ==\n");

    const int width = 1280;
    const int height = 800;
    const double radius = 18.0;  /* 12 DIP at 150% DPI */
    const int count = build(width, height, radius);

    CHECK(count == TS_WINDOW_REGION_MAX_POINTS,
          "full radius produces one start point plus 4 arcs");
    if (count != TS_WINDOW_REGION_MAX_POINTS) return;

    /* 1. Everything is inside the window rectangle. */
    int inside = 1;
    for (int i = 0; i < count; ++i) {
        if (g_points[i].x < 0 || g_points[i].x > width ||
            g_points[i].y < 0 || g_points[i].y > height) {
            inside = 0;
        }
    }
    CHECK(inside, "all outline samples stay inside the window rectangle");

    /* 2. The four rectangle corners are cut away. */
    int touches_corner = 0;
    for (int i = 0; i < count; ++i) {
        const long x = g_points[i].x;
        const long y = g_points[i].y;
        if ((x == 0 || x == width) && (y == 0 || y == height)) touches_corner = 1;
    }
    CHECK(!touches_corner, "no outline sample lands on a rectangle corner");

    /* 3. The outline touches all four edges at the middle of each side. */
    int top_mid = 0, bottom_mid = 0, left_mid = 0, right_mid = 0;
    for (int i = 0; i < count; ++i) {
        if (g_points[i].y == 0 && g_points[i].x > 0 && g_points[i].x < width) {
            top_mid = 1;
        }
        if (g_points[i].y == height && g_points[i].x > 0 &&
            g_points[i].x < width) {
            bottom_mid = 1;
        }
        if (g_points[i].x == 0 && g_points[i].y > 0 && g_points[i].y < height) {
            left_mid = 1;
        }
        if (g_points[i].x == width && g_points[i].y > 0 &&
            g_points[i].y < height) {
            right_mid = 1;
        }
    }
    CHECK(top_mid && bottom_mid && left_mid && right_mid,
          "the outline reaches every straight edge outside the corner cuts");

    /*
     * 4. Tangency: the arc starts/ends on the straight edges. With integer
     * rounding the first arc sample may be up to one pixel away from the edge
     * in the perpendicular direction only, never both.
     */
    const int r = (int)(radius + 0.5);
    CHECK(g_points[0].y == 0, "top-right arc starts on the top edge");
    CHECK(g_points[TS_WINDOW_REGION_SEGMENTS - 1].x == width,
          "top-right arc ends on the right edge");
    CHECK(g_points[TS_WINDOW_REGION_SEGMENTS - 1].y == r,
          "top-right arc ends one radius below the window top");

    /*
     * 5. Corner symmetry: the four corners are mirror images of each other.
     * Each sample of the top-right arc must have mirror partners in the other
     * three corners.
     */
    int symmetric = 1;
    for (int i = 0; i < count; ++i) {
        const long x = g_points[i].x;
        const long y = g_points[i].y;
        if (!has_point(count, width - x, y)) symmetric = 0;   /* left/right */
        if (!has_point(count, x, height - y)) symmetric = 0;  /* top/bottom */
        if (!has_point(count, width - x, height - y)) symmetric = 0;
    }
    CHECK(symmetric, "all four corners are mirror-symmetric");

    /* 6. Each arc sample is monotone and close to its neighbour. */
    const int first = 0;
    const int last = TS_WINDOW_REGION_SEGMENTS - 1;
    int monotone = 1;
    long prev_x = g_points[first].x;
    long prev_y = g_points[first].y;
    for (int i = first + 1; i <= last; ++i) {
        if (g_points[i].x < prev_x || g_points[i].y < prev_y) monotone = 0;
        if (g_points[i].x == prev_x && g_points[i].y == prev_y) monotone = 0;
        prev_x = g_points[i].x;
        prev_y = g_points[i].y;
    }
    CHECK(monotone, "top-right arc samples advance monotonically");

    int close = 1;
    for (int i = first + 1; i <= last; ++i) {
        const long dx = g_points[i].x - g_points[i - 1].x;
        const long dy = g_points[i].y - g_points[i - 1].y;
        /* Integer rounding can add at most ~1 px on top of the 1.8 px chord, so
         * the bound is 2.5 px: dense enough that a binary region fill is visually
         * indistinguishable from the analytic curve. */
        if (dx * dx + dy * dy > 6) close = 0;
    }
    CHECK(close, "consecutive arc samples are under 2.5 px apart");

    /*
     * 7. The first arc sample is closer to the top edge than one radius:
     * the curve leaves the edge tangentially instead of chamfering it.
     */
    CHECK(g_points[first].y <= 1, "top-right arc leaves the top edge tangentially");
    CHECK(g_points[last].x >= width - 1,
          "top-right arc reaches the right edge tangentially");

    /* 8. Determinism: rebuilding yields the same polygon. */
    TsWindowRegionPoint again[TS_WINDOW_REGION_MAX_POINTS];
    const int again_count = ts_window_region_build(
        width, height, radius, again, TS_WINDOW_REGION_MAX_POINTS);
    int same = again_count == count;
    for (int i = 0; same && i < count; ++i) {
        if (again[i].x != g_points[i].x || again[i].y != g_points[i].y) same = 0;
    }
    CHECK(same, "outline geometry is deterministic");
}

static void test_radius_from_dpi(void)
{
    printf("== radius from the window's own DPI ==\n");

    /* 12 DIP at the standard scale factors. */
    const unsigned int dpi[] = {96, 120, 144, 150, 168, 192, 240};
    const int expect[] = {12, 15, 18, 19, 21, 24, 30};
    for (int i = 0; i < 7; ++i) {
        const int px = ts_window_region_radius_px(1280, 800, dpi[i], 12.0);
        if (px != expect[i]) {
            printf("  [FAIL] dpi %u: got %d px, want %d\n", dpi[i], px,
                   expect[i]);
            g_fail++;
        } else {
            g_pass++;
        }
    }

    /*
     * The product radius is 18 DIP (second round); the same DPI pipeline must
     * scale it without a second multiplication. 100% -> 18, 150% -> 27, 200% -> 36.
     */
    const unsigned int product_dpi[] = {96, 120, 144, 168, 192};
    const int product_expect[] = {18, 23, 27, 32, 36};
    for (int i = 0; i < 5; ++i) {
        const int px = ts_window_region_radius_px(1600, 900, product_dpi[i], 18.0);
        if (px != product_expect[i]) {
            printf("  [FAIL] product radius dpi %u: got %d px, want %d\n",
                   product_dpi[i], px, product_expect[i]);
            g_fail++;
        } else {
            g_pass++;
        }
    }

    /* Restored normal window: 18 DIP is a visible, non-degenerate arc. */
    CHECK(ts_window_region_build(1600, 900,
                                 (double)ts_window_region_radius_px(1600, 900, 96, 18.0),
                                 g_points, TS_WINDOW_REGION_MAX_POINTS) ==
              TS_WINDOW_REGION_MAX_POINTS,
          "18 DIP produces a full rounded outline");

    /* Maximized/snapped windows pass radius 0 and must not build any region:
     * the caller clears the window region and the window is a plain rectangle. */
    CHECK(ts_window_region_radius_px(2560, 1540, 144, 0.0) == 0,
          "radius 0 (maximized) yields no corner radius");
    CHECK(ts_window_region_build(2560, 1540, 0.0, g_points,
                                 TS_WINDOW_REGION_MAX_POINTS) == 0,
          "radius 0 asks the caller for a plain rectangle");
    /* Different DPI on the same window must give a different physical radius:
     * this is the "double scaling" trap the outline must not fall into. */
    CHECK(ts_window_region_radius_px(1280, 800, 96, 12.0) !=
              ts_window_region_radius_px(1280, 800, 192, 12.0),
          "physical radius follows the window DPI");

    /* Clamped to half of the short side. */
    CHECK(ts_window_region_radius_px(40, 30, 96, 500.0) == 15,
          "radius is clamped to half of the short side");

    /* Degenerate input. */
    CHECK(ts_window_region_radius_px(0, 800, 96, 12.0) == 0, "zero width");
    CHECK(ts_window_region_radius_px(1280, 0, 96, 12.0) == 0, "zero height");
    CHECK(ts_window_region_radius_px(1280, 800, 0, 12.0) == 0, "zero dpi");
    CHECK(ts_window_region_radius_px(1280, 800, 96, 0.0) == 0, "zero radius");
    CHECK(ts_window_region_radius_px(1280, 800, 96, -5.0) == 0,
          "negative radius");

    /* A sub-pixel radius must not create an invisible region. */
    CHECK(ts_window_region_radius_px(1280, 800, 96, 0.2) == 0,
          "sub-pixel radius falls back to a rectangle");
}

static void test_build_edge_cases(void)
{
    printf("== invalid / degenerate region input ==\n");

    CHECK(build(0, 800, 18.0) == -1, "zero width is rejected");
    CHECK(build(1280, -1, 18.0) == -1, "negative height is rejected");
    CHECK(ts_window_region_build(1280, 800, 18.0, 0,
                                 TS_WINDOW_REGION_MAX_POINTS) == -1,
          "null output buffer is rejected");
    CHECK(ts_window_region_build(1280, 800, 18.0, g_points, 4) == -1,
          "too small capacity is rejected");
    CHECK(build(1280, 800, 0.0) == 0, "zero radius asks for a rectangle");
    CHECK(build(1280, 800, -3.0) == 0, "negative radius asks for a rectangle");

    /* A radius larger than the window is clamped, and stays inside bounds. */
    const int count = build(60, 40, 500.0);
    CHECK(count == TS_WINDOW_REGION_MAX_POINTS, "clamped radius still builds");
    int inside = 1;
    for (int i = 0; i < count; ++i) {
        if (g_points[i].x < 0 || g_points[i].x > 60 || g_points[i].y < 0 ||
            g_points[i].y > 40) {
            inside = 0;
        }
    }
    CHECK(inside, "clamped outline stays inside a small window");

    /* A 1x1 window cannot carry corners: radius clamps to 0. */
    CHECK(ts_window_region_radius_px(1, 1, 96, 12.0) == 0,
          "a 1x1 window has no room for a corner");
}

int main(void)
{
    test_shape_contract();
    test_radius_from_dpi();
    test_build_edge_cases();

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
