/*
 * test_window_geometry.c — maximize placement math for multi-monitor layouts.
 *
 * Window MAXINFO.ptMaxPosition is relative to the monitor origin; the test
 * covers the primary, a right-hand secondary, a negative-origin left monitor and
 * a top taskbar. No window/GPU is created.
 */

#include <stdio.h>

#include "../flutter_app/windows/runner/window_geometry.h"

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, msg) do {                                    \
    if (cond) { g_pass++; }                                      \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }             \
} while (0)

static void expect_placement(const char *name, TsPixelRect monitor,
                             TsPixelRect work, long x, long y, long w, long h)
{
    const TsMaximizePlacement p = ts_maximize_placement(monitor, work);
    if (p.x != x || p.y != y || p.width != w || p.height != h) {
        printf("  [FAIL] %s: got (%ld,%ld %ldx%ld), want (%ld,%ld %ldx%ld)\n",
               name, p.x, p.y, p.width, p.height, x, y, w, h);
        g_fail++;
        return;
    }
    g_pass++;
}

int main(void)
{
    printf("== maximize placement ==\n");

    /* 主屏 2560x1600，底部任务栏 60px。 */
    expect_placement("primary bottom taskbar",
                     (TsPixelRect){0, 0, 2560, 1600},
                     (TsPixelRect){0, 0, 2560, 1540},
                     0, 0, 2560, 1540);

    /* 右侧副屏：虚拟桌面 x=2560，ptMaxPosition 仍相对该屏。 */
    expect_placement("secondary right",
                     (TsPixelRect){2560, 0, 5120, 1600},
                     (TsPixelRect){2560, 0, 5120, 1540},
                     0, 0, 2560, 1540);

    /* 左侧负坐标屏。 */
    expect_placement("negative origin left",
                     (TsPixelRect){-1920, 0, 0, 1080},
                     (TsPixelRect){-1920, 0, 0, 1040},
                     0, 0, 1920, 1040);

    /* 副屏任务栏在顶部：工作区顶部偏移 40。 */
    expect_placement("secondary top taskbar",
                     (TsPixelRect){1920, 0, 4480, 1440},
                     (TsPixelRect){1920, 40, 4480, 1440},
                     0, 40, 2560, 1400);

    /* 负原点 + 顶部任务栏。 */
    expect_placement("negative origin + top taskbar",
                     (TsPixelRect){-2560, -200, 0, 1240},
                     (TsPixelRect){-2560, -160, 0, 1240},
                     0, 40, 2560, 1400);

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
