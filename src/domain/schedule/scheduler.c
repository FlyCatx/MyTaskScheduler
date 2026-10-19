/*
 * scheduler.c — 依赖图构建、拓扑分层、就绪状态、评分与建议顺序。
 *
 * 主要函数：ts_schedule_build、ts_schedule_result_free、ts_schedule_status、ts_status_view_free。
 */

#include "scheduler.h"
#include "runtime.h"
#include "mem.h"

#include <stdio.h>
#include <string.h>
#include <math.h>

/* ------------------------------------------------------------------ */
/* 图上下文                                                            */
/* ------------------------------------------------------------------ */

typedef struct SchedCtx {
    const TsPlan *plan;
    size_t n;
    size_t **pred; size_t *pred_count;   /* 前驱（= depends_on 的下标） */
    size_t **succ; size_t *succ_count;   /* 后继 */
    int *level;                          /* 拓扑层级 */
    int *depth;                          /* 向后最长依赖边数 */
    int *ext_status;                     /* 0 ok / 1 unmet / 2 unknown */
    unsigned char **reach;               /* reach[i][j] = 严格后代 */
    size_t *topo; size_t topo_count;     /* 拓扑序 */
    size_t *cycle; size_t cycle_count;   /* 循环成员（若有） */
} SchedCtx;

static size_t find_index(const TsPlan *p, const char *id)
{
    size_t i;
    for (i = 0; i < p->task_count; i++) {
        if (p->tasks[i].id != NULL && strcmp(p->tasks[i].id, id) == 0) return i;
    }
    return SIZE_MAX;
}

static int ext_status_of(const TsTask *t)
{
    size_t k;
    int has_unknown = 0;
    for (k = 0; k < t->preconditions_count; k++) {
        if (t->preconditions[k].status == TS_PRECOND_UNMET) return 1;
        if (t->preconditions[k].status == TS_PRECOND_UNKNOWN) has_unknown = 1;
    }
    return has_unknown ? 2 : 0;
}

static void ctx_free(SchedCtx *ctx)
{
    size_t i;
    if (ctx->pred != NULL) {
        for (i = 0; i < ctx->n; i++) ts_free(ctx->pred[i]);
    }
    if (ctx->succ != NULL) {
        for (i = 0; i < ctx->n; i++) ts_free(ctx->succ[i]);
    }
    if (ctx->reach != NULL) {
        for (i = 0; i < ctx->n; i++) ts_free(ctx->reach[i]);
    }
    ts_free(ctx->pred);
    ts_free(ctx->pred_count);
    ts_free(ctx->succ);
    ts_free(ctx->succ_count);
    ts_free(ctx->level);
    ts_free(ctx->depth);
    ts_free(ctx->ext_status);
    ts_free(ctx->reach);
    ts_free(ctx->topo);
    ts_free(ctx->cycle);
    memset(ctx, 0, sizeof(*ctx));
}

static int ctx_oom(char *err, size_t err_sz)
{
    snprintf(err, err_sz, "内存分配失败");
    return 1;
}

/* 构建前驱/后继图；依赖不存在则报错。 */
static int build_graph(SchedCtx *ctx, const TsPlan *plan, char *err, size_t err_sz)
{
    size_t i, j;
    size_t n = plan->task_count;
    size_t *scap, *scur;

    memset(ctx, 0, sizeof(*ctx));
    ctx->plan = plan;
    ctx->n = n;

    ctx->pred_count = (size_t *)ts_calloc(n, sizeof(size_t));
    ctx->succ_count = (size_t *)ts_calloc(n, sizeof(size_t));
    ctx->pred = (size_t **)ts_calloc(n, sizeof(size_t *));
    ctx->succ = (size_t **)ts_calloc(n, sizeof(size_t *));
    scap = (size_t *)ts_calloc(n, sizeof(size_t));
    scur = (size_t *)ts_calloc(n, sizeof(size_t));
    if (!ctx->pred_count || !ctx->succ_count || !ctx->pred || !ctx->succ || !scap || !scur) {
        ts_free(scap); ts_free(scur);
        return ctx_oom(err, err_sz);
    }

    /* 校验依赖存在性，并统计后继数量 */
    for (i = 0; i < n; i++) {
        const TsTask *t = &plan->tasks[i];
        ctx->pred_count[i] = t->depends_on_count;
        for (j = 0; j < t->depends_on_count; j++) {
            size_t p = find_index(plan, t->depends_on[j]);
            if (p == SIZE_MAX) {
                snprintf(err, err_sz, "任务 %s 依赖的 %s 不存在", t->id, t->depends_on[j]);
                ts_free(scap); ts_free(scur);
                return 1;
            }
            scap[p]++;
        }
    }

    for (i = 0; i < n; i++) {
        if (ctx->pred_count[i] > 0) {
            ctx->pred[i] = (size_t *)ts_malloc(ctx->pred_count[i] * sizeof(size_t));
            if (ctx->pred[i] == NULL) {
                ts_free(scap); ts_free(scur);
                return ctx_oom(err, err_sz);
            }
        }
        if (scap[i] > 0) {
            ctx->succ[i] = (size_t *)ts_malloc(scap[i] * sizeof(size_t));
            if (ctx->succ[i] == NULL) {
                ts_free(scap); ts_free(scur);
                return ctx_oom(err, err_sz);
            }
        }
    }

    /* 填充前驱与后继 */
    for (i = 0; i < n; i++) {
        const TsTask *t = &plan->tasks[i];
        for (j = 0; j < t->depends_on_count; j++) {
            size_t p = find_index(plan, t->depends_on[j]);
            ctx->pred[i][j] = p;
            ctx->succ[p][scur[p]++] = i;
        }
    }
    for (i = 0; i < n; i++) ctx->succ_count[i] = scap[i];

    ts_free(scap);
    ts_free(scur);
    return 0;
}

/* Kahn 拓扑排序 + 层级；检测循环并收集循环成员。 */
static int kahn(SchedCtx *ctx, char *err, size_t err_sz)
{
    size_t n = ctx->n;
    size_t *indeg = (size_t *)ts_calloc(n, sizeof(size_t));
    size_t *q = (size_t *)ts_malloc(n * sizeof(size_t));
    size_t qh = 0, qt = 0, i, e;
    int mx;

    if (indeg == NULL || q == NULL) {
        ts_free(indeg); ts_free(q);
        return ctx_oom(err, err_sz);
    }
    for (i = 0; i < n; i++) indeg[i] = ctx->pred_count[i];
    for (i = 0; i < n; i++) if (indeg[i] == 0) q[qt++] = i;

    ctx->topo = (size_t *)ts_malloc(n * sizeof(size_t));
    ctx->topo_count = 0;
    if (ctx->topo == NULL) { ts_free(indeg); ts_free(q); return ctx_oom(err, err_sz); }

    while (qh < qt) {
        size_t u = q[qh++];
        ctx->topo[ctx->topo_count++] = u;
        for (e = 0; e < ctx->succ_count[u]; e++) {
            size_t v = ctx->succ[u][e];
            if (--indeg[v] == 0) q[qt++] = v;
        }
    }

    if (ctx->topo_count < n) {
        /* 剩余入度 > 0 的节点即循环成员 */
        size_t c = 0;
        ctx->cycle = (size_t *)ts_calloc(n, sizeof(size_t));
        if (ctx->cycle == NULL) {
            ts_free(indeg);
            ts_free(q);
            return ctx_oom(err, err_sz);
        }
        for (i = 0; i < n; i++) if (indeg[i] > 0) ctx->cycle[c++] = i;
        ctx->cycle_count = c;
        ts_free(indeg);
        ts_free(q);
        snprintf(err, err_sz, "检测到循环依赖（%zu 个任务）", c);
        return 1;
    }

    /* 层级：无前置 0；否则 1 + max(前置层级) */
    ctx->level = (int *)ts_calloc(n, sizeof(int));
    if (ctx->level == NULL) { ts_free(indeg); ts_free(q); return ctx_oom(err, err_sz); }
    for (i = 0; i < n; i++) {
        size_t u = ctx->topo[i];
        mx = -1;
        for (e = 0; e < ctx->pred_count[u]; e++) {
            size_t p = ctx->pred[u][e];
            if (ctx->level[p] > mx) mx = ctx->level[p];
        }
        ctx->level[u] = (mx < 0) ? 0 : (mx + 1);
    }

    ts_free(indeg);
    ts_free(q);
    return 0;
}

/*
 * 向后最长依赖边数 D 的分子（静态量，与被完成状态无关）。
 *
 * 说明：最长剩余工时链（关键链 C）不在这里算——它必须随“哪些任务已完成”变化，
 * 否则已完成的后继会把工时重新算进剩余链（审查报告 P2）。C 在 compute_scores 中
 * 依据当前 done 集合按逆拓扑实时计算。
 */
static int compute_metrics(SchedCtx *ctx, char *err, size_t err_sz)
{
    size_t n = ctx->n, i, e;

    ctx->depth = (int *)ts_calloc(n, sizeof(int));
    if (ctx->depth == NULL) {
        return ctx_oom(err, err_sz);
    }

    for (i = n; i-- > 0;) {
        size_t u = ctx->topo[i];
        int dmx = 0;
        for (e = 0; e < ctx->succ_count[u]; e++) {
            size_t v = ctx->succ[u][e];
            if (ctx->depth[v] + 1 > dmx) dmx = ctx->depth[v] + 1;
        }
        ctx->depth[u] = dmx;
    }
    return 0;
}

/*
 * 计算“剩余工时链” rem[]/rem_known[]（逆拓扑），完全依据 done 集合：
 *   - 未完成节点：rem = 自身工时 + max(后继 rem)；工时未知则整条链标记为不完整。
 *   - 已完成节点：自身不再占用工时（rem 只取后继的最大值），但仍然要沿依赖边
 *     继续往后看——已完成节点的下游可能还有未完成的工作。
 * 这样“已完成任务的工时”不会污染剩余关键链。
 */
static int compute_remaining_chain(const SchedCtx *ctx, const int *done,
                                   double **out_rem, int **out_known,
                                   char *err, size_t err_sz)
{
    size_t n = ctx->n, i, e;
    const TsPlan *plan = ctx->plan;
    double *rem = (double *)ts_calloc(n, sizeof(double));
    int *known = (int *)ts_calloc(n, sizeof(int));

    if (rem == NULL || known == NULL) {
        ts_free(rem);
        ts_free(known);
        ctx_oom(err, err_sz);
        return 1;
    }

    for (i = n; i-- > 0;) {
        size_t u = ctx->topo[i];
        double mx = 0.0;
        int all_known = 1;

        for (e = 0; e < ctx->succ_count[u]; e++) {
            size_t v = ctx->succ[u][e];
            if (!known[v]) all_known = 0;
            else if (rem[v] > mx) mx = rem[v];
        }

        if (done[u]) {
            rem[u] = mx;
            known[u] = all_known;
        } else if (!plan->tasks[u].has_estimated_hours) {
            rem[u] = 0.0;
            known[u] = 0;       /* 链上有未知工时：不提供确定的关键链加分 */
        } else {
            rem[u] = plan->tasks[u].estimated_hours + mx;
            known[u] = all_known;
        }
    }

    *out_rem = rem;
    *out_known = known;
    return 0;
}

/* 传递闭包（严格后代）。 */
static int compute_reach(SchedCtx *ctx, char *err, size_t err_sz)
{
    size_t n = ctx->n, i;
    ctx->reach = (unsigned char **)ts_calloc(n, sizeof(unsigned char *));
    if (ctx->reach == NULL) return ctx_oom(err, err_sz);

    for (i = 0; i < n; i++) {
        unsigned char *vis = (unsigned char *)ts_calloc(n, 1);
        size_t *q = (size_t *)ts_malloc(n * sizeof(size_t));
        size_t h = 0, t = 0, e;

        ctx->reach[i] = (unsigned char *)ts_calloc(n, 1);
        if (vis == NULL || q == NULL || ctx->reach[i] == NULL) {
            ts_free(vis); ts_free(q);
            return ctx_oom(err, err_sz);
        }
        vis[i] = 1;
        for (e = 0; e < ctx->succ_count[i]; e++) {
            size_t v = ctx->succ[i][e];
            if (!vis[v]) { vis[v] = 1; ctx->reach[i][v] = 1; q[t++] = v; }
        }
        while (h < t) {
            size_t u = q[h++];
            for (e = 0; e < ctx->succ_count[u]; e++) {
                size_t v = ctx->succ[u][e];
                if (!vis[v]) { vis[v] = 1; ctx->reach[i][v] = 1; q[t++] = v; }
            }
        }
        ts_free(vis);
        ts_free(q);
    }
    return 0;
}

static int compute_ext_status(SchedCtx *ctx)
{
    size_t i;
    ctx->ext_status = (int *)ts_malloc(ctx->n * sizeof(int));
    if (ctx->ext_status == NULL) return 1;
    for (i = 0; i < ctx->n; i++) ctx->ext_status[i] = ext_status_of(&ctx->plan->tasks[i]);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 评分                                                                */
/* ------------------------------------------------------------------ */

static int compute_scores(const SchedCtx *ctx, const TsConfig *cfg, const int *done,
                          const size_t *cands, size_t cand_count,
                          TsScoreBreakdown *out, char *err, size_t err_sz)
{
    size_t n = ctx->n, a, b, k;
    const TsPlan *plan = ctx->plan;
    size_t *cnt = NULL;
    size_t *un = NULL;
    double *rem = NULL;
    int *rem_known = NULL;
    int rc = 1;

    /* 五维中的静态项与 Q */
    for (a = 0; a < cand_count; a++) {
        size_t t = cands[a];
        const TsTask *task = &plan->tasks[t];
        TsScoreBreakdown *sc = &out[a];
        memset(sc, 0, sizeof(*sc));
        sc->u = (task->urgency - 1) / 4.0;
        sc->i = (task->impact - 1) / 4.0;
        if (task->has_estimated_hours) {
            sc->q = cfg->reference_hours / (cfg->reference_hours + task->estimated_hours);
            sc->hours_unknown = 0;
        } else {
            sc->q = 0.5;
            sc->hours_unknown = 1;
        }
    }

    /* B：去重未完成后代数 */
    cnt = (size_t *)ts_calloc(cand_count ? cand_count : 1, sizeof(size_t));
    if (cnt == NULL) goto oom;
    {
        size_t max_desc = 0;
        for (a = 0; a < cand_count; a++) {
            size_t t = cands[a];
            for (b = 0; b < n; b++) if (ctx->reach[t][b] && !done[b]) cnt[a]++;
            if (cnt[a] > max_desc) max_desc = cnt[a];
        }
        for (a = 0; a < cand_count; a++) {
            out[a].b = max_desc ? ((double)cnt[a] / (double)max_desc) : 0.0;
        }
    }

    /* D：向后最长依赖边数 */
    {
        int max_depth = 0;
        for (a = 0; a < cand_count; a++) {
            if (ctx->depth[cands[a]] > max_depth) max_depth = ctx->depth[cands[a]];
        }
        for (a = 0; a < cand_count; a++) {
            out[a].d = max_depth ? ((double)ctx->depth[cands[a]] / (double)max_depth) : 0.0;
        }
    }

    /*
     * C：关键链推进 —— 用“实际未完成”的剩余工时链（已完成任务不计自身工时），
     * 按全体未完成且链完整者的最大值归一化。
     */
    if (compute_remaining_chain(ctx, done, &rem, &rem_known, err, err_sz) != 0) {
        goto done;   /* err 已写好 */
    }
    {
        double max_rem = 0.0;
        for (b = 0; b < n; b++) {
            if (!done[b] && rem_known[b] && rem[b] > max_rem) max_rem = rem[b];
        }
        for (a = 0; a < cand_count; a++) {
            size_t t = cands[a];
            if (!rem_known[t]) {
                out[a].c = 0.0;
                out[a].chain_incomplete = 1;  /* 链上有未知工时：不给确定加分 */
            } else {
                out[a].c = (max_rem > 0.0) ? (rem[t] / max_rem) : 0.0;
            }
        }
    }

    /* R：立即解锁数量 */
    un = (size_t *)ts_calloc(cand_count ? cand_count : 1, sizeof(size_t));
    if (un == NULL) goto oom;
    {
        size_t max_unlock = 0;
        for (a = 0; a < cand_count; a++) {
            size_t t = cands[a];
            size_t e;
            for (e = 0; e < ctx->succ_count[t]; e++) {
                size_t sv = ctx->succ[t][e];
                int ready = 1;
                if (done[sv]) continue;
                if (ctx->ext_status[sv] != 0) continue;
                for (k = 0; k < ctx->pred_count[sv]; k++) {
                    size_t p = ctx->pred[sv][k];
                    if (p != t && !done[p]) { ready = 0; break; }
                }
                if (ready) un[a]++;
            }
            if (un[a] > max_unlock) max_unlock = un[a];
        }
        for (a = 0; a < cand_count; a++) {
            out[a].r = max_unlock ? ((double)un[a] / (double)max_unlock) : 0.0;
        }
    }

    /* 汇总：FinalScore = BaseScore + 10C + 7R + 3W */
    for (a = 0; a < cand_count; a++) {
        TsScoreBreakdown *sc = &out[a];
        sc->w = sc->i * sc->q;
        sc->base = 100.0 * (cfg->w_urgency * sc->u + cfg->w_impact * sc->i +
                            cfg->w_blocking * sc->b + cfg->w_quick_win * sc->q +
                            cfg->w_depth * sc->d);
        sc->final = sc->base + 10.0 * sc->c + 7.0 * sc->r + 3.0 * sc->w;
    }

    rc = 0;
    goto done;

oom:
    ctx_oom(err, err_sz);
done:
    ts_free(cnt);
    ts_free(un);
    ts_free(rem);
    ts_free(rem_known);
    return rc;
}

/* 返回 1 表示 a 优先于 b（同分：紧迫性 -> 影响力 -> 稳定 ID 升序）。 */
static int better(const SchedCtx *ctx, const size_t *cands,
                  const TsScoreBreakdown *sc, size_t a, size_t b)
{
    const TsTask *ta = &ctx->plan->tasks[cands[a]];
    const TsTask *tb = &ctx->plan->tasks[cands[b]];
    if (sc[a].final > sc[b].final + 1e-12) return 1;
    if (sc[b].final > sc[a].final + 1e-12) return 0;
    if (ta->urgency != tb->urgency) return ta->urgency > tb->urgency;
    if (ta->impact != tb->impact) return ta->impact > tb->impact;
    return strcmp(ta->id, tb->id) < 0;
}

/* ------------------------------------------------------------------ */
/* 字符串向量                                                          */
/* ------------------------------------------------------------------ */

static int strvec_add(char ***vec, size_t *count, const char *s, char *err, size_t err_sz)
{
    size_t newc = *count + 1;
    size_t bytes;
    char **nv;
    char *copy = ts_strdup(s);
    if (copy == NULL) return ctx_oom(err, err_sz);
    if (ts_mul_overflow(newc, sizeof(char *), &bytes)) {
        ts_free(copy);
        return ctx_oom(err, err_sz);
    }
    nv = (char **)ts_realloc(*vec, bytes);
    if (nv == NULL) {
        ts_free(copy);
        return ctx_oom(err, err_sz);
    }
    *vec = nv;
    (*vec)[*count] = copy;
    *count = newc;
    return 0;
}

static void strvec_free(char **v, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++) ts_free(v[i]);
    ts_free(v);
}

/* ------------------------------------------------------------------ */
/* 解释文本                                                            */
/* ------------------------------------------------------------------ */

/*
 * 生成可复算的解释。
 *
 * 重要：基础分是【加权和】，因此必须把权重与乘积累写出来，不能写成
 * “100×(U + I + B + Q + D)”——那样用户按理由复算会和最终得分对不上（审查报告 P2）。
 */
static void build_reason(const TsConfig *cfg, const TsScoreBreakdown *sc,
                         const TsScheduleStep *st, char *buf, size_t sz)
{
    size_t i;
    int pos = 0;
    pos += snprintf(buf + pos, sz - (size_t)pos,
                    "基础分 %.2f = 100×(%.2f×U%.3f + %.2f×I%.3f + %.2f×B%.3f "
                    "+ %.2f×Q%.3f + %.2f×D%.3f)",
                    sc->base,
                    cfg->w_urgency, sc->u, cfg->w_impact, sc->i, cfg->w_blocking, sc->b,
                    cfg->w_quick_win, sc->q, cfg->w_depth, sc->d);
    if (pos < 0 || (size_t)pos >= sz) return;
    pos += snprintf(buf + pos, sz - (size_t)pos,
                    "；全局加分 %.2f = 10×C(%.3f) + 7×R(%.3f) + 3×W(%.3f)；"
                    "最终 %.2f = 基础分 + 全局加分",
                    10.0 * sc->c + 7.0 * sc->r + 3.0 * sc->w,
                    sc->c, sc->r, sc->w, sc->final);
    if (pos < 0 || (size_t)pos >= sz) return;
    if (sc->hours_unknown) {
        pos += snprintf(buf + pos, sz - (size_t)pos, "（工时待确认）");
        if (pos < 0 || (size_t)pos >= sz) return;
    }
    if (sc->chain_incomplete) {
        pos += snprintf(buf + pos, sz - (size_t)pos, "（关键链估计不完整）");
        if (pos < 0 || (size_t)pos >= sz) return;
    }
    if (st->unlocked_count > 0) {
        pos += snprintf(buf + pos, sz - (size_t)pos, "；完成后解锁：");
        if (pos < 0 || (size_t)pos >= sz) return;
        for (i = 0; i < st->unlocked_count; i++) {
            pos += snprintf(buf + pos, sz - (size_t)pos, "%s%s",
                            i ? "、" : "", st->unlocked[i]);
            if (pos < 0 || (size_t)pos >= sz) return;
        }
    }
    if (st->still_waiting_count > 0) {
        pos += snprintf(buf + pos, sz - (size_t)pos, "；仍待其它前置：");
        if (pos < 0 || (size_t)pos >= sz) return;
        for (i = 0; i < st->still_waiting_count; i++) {
            pos += snprintf(buf + pos, sz - (size_t)pos, "%s%s",
                            i ? "、" : "", st->still_waiting[i]);
            if (pos < 0 || (size_t)pos >= sz) return;
        }
    }
}

/* ------------------------------------------------------------------ */
/* 主流程                                                              */
/* ------------------------------------------------------------------ */

static int compute_unlocked(const SchedCtx *ctx, const int *done, size_t t,
                            char ***unlocked, size_t *unlocked_count,
                            char ***waiting, size_t *waiting_count,
                            char *err, size_t err_sz)
{
    size_t e, k;
    *unlocked = NULL; *unlocked_count = 0;
    *waiting = NULL; *waiting_count = 0;
    for (e = 0; e < ctx->succ_count[t]; e++) {
        size_t s = ctx->succ[t][e];
        const TsTask *st = &ctx->plan->tasks[s];
        int ready;
        if (done[s]) continue;
        if (ctx->ext_status[s] != 0) {
            if (strvec_add(waiting, waiting_count, st->id, err, err_sz)) return 1;
            continue;
        }
        ready = 1;
        for (k = 0; k < ctx->pred_count[s]; k++) {
            size_t p = ctx->pred[s][k];
            if (p != t && !done[p]) { ready = 0; break; }
        }
        if (ready) {
            if (strvec_add(unlocked, unlocked_count, st->id, err, err_sz)) return 1;
        } else {
            if (strvec_add(waiting, waiting_count, st->id, err, err_sz)) return 1;
        }
    }
    return 0;
}

int ts_schedule_build(const TsPlan *plan, const TsConfig *cfg,
                      TsScheduleResult *out, char *err, size_t err_sz)
{
    SchedCtx ctx;
    int *done = NULL;
    size_t *cands = NULL;
    size_t remaining = 0, i, a;
    int rc = 1;

    memset(out, 0, sizeof(*out));

    if (plan == NULL || cfg == NULL || plan->task_count == 0) {
        snprintf(err, err_sz, "计划为空，无法生成顺序");
        return 1;
    }

    if (build_graph(&ctx, plan, err, err_sz) != 0) goto done;
    if (kahn(&ctx, err, err_sz) != 0) goto done;
    if (compute_metrics(&ctx, err, err_sz) != 0) goto done;
    if (compute_reach(&ctx, err, err_sz) != 0) goto done;
    if (compute_ext_status(&ctx) != 0) { ctx_oom(err, err_sz); goto done; }

    done = (int *)ts_calloc(ctx.n, sizeof(int));
    cands = (size_t *)ts_malloc(ctx.n * sizeof(size_t));
    if (done == NULL || cands == NULL) { ctx_oom(err, err_sz); goto done; }

    for (i = 0; i < ctx.n; i++) {
        done[i] = (plan->tasks[i].actual_status == TS_ACTUAL_DONE);
        if (!done[i]) remaining++;
    }

    /* 静态受阻/待确认清单（外部条件，与模拟无关） */
    for (i = 0; i < ctx.n; i++) {
        if (done[i]) continue;
        if (ctx.ext_status[i] == 1) {
            if (strvec_add(&out->blocked_ids, &out->blocked_count,
                           plan->tasks[i].id, err, err_sz)) goto done;
        } else if (ctx.ext_status[i] == 2) {
            if (strvec_add(&out->pending_ids, &out->pending_count,
                           plan->tasks[i].id, err, err_sz)) goto done;
        }
    }

    /* 带优先级拓扑调度 */
    while (remaining > 0) {
        size_t cand_count = 0;
        size_t best = 0;
        TsScoreBreakdown *scores = NULL;
        TsScheduleStep step;
        size_t steps_new;

        memset(&step, 0, sizeof(step));

        for (i = 0; i < ctx.n; i++) {
            size_t k;
            int rd;
            if (done[i]) continue;
            if (ctx.ext_status[i] != 0) continue; /* 受阻/待确认永不是候选 */
            rd = 1;
            for (k = 0; k < ctx.pred_count[i]; k++) {
                if (!done[ctx.pred[i][k]]) { rd = 0; break; }
            }
            if (rd) cands[cand_count++] = i;
        }

        if (cand_count == 0) {
            out->unresolvable_reason = ts_strdup(
                "没有可立即执行的任务：所有剩余任务均受阻/待确认，或依赖受阻/待确认的前置任务");
            if (out->unresolvable_reason == NULL) { ctx_oom(err, err_sz); goto done; }
            break;
        }

        scores = (TsScoreBreakdown *)ts_calloc(cand_count, sizeof(TsScoreBreakdown));
        if (scores == NULL) { ctx_oom(err, err_sz); goto done; }
        if (compute_scores(&ctx, cfg, done, cands, cand_count, scores,
                           err, err_sz) != 0) {
            ts_free(scores);
            goto done;   /* err 已写好 */
        }

        best = 0;
        for (a = 1; a < cand_count; a++) {
            if (better(&ctx, cands, scores, a, best)) best = a;
        }

        step.task_id = ts_strdup(plan->tasks[cands[best]].id);
        if (step.task_id == NULL) { ts_free(scores); ctx_oom(err, err_sz); goto done; }
        step.task_index = cands[best];
        step.score = scores[best];

        /* 候选快照 */
        for (a = 0; a < cand_count; a++) {
            if (strvec_add(&step.candidates, &step.candidate_count,
                           plan->tasks[cands[a]].id, err, err_sz)) {
                ts_free(scores);
                ts_free(step.task_id);
                strvec_free(step.candidates, step.candidate_count);
                goto done;
            }
        }
        /* 解锁 / 仍等待 */
        if (compute_unlocked(&ctx, done, cands[best],
                             &step.unlocked, &step.unlocked_count,
                             &step.still_waiting, &step.still_waiting_count,
                             err, err_sz)) {
            ts_free(scores);
            ts_free(step.task_id);
            strvec_free(step.candidates, step.candidate_count);
            strvec_free(step.unlocked, step.unlocked_count);
            strvec_free(step.still_waiting, step.still_waiting_count);
            goto done;
        }
        /* 解释 */
        step.reason = (char *)ts_malloc(2048);
        if (step.reason == NULL) {
            ts_free(scores);
            ts_free(step.task_id);
            strvec_free(step.candidates, step.candidate_count);
            strvec_free(step.unlocked, step.unlocked_count);
            strvec_free(step.still_waiting, step.still_waiting_count);
            ctx_oom(err, err_sz);
            goto done;
        }
        build_reason(cfg, &step.score, &step, step.reason, 2048);

        /* 追加步骤 */
        steps_new = out->step_count + 1;
        {
            size_t bytes;
            TsScheduleStep *ns;
            if (ts_mul_overflow(steps_new, sizeof(TsScheduleStep), &bytes)) {
                ts_free(scores);
                ts_free(step.task_id);
                ts_free(step.reason);
                strvec_free(step.candidates, step.candidate_count);
                strvec_free(step.unlocked, step.unlocked_count);
                strvec_free(step.still_waiting, step.still_waiting_count);
                ctx_oom(err, err_sz);
                goto done;
            }
            ns = (TsScheduleStep *)ts_realloc(out->steps, bytes);
            if (ns == NULL) {
                ts_free(scores);
                ts_free(step.task_id);
                ts_free(step.reason);
                strvec_free(step.candidates, step.candidate_count);
                strvec_free(step.unlocked, step.unlocked_count);
                strvec_free(step.still_waiting, step.still_waiting_count);
                ctx_oom(err, err_sz);
                goto done;
            }
            out->steps = ns;
            out->steps[out->step_count] = step;
            out->step_count = steps_new;
        }

        ts_free(scores);
        done[cands[best]] = 1;
        remaining--;
    }

    /* 受影响任务：受阻/待确认任务的下游（排除自身已受阻/待确认/已完成） */
    for (i = 0; i < ctx.n; i++) {
        size_t s;
        if (done[i]) continue;
        if (ctx.ext_status[i] == 0) {
            /* 仅当它是某个受阻/待确认任务的后代 */
            for (s = 0; s < ctx.n; s++) {
                if (done[s]) continue;
                if (ctx.ext_status[s] == 0) continue;
                if (ctx.reach[s][i]) {
                    strvec_add(&out->affected_ids, &out->affected_count,
                               plan->tasks[i].id, err, err_sz);
                    break;
                }
            }
        }
    }

    ts_clock_wall_iso(out->sorted_at, sizeof(out->sorted_at));
    rc = 0;
done:
    ts_free(done);
    ts_free(cands);
    ctx_free(&ctx);
    if (rc != 0) {
        /* 调用方仍可 ts_schedule_result_free 清理已分配的部分 */
        return 1;
    }
    return 0;
}

void ts_schedule_result_free(TsScheduleResult *r)
{
    size_t i;
    if (r == NULL) return;
    for (i = 0; i < r->step_count; i++) {
        ts_free(r->steps[i].task_id);
        strvec_free(r->steps[i].candidates, r->steps[i].candidate_count);
        strvec_free(r->steps[i].unlocked, r->steps[i].unlocked_count);
        strvec_free(r->steps[i].still_waiting, r->steps[i].still_waiting_count);
        ts_free(r->steps[i].reason);
    }
    ts_free(r->steps);
    strvec_free(r->blocked_ids, r->blocked_count);
    strvec_free(r->pending_ids, r->pending_count);
    strvec_free(r->affected_ids, r->affected_count);
    ts_free(r->unresolvable_reason);
    memset(r, 0, sizeof(*r));
}

/* ------------------------------------------------------------------ */
/* 当前就绪状态                                                        */
/* ------------------------------------------------------------------ */

int ts_schedule_status(const TsPlan *plan, TsStatusView *out, char *err, size_t err_sz)
{
    SchedCtx ctx;
    size_t i, k, s;
    int rc = 1;

    memset(out, 0, sizeof(*out));

    if (plan == NULL || plan->task_count == 0) {
        snprintf(err, err_sz, "计划为空");
        return 1;
    }
    if (build_graph(&ctx, plan, err, err_sz) != 0) goto done;
    if (kahn(&ctx, err, err_sz) != 0) {
        /* 循环：循环成员标受阻，其余正常计算；不直接失败 */
    }
    if (compute_reach(&ctx, err, err_sz) != 0) goto done;
    if (compute_ext_status(&ctx) != 0) { ctx_oom(err, err_sz); goto done; }

    out->states = (TsReadyState *)ts_calloc(ctx.n, sizeof(TsReadyState));
    out->affected = (int *)ts_calloc(ctx.n, sizeof(int));
    out->level = (int *)ts_calloc(ctx.n, sizeof(int));
    if (out->states == NULL || out->affected == NULL || out->level == NULL) {
        ctx_oom(err, err_sz);
        goto done;
    }
    for (i = 0; i < ctx.n; i++) {
        out->level[i] = (ctx.level != NULL) ? ctx.level[i] : -1;
    }

    for (i = 0; i < ctx.n; i++) {
        const TsTask *t = &plan->tasks[i];
        if (t->actual_status == TS_ACTUAL_DONE) {
            out->states[i] = TS_DONE;
            continue;
        }
        if (ctx.ext_status[i] == 1) { out->states[i] = TS_BLOCKED; continue; }
        if (ctx.ext_status[i] == 2) { out->states[i] = TS_PENDING_CONFIRM; continue; }
        {
            int rd = 1;
            for (k = 0; k < ctx.pred_count[i]; k++) {
                size_t p = ctx.pred[i][k];
                if (plan->tasks[p].actual_status != TS_ACTUAL_DONE) { rd = 0; break; }
            }
            out->states[i] = rd ? TS_READY : TS_WAITING_DEP;
        }
    }

    /* 循环成员标记为受阻 */
    for (i = 0; i < ctx.cycle_count; i++) {
        size_t c = ctx.cycle[i];
        if (plan->tasks[c].actual_status != TS_ACTUAL_DONE) {
            out->states[c] = TS_BLOCKED;
        }
    }
    /* 循环成员 ID */
    for (i = 0; i < ctx.cycle_count; i++) {
        if (strvec_add(&out->cycle_ids, &out->cycle_count,
                       plan->tasks[ctx.cycle[i]].id, err, err_sz)) goto done;
    }

    /* 受影响标记：受阻/待确认任务的后代（排除自身已受阻/待确认/已完成） */
    for (i = 0; i < ctx.n; i++) {
        if (plan->tasks[i].actual_status == TS_ACTUAL_DONE) continue;
        if (ctx.ext_status[i] != 0) continue;
        for (s = 0; s < ctx.n; s++) {
            if (plan->tasks[s].actual_status == TS_ACTUAL_DONE) continue;
            if (ctx.ext_status[s] == 0) continue;
            if (ctx.reach[s][i]) { out->affected[i] = 1; break; }
        }
    }

    rc = 0;
done:
    ctx_free(&ctx);
    if (rc != 0) {
        ts_status_view_free(out);
        return 1;
    }
    return 0;
}

void ts_status_view_free(TsStatusView *v)
{
    if (v == NULL) return;
    ts_free(v->states);
    ts_free(v->affected);
    ts_free(v->level);
    strvec_free(v->cycle_ids, v->cycle_count);
    memset(v, 0, sizeof(*v));
}

