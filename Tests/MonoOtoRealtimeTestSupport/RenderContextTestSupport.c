#define _POSIX_C_SOURCE 200809L
#include "RenderContext.h"
#include "FrameQueueTestSupport.h"
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Compile exactly the production context algorithm with renamed symbols and
 * deterministic test-only hooks. The product target never defines this macro. */
#define mo_render_context_create mo_barrier_context_create
#define mo_render_context_destroy mo_barrier_context_destroy
#define mo_render_context_set_hold mo_barrier_context_set_hold
#define mo_render_context_render mo_barrier_context_render
#define mo_render_context_read_stats mo_barrier_context_read_stats
#define MO_RENDER_CONTEXT_TESTING 1
#include "../../Sources/MonoOtoRealtime/RenderContext.c"
#undef MO_RENDER_CONTEXT_TESTING
#undef mo_render_context_create
#undef mo_render_context_destroy
#undef mo_render_context_set_hold
#undef mo_render_context_render
#undef mo_render_context_read_stats

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    MORenderContext *context;
    AudioBufferList *buffers;
    unsigned phase;
    bool reached, proceed, timed_out, silent;
    MORenderResult result;
} RenderBarrier;
/* The mutex serializes harness invocations, not product callback work. */
static pthread_mutex_t harness_mutex = PTHREAD_MUTEX_INITIALIZER;
static RenderBarrier *current_barrier;
static struct timespec render_deadline(void) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;
    return deadline;
}
void mo_render_context_test_hook(MORenderContext *context, unsigned phase) {
    RenderBarrier *b = current_barrier;
    if (!b || context != b->context || phase != b->phase) return;
    struct timespec deadline = render_deadline();
    pthread_mutex_lock(&b->mutex);
    b->reached = true;
    pthread_cond_broadcast(&b->condition);
    while (!b->proceed) {
        if (pthread_cond_timedwait(&b->condition, &b->mutex, &deadline)) {
            b->timed_out = true;
            break;
        }
    }
    pthread_mutex_unlock(&b->mutex);
}
static void *render_at_barrier(void *arg) {
    RenderBarrier *b = arg;
    b->result = mo_barrier_context_render(b->context, b->buffers, 2, &b->silent);
    return NULL;
}
static int run_render_barrier(unsigned phase, bool stop) {
    int failure = 0;
    MOFrameQueue *q = mo_queue_create(4, 0);
    if (!q) return 201;
    MORenderContext *c = mo_barrier_context_create(q);
    if (!c) { mo_queue_destroy(q); return 202; }
    AudioBufferList *abl = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    if (!abl) { mo_barrier_context_destroy(c); mo_queue_destroy(q); return 203; }
    float left[] = {9,9,9}, right[] = {9,9,9}, input[] = {0.1f,0.2f};
    abl->mNumberBuffers = 2;
    abl->mBuffers[0] = (AudioBuffer){1, sizeof(left), left};
    abl->mBuffers[1] = (AudioBuffer){1, sizeof(right), right};
    RenderBarrier b = {.context=c, .buffers=abl, .phase=phase};
    if (mo_queue_push(q, input, 2) != 2 || !mo_barrier_context_set_hold(c, false)) failure = 204;
    if (pthread_mutex_init(&b.mutex, NULL)) { failure = 205; goto cleanup_storage; }
    if (pthread_cond_init(&b.condition, NULL)) { failure = 206; goto cleanup_mutex; }
    if (failure) goto cleanup_condition;
    current_barrier = &b;
    pthread_t worker;
    if (pthread_create(&worker, NULL, render_at_barrier, &b)) {
        failure = 207; current_barrier = NULL; goto cleanup_condition;
    }
    struct timespec deadline = render_deadline();
    pthread_mutex_lock(&b.mutex);
    while (!b.reached) {
        if (pthread_cond_timedwait(&b.condition, &b.mutex, &deadline)) {
            b.timed_out = true; break;
        }
    }
    /* The worker is inside the actual C render with active=1; no polling race
     * or assumed scheduler delay establishes this ordering. */
    MORenderContextStats entered = mo_barrier_context_read_stats(c);
    if (entered.active_callbacks != 1 || entered.entries != 1 || entered.exits != 0) failure = 208;
    if (!mo_barrier_context_set_hold(c, true)) failure = 209;
    if (stop) mo_queue_silence(q);
    /* Even an observed hold/silence is not a join. Keep every resource alive. */
    if (mo_barrier_context_read_stats(c).active_callbacks != 1) failure = 210;
    b.proceed = true;
    pthread_cond_broadcast(&b.condition);
    pthread_mutex_unlock(&b.mutex);
    pthread_join(worker, NULL);
    current_barrier = NULL;
    if (b.timed_out) failure = 211;
    MORenderContextStats exited = mo_barrier_context_read_stats(c);
    MOQueueStats stats = mo_queue_read_stats(q);
    if (exited.active_callbacks || exited.entries != 1 || exited.exits != 1) failure = 212;
    if (phase == 1 && (b.result != MO_RENDER_SILENCED || !b.silent ||
                      left[0] != 0 || left[1] != 0 || stats.rendered_frames != 0)) failure = 213;
    /* A call already returned from queue's final gate remains original PCM and
     * counted exactly once, even when hold/stop arrives before context exit. */
    if (phase == 2 && (b.result != MO_RENDER_OK || b.silent ||
                      memcmp(left,input,sizeof(input)) || stats.rendered_frames != 2)) failure = 214;
    if (right[0] != 0 || right[1] != 0 || left[2] != 9 || right[2] != 9) failure = 215;
    bool silent = false;
    if (mo_barrier_context_render(c, abl, 2, &silent) != MO_RENDER_SILENCED ||
        !silent || left[0] != 0 || left[1] != 0 || right[0] != 0 || right[1] != 0 ||
        mo_queue_read_stats(q).rendered_frames != stats.rendered_frames) failure = 216;
    if (stop && mo_barrier_context_set_hold(c, false)) failure = 217;
    if (!stop) {
        if (!mo_barrier_context_set_hold(c, false)) failure = 218;
        MORenderResult resumed = mo_barrier_context_render(c, abl, 2, &silent);
        if (phase == 1 && (resumed != MO_RENDER_OK || memcmp(left,input,sizeof(input)))) failure = 219;
        if (phase == 2 && (resumed != MO_RENDER_UNDERRUN || !silent)) failure = 220;
        if (mo_queue_read_stats(q).rendered_frames != 2) failure = 221;
    }
cleanup_condition:
    pthread_cond_destroy(&b.condition);
cleanup_mutex:
    pthread_mutex_destroy(&b.mutex);
cleanup_storage:
    /* The successful pthread_join above precedes context, queue and ABL destroy. */
    free(abl); mo_barrier_context_destroy(c); mo_queue_destroy(q);
    return failure;
}
int mo_test_render_context_barriers(unsigned phase) {
    if (phase != 1 && phase != 2) return 200;
    pthread_mutex_lock(&harness_mutex);
    int result = run_render_barrier(phase, false);
    if (!result) result = run_render_barrier(phase, true);
    pthread_mutex_unlock(&harness_mutex);
    return result;
}
