#define _POSIX_C_SOURCE 200809L
#include "FrameQueue.h"
#include "FrameQueueTestSupport.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <errno.h>
#include <math.h>

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
static void sleep_ns(uint64_t ns) {
    struct timespec t = {(time_t)(ns / 1000000000), (long)(ns % 1000000000)};
    while (nanosleep(&t, &t) && errno == EINTR) {}
}
static uint32_t random_next(uint32_t *state) {
    *state = *state * 1664525u + 1013904223u;
    return *state;
}
/* An injective 23-bit pattern over the million-frame trial; never zero. */
static float sample_at(uint64_t position) {
    uint32_t bits = 0x3e800000u | (((uint32_t)position * 2654435761u) & 0x007fffffu);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

typedef struct {
    MOFrameQueue *queue;
    uint64_t limit, deadline, producer_start;
    unsigned ear;
    bool lifecycle;
    _Atomic uint32_t producer_calls, consumer_calls, observer_calls;
    _Atomic bool stop, producer_done, consumer_done;
    _Atomic int failed;
    uint64_t consumed; /* consumer-owned, read after join */
} Trial;

static void *produce(void *context) {
    Trial *t = context;
    uint64_t position = t->producer_start;
    uint32_t seed = 0x451023u;
    float input[1024];
    while (position < t->limit && !atomic_load(&t->stop)) {
        uint32_t count = 1 + random_next(&seed) % 1024;
        if (count > t->limit - position) count = (uint32_t)(t->limit - position);
        for (uint32_t i = 0; i < count; ++i) input[i] = sample_at(position + i);
        uint32_t offset = 0;
        while (offset < count && !atomic_load(&t->stop)) {
            uint32_t n = mo_queue_push(t->queue, input + offset, count - offset);
            atomic_fetch_add(&t->producer_calls, 1);
            offset += n;
            if (!n) {
                if (now_ns() > t->deadline) { atomic_store(&t->failed, 1); atomic_store(&t->stop, true); break; }
                sleep_ns(1000);
            }
        }
        position += offset;
    }
    atomic_store(&t->producer_done, true);
    return NULL;
}
static int check_output(const float *left, const float *right, uint32_t count,
                        unsigned ear, uint64_t *position) {
    bool tail = false;
    for (uint32_t i = 0; i < count; ++i) {
        float selected = ear ? right[i] : left[i];
        if ((ear ? left[i] : right[i]) != 0) return 1;
        if (selected == 0) { tail = true; continue; }
        if (tail || selected != sample_at(*position)) return 1;
        ++*position;
    }
    return 0;
}
static void *consume(void *context) {
    Trial *t = context;
    float left[1025], right[1025];
    uint32_t seed = 0x789abc;
    while (t->consumed < t->limit && !atomic_load(&t->stop)) {
        uint32_t count = 1 + random_next(&seed) % 1024;
        left[count] = right[count] = 9;
        MORenderResult result = mo_queue_render(t->queue,
            (MOFloatBuffer){left, 1025}, (MOFloatBuffer){right, 1025}, count);
        atomic_fetch_add(&t->consumer_calls, 1);
        if (result == MO_RENDER_FAULT || (!t->lifecycle && result == MO_RENDER_SILENCED) || check_output(left, right, count, t->ear, &t->consumed) ||
            left[count] != 9 || right[count] != 9) {
            atomic_store(&t->failed, 2); atomic_store(&t->stop, true); break;
        }
        if (now_ns() > t->deadline) { atomic_store(&t->failed, 3); atomic_store(&t->stop, true); break; }
        if (result == MO_RENDER_UNDERRUN) sleep_ns(1000);
    }
    atomic_store(&t->consumer_done, true);
    return NULL;
}
static void *observe(void *context) {
    Trial *t = context;
    while (!atomic_load(&t->stop) && !atomic_load(&t->consumer_done)) {
        MOQueueStats stats = mo_queue_read_stats(t->queue);
        atomic_fetch_add(&t->observer_calls, 1);
        if (stats.high_water_frames > 4096 || stats.faulted || stats.invalid_samples || stats.invalid_buffers) {
            atomic_store(&t->failed, 4); atomic_store(&t->stop, true);
        }
        if (now_ns() > t->deadline) { atomic_store(&t->failed, 5); atomic_store(&t->stop, true); }
        sleep_ns(10000);
    }
    return NULL;
}
static int start_trial(Trial *t, bool lifecycle) {
    pthread_t producer, consumer, observer;
    if (pthread_create(&producer, NULL, produce, t)) return 10;
    if (pthread_create(&consumer, NULL, consume, t)) {
        atomic_store(&t->stop, true); pthread_join(producer, NULL); return 11;
    }
    if (pthread_create(&observer, NULL, observe, t)) {
        atomic_store(&t->stop, true); pthread_join(producer, NULL); pthread_join(consumer, NULL); return 12;
    }
    if (lifecycle) {
        while (!atomic_load(&t->producer_calls) || !atomic_load(&t->consumer_calls) || !atomic_load(&t->observer_calls)) {
            if (atomic_load(&t->stop) || now_ns() > t->deadline) {
                atomic_store(&t->failed, 13); break;
            }
            sleep_ns(1000);
        }
        mo_queue_silence(t->queue);
        atomic_store(&t->stop, true);
    }
    pthread_join(producer, NULL);
    pthread_join(consumer, NULL);
    pthread_join(observer, NULL);
    return atomic_load(&t->failed);
}
int mo_test_concurrent_order(void) {
    for (unsigned ear = 0; ear < 2; ++ear) {
        Trial t = {.queue = mo_queue_create(4096, ear), .limit = 1100000,
                   .deadline = now_ns() + UINT64_C(30000000000), .ear = ear};
        atomic_init(&t.producer_calls, 0); atomic_init(&t.consumer_calls, 0); atomic_init(&t.observer_calls, 0);
        atomic_init(&t.stop, false); atomic_init(&t.producer_done, false);
        atomic_init(&t.consumer_done, false); atomic_init(&t.failed, 0);
        if (!t.queue) return 20;
        int result = start_trial(&t, false);
        MOQueueStats stats = mo_queue_read_stats(t.queue);
        if (!result && (t.consumed != t.limit || stats.rendered_frames != t.limit || stats.high_water_frames > 4096)) result = 21;
        mo_queue_destroy(t.queue);
        if (result) return result;
    }
    return 0;
}
int mo_test_lifecycle(void) {
    for (unsigned cycle = 0; cycle < 1000; ++cycle) {
        Trial t = {.queue = mo_queue_create(4096, cycle % 2), .limit = UINT64_MAX, .producer_start = 32, .lifecycle = true,
                   .deadline = now_ns() + UINT64_C(5000000000), .ear = cycle % 2};
        atomic_init(&t.producer_calls, 0); atomic_init(&t.consumer_calls, 0); atomic_init(&t.observer_calls, 0);
        atomic_init(&t.stop, false); atomic_init(&t.producer_done, false);
        atomic_init(&t.consumer_done, false); atomic_init(&t.failed, 0);
        if (!t.queue) return 30;
        /* Leave unread PCM before racing silence with an active producer. */
        float initial[32];
        for (unsigned i = 0; i < 32; ++i) initial[i] = sample_at(i);
        if (mo_queue_push(t.queue, initial, 32) != 32) { mo_queue_destroy(t.queue); return 31; }
        int result = start_trial(&t, true);
        float l[16], r[16];
        MORenderResult rendered = mo_queue_render(t.queue, (MOFloatBuffer){l,16}, (MOFloatBuffer){r,16}, 16);
        if (rendered != MO_RENDER_SILENCED) result = 32;
        for (unsigned i = 0; i < 16; ++i) if (l[i] != 0 || r[i] != 0) result = 33;
        mo_queue_destroy(t.queue);
        if (result) return result;
    }
    return 0;
}

/* Product-only boundaries also run under the standalone UBSan runner. */
static int product_boundaries(void) {
    if (mo_queue_create(0, 0) || mo_queue_create(3, 0) || mo_queue_create(4097, 0) || mo_queue_create(4, 2)) return 50;
    if (mo_queue_render(NULL, (MOFloatBuffer){0}, (MOFloatBuffer){0}, 0) != MO_RENDER_OK) return 51;
    for (unsigned ear = 0; ear < 2; ++ear) {
        MOFrameQueue *q = mo_queue_create(4, ear);
        if (!q) return 52;
        float input[] = {0.1f, -0.0f, 0.3f, 0.4f, 0.5f}, left[6], right[6];
        for (unsigned i = 0; i < 6; ++i) left[i] = right[i] = 9;
        int result = 0;
        if (mo_queue_push(q, input, 5) != 4 || mo_queue_push(q, input, 1) != 0) result = 53;
        if (mo_queue_render(q, (MOFloatBuffer){left,6}, (MOFloatBuffer){right,6}, 5) != MO_RENDER_UNDERRUN) result = 54;
        if (memcmp(ear ? right : left, input, 4 * sizeof(float))) result = 55;
        for (unsigned i = 0; i < 5; ++i) if ((ear ? left : right)[i] != 0) result = 56;
        if (left[4] != 0 || right[4] != 0 || left[5] != 9 || right[5] != 9) result = 57;
        MOQueueStats stats = mo_queue_read_stats(q);
        if (stats.rendered_frames != 4 || stats.underruns != 1 || stats.high_water_frames != 4 || stats.faulted) result = 58;
        left[0] = left[1] = right[0] = right[1] = 9;
        if (mo_queue_render(q, (MOFloatBuffer){left,1}, (MOFloatBuffer){right,6}, 2) != MO_RENDER_FAULT ||
            left[0] != 0 || left[1] != 9 || right[0] != 0 || right[1] != 0) result = 59;
        mo_queue_destroy(q);
        if (result) return result;
    }
    return 0;
}

#ifndef MO_QUEUE_TEST_MAIN
/* Compile the exact implementation under private names; never linked into product. */
static unsigned allocation_call, fail_allocation, live_allocations;
static unsigned lockfree_call, fail_lockfree;
static void *injected_calloc(size_t count, size_t size) {
    ++allocation_call;
    void *result = fail_allocation == allocation_call ? NULL : calloc(count, size);
    if (result) ++live_allocations;
    return result;
}
static void injected_free(void *allocation) {
    if (allocation) --live_allocations;
    free(allocation);
}
static bool native_lockfree_size(size_t size) {
    switch (size) {
        case sizeof(_Atomic bool): { _Atomic bool v; atomic_init(&v, false); return atomic_is_lock_free(&v); }
        case sizeof(_Atomic uint32_t): { _Atomic uint32_t v; atomic_init(&v, 0); return atomic_is_lock_free(&v); }
        case sizeof(_Atomic uint64_t): { _Atomic uint64_t v; atomic_init(&v, 0); return atomic_is_lock_free(&v); }
        default: return false;
    }
}
#define mo_queue_create mo_test_queue_create
#define mo_queue_destroy mo_test_queue_destroy
#define mo_queue_push mo_test_queue_push
#define mo_queue_render mo_test_queue_render
#define mo_queue_silence mo_test_queue_silence
#define mo_queue_read_stats mo_test_queue_read_stats
#define MO_QUEUE_TESTING 1
#define calloc injected_calloc
#define free injected_free
#undef atomic_is_lock_free
#define atomic_is_lock_free(object) (++lockfree_call != fail_lockfree && native_lockfree_size(sizeof(*(object))))
#include "../../Sources/MonoOtoRealtime/FrameQueue.c"
#undef calloc
#undef free
#undef atomic_is_lock_free
#undef MO_QUEUE_TESTING
#undef mo_queue_create
#undef mo_queue_destroy
#undef mo_queue_push
#undef mo_queue_render
#undef mo_queue_silence
#undef mo_queue_read_stats

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned phase;
    bool reached, proceed, timed_out;
    MOFrameQueue *queue;
    uint32_t accepted;
    MORenderResult result;
    float left[3], right[3];
} HookBarrier;
/* Installed before pthread_create, removed after join; no concurrent test runs. */
static HookBarrier *active_barrier;
static struct timespec deadline_after_five_seconds(void) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;
    return deadline;
}
void mo_queue_test_hook(MOFrameQueue *q, unsigned phase) {
    HookBarrier *b = active_barrier;
    if (!b || b->queue != q || b->phase != phase) return;
    struct timespec deadline = deadline_after_five_seconds();
    pthread_mutex_lock(&b->mutex);
    b->reached = true;
    pthread_cond_broadcast(&b->condition);
    while (!b->proceed) {
        if (pthread_cond_timedwait(&b->condition, &b->mutex, &deadline)) {
            b->timed_out = true; break;
        }
    }
    pthread_mutex_unlock(&b->mutex);
}
static void *hook_worker(void *context) {
    HookBarrier *b = context;
    float input[] = {0.1f, 0.2f};
    if (b->phase == 1) b->accepted = mo_test_queue_push(b->queue, input, 2);
    else b->result = mo_test_queue_render(b->queue, (MOFloatBuffer){b->left,3}, (MOFloatBuffer){b->right,3}, 2);
    return NULL;
}
static int silence_at_hook(unsigned phase) {
    MOFrameQueue *q = mo_test_queue_create(4, 0);
    if (!q) return 100;
    float input[] = {0.1f, 0.2f};
    if (phase != 1 && mo_test_queue_push(q, input, 2) != 2) { mo_test_queue_destroy(q); return 101; }
    HookBarrier b = {.phase = phase, .queue = q, .left = {9,9,9}, .right = {9,9,9}};
    if (pthread_mutex_init(&b.mutex, NULL)) { mo_test_queue_destroy(q); return 102; }
    if (pthread_cond_init(&b.condition, NULL)) { pthread_mutex_destroy(&b.mutex); mo_test_queue_destroy(q); return 103; }
    active_barrier = &b;
    pthread_t worker;
    if (pthread_create(&worker, NULL, hook_worker, &b)) {
        active_barrier = NULL; pthread_cond_destroy(&b.condition); pthread_mutex_destroy(&b.mutex); mo_test_queue_destroy(q); return 104;
    }
    struct timespec deadline = deadline_after_five_seconds();
    pthread_mutex_lock(&b.mutex);
    while (!b.reached) {
        if (pthread_cond_timedwait(&b.condition, &b.mutex, &deadline)) { b.timed_out = true; break; }
    }
    mo_test_queue_silence(q);
    b.proceed = true;
    pthread_cond_broadcast(&b.condition);
    pthread_mutex_unlock(&b.mutex);
    pthread_join(worker, NULL);
    active_barrier = NULL;
    int result = b.timed_out ? 105 : 0;
    MOQueueStats stats = mo_test_queue_read_stats(q);
    if (phase == 1 && (b.accepted != 0 || atomic_load(&q->write_position) != 0)) result = 106;
    if (phase == 2 && (b.result != MO_RENDER_SILENCED || b.left[0] != 0 || b.left[1] != 0 || stats.rendered_frames != 0)) result = 107;
    /* The documented boundary: silence cannot recall a render past its final check. */
    if (phase == 3 && (b.result != MO_RENDER_OK || memcmp(b.left,input,sizeof(input)) || stats.rendered_frames != 2)) result = 108;
    if (phase != 1 && (b.right[0] != 0 || b.right[1] != 0 || b.left[2] != 9 || b.right[2] != 9)) result = 109;
    if (mo_test_queue_render(q, (MOFloatBuffer){b.left,3}, (MOFloatBuffer){b.right,3}, 2) != MO_RENDER_SILENCED || b.left[0] != 0 || b.left[1] != 0) result = 110;
    pthread_cond_destroy(&b.condition); pthread_mutex_destroy(&b.mutex); mo_test_queue_destroy(q);
    return result;
}
static int inject_wrap(uint32_t capacity, bool initially_nonempty) {
    MOFrameQueue *q = mo_test_queue_create(capacity, 1);
    if (!q) return 120;
    uint32_t start = UINT32_MAX;
    atomic_store(&q->read_position, start);
    atomic_store(&q->write_position, start);
    if (initially_nonempty) {
        q->pcm[start & (capacity - 1)] = 0.1f;
        atomic_store(&q->write_position, start + 1);
    }
    float input[] = {0.1f, 0.2f}, l[3], r[3];
    int result = 0;
    if (!initially_nonempty && mo_test_queue_push(q, input, 1) != 1) result = 121;
    if (mo_test_queue_render(q, (MOFloatBuffer){l,3}, (MOFloatBuffer){r,3}, 1) != MO_RENDER_OK || r[0] != 0.1f || l[0] != 0) result = 122;
    if (atomic_load(&q->read_position) != 0 || atomic_load(&q->write_position) != 0) result = 123;
    if (mo_test_queue_push(q, input + 1, 1) != 1 || mo_test_queue_render(q, (MOFloatBuffer){l,3}, (MOFloatBuffer){r,3}, 1) != MO_RENDER_OK || r[0] != 0.2f) result = 124;
    MOQueueStats stats = mo_test_queue_read_stats(q);
    if (stats.faulted || stats.rendered_frames != 2 || stats.high_water_frames > capacity) result = 125;
    mo_test_queue_destroy(q);
    return result;
}
static int injected_failures(void) {
    for (unsigned failure = 1; failure <= 2; ++failure) {
        allocation_call = 0; fail_allocation = failure;
        MOFrameQueue *q = mo_test_queue_create(4, 0);
        fail_allocation = 0;
        if (q || allocation_call != failure || live_allocations != 0) { mo_test_queue_destroy(q); return 130; }
    }
    // Each position/flag/diagnostic atomic must independently reject creation.
    for (unsigned failure = 1; failure <= 11; ++failure) {
        lockfree_call = 0; fail_lockfree = failure;
        MOFrameQueue *q = mo_test_queue_create(4, 0);
        fail_lockfree = 0;
        if (q || lockfree_call != failure || live_allocations != 0) { mo_test_queue_destroy(q); return 131; }
    }
    MOFrameQueue *q;
    for (unsigned kind = 0; kind < 4; ++kind) {
        q = mo_test_queue_create(4, 0);
        if (!q) return 132;
        float input[2] = {0.1f,0.2f}, l[3] = {9,9,9}, r[3] = {9,9,9};
        int result = 0;
        if (kind == 0) {
            q->pcm[0] = NAN; q->pcm[1] = INFINITY;
            atomic_store(&q->write_position, 2);
            if (mo_test_queue_render(q, (MOFloatBuffer){l,3}, (MOFloatBuffer){r,3}, 2) != MO_RENDER_FAULT ||
                l[0] != 0 || l[1] != 0 || r[0] != 0 || r[1] != 0 || l[2] != 9 || r[2] != 9) result = 133;
            if (mo_test_queue_read_stats(q).invalid_samples != 2) result = 134;
        } else if (kind == 1 || kind == 2) {
            atomic_store(&q->write_position, 5);
            if (kind == 1 && mo_test_queue_push(q,input,2) != 0) result = 135;
            if (kind == 2 && mo_test_queue_render(q, (MOFloatBuffer){l,3}, (MOFloatBuffer){r,3}, 2) != MO_RENDER_FAULT) result = 136;
            if (mo_test_queue_read_stats(q).invalid_buffers != 1) result = 137;
        } else {
            q->pcm[0] = 0.3f;
            if (mo_test_queue_render(q, (MOFloatBuffer){q->pcm,4}, (MOFloatBuffer){r,3}, 2) != MO_RENDER_FAULT || q->pcm[0] != 0.3f) result = 138;
        }
        MOQueueStats stats = mo_test_queue_read_stats(q);
        if (!stats.faulted || !stats.silenced || stats.rendered_frames || stats.underruns) result = 139;
        if (mo_test_queue_push(q,input,2) != 0 || mo_test_queue_render(q, (MOFloatBuffer){l,3}, (MOFloatBuffer){r,3}, 2) != MO_RENDER_FAULT) result = 140;
        mo_test_queue_destroy(q);
        if (result) return result;
    }
    return 0;
}
static int compare_product_and_instrumented(void) {
    for (unsigned ear = 0; ear < 2; ++ear) {
        MOFrameQueue *product = mo_queue_create(4, ear), *instrumented = mo_test_queue_create(4, ear);
        if (!product || !instrumented) { mo_queue_destroy(product); mo_test_queue_destroy(instrumented); return 150; }
        uint32_t seed = 10301;
        int failed = 0;
        for (unsigned turn = 0; turn < 1000; ++turn) {
            float input[7], pl[9], pr[9], il[9], ir[9];
            uint32_t count = 1 + random_next(&seed) % 7;
            for (unsigned i = 0; i < 7; ++i) input[i] = sample_at(turn + i);
            if (random_next(&seed) & 16) {
                if (mo_queue_push(product,input,count) != mo_test_queue_push(instrumented,input,count)) failed = 151;
            } else {
                for (unsigned i = 0; i < 9; ++i) pl[i] = pr[i] = il[i] = ir[i] = 9;
                if (mo_queue_render(product,(MOFloatBuffer){pl,9},(MOFloatBuffer){pr,9},count) != mo_test_queue_render(instrumented,(MOFloatBuffer){il,9},(MOFloatBuffer){ir,9},count) || memcmp(pl,il,sizeof(pl)) || memcmp(pr,ir,sizeof(pr))) failed = 152;
            }
            MOQueueStats a = mo_queue_read_stats(product), b = mo_test_queue_read_stats(instrumented);
            if (a.rendered_frames != b.rendered_frames || a.underruns != b.underruns || a.high_water_frames != b.high_water_frames || a.faulted != b.faulted || a.invalid_samples != b.invalid_samples || a.invalid_buffers != b.invalid_buffers) failed = 153;
            if (failed) break;
        }
        mo_queue_destroy(product); mo_test_queue_destroy(instrumented);
        if (failed) return failed;
    }
    return 0;
}
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned stage;
    bool timed_out;
    MOFrameQueue *queue;
    uint32_t accepted, full_accepted;
} PressureBarrier;
static void *pressure_producer(void *context) {
    PressureBarrier *b = context;
    struct timespec deadline = deadline_after_five_seconds();
    pthread_mutex_lock(&b->mutex);
    while (b->stage < 1 && !b->timed_out) {
        if (pthread_cond_timedwait(&b->condition, &b->mutex, &deadline)) b->timed_out = true;
    }
    bool proceed = !b->timed_out;
    pthread_mutex_unlock(&b->mutex);
    if (proceed) {
        float input[] = {0.1f, 0.2f, 0.3f, 0.4f};
        b->accepted = mo_queue_push(b->queue, input, 4);
        b->full_accepted = mo_queue_push(b->queue, input, 1);
    }
    pthread_mutex_lock(&b->mutex);
    b->stage = 2;
    pthread_cond_broadcast(&b->condition);
    pthread_mutex_unlock(&b->mutex);
    return NULL;
}
static int deterministic_pressure(void) {
    PressureBarrier b = {.queue = mo_queue_create(4, 0)};
    if (!b.queue) return 160;
    if (pthread_mutex_init(&b.mutex, NULL)) { mo_queue_destroy(b.queue); return 161; }
    if (pthread_cond_init(&b.condition, NULL)) { pthread_mutex_destroy(&b.mutex); mo_queue_destroy(b.queue); return 162; }
    pthread_t producer;
    if (pthread_create(&producer, NULL, pressure_producer, &b)) {
        pthread_cond_destroy(&b.condition); pthread_mutex_destroy(&b.mutex); mo_queue_destroy(b.queue); return 163;
    }
    // Producer is held until the consumer has deterministically observed starvation.
    float left[5] = {9,9,9,9,9}, right[5] = {9,9,9,9,9};
    int failed = 0;
    if (mo_queue_render(b.queue, (MOFloatBuffer){left,5}, (MOFloatBuffer){right,5}, 4) != MO_RENDER_UNDERRUN) failed = 164;
    for (unsigned i = 0; i < 4; ++i) if (left[i] != 0 || right[i] != 0) failed = 165;
    if (left[4] != 9 || right[4] != 9) failed = 166;
    struct timespec deadline = deadline_after_five_seconds();
    pthread_mutex_lock(&b.mutex);
    b.stage = 1;
    pthread_cond_broadcast(&b.condition);
    // Consumer remains held until the producer has observed a completely full queue.
    while (b.stage < 2 && !b.timed_out) {
        if (pthread_cond_timedwait(&b.condition, &b.mutex, &deadline)) b.timed_out = true;
    }
    bool timed_out = b.timed_out;
    pthread_mutex_unlock(&b.mutex);
    pthread_join(producer, NULL);
    if (timed_out) failed = 167;
    if (b.accepted != 4 || b.full_accepted != 0) failed = 168;
    if (mo_queue_render(b.queue, (MOFloatBuffer){left,5}, (MOFloatBuffer){right,5}, 4) != MO_RENDER_OK) failed = 169;
    const float expected[] = {0.1f,0.2f,0.3f,0.4f};
    if (memcmp(left,expected,sizeof(expected))) failed = 170;
    for (unsigned i = 0; i < 4; ++i) if (right[i] != 0) failed = 171;
    if (left[4] != 9 || right[4] != 9) failed = 172;
    MOQueueStats stats = mo_queue_read_stats(b.queue);
    if (stats.underruns != 1 || stats.high_water_frames != 4 || stats.rendered_frames != 4 || stats.faulted || stats.invalid_samples || stats.invalid_buffers) failed = 173;
    pthread_cond_destroy(&b.condition); pthread_mutex_destroy(&b.mutex); mo_queue_destroy(b.queue);
    return failed;
}
int mo_test_injected_contracts(void) {
    int result = product_boundaries();
    if (result) return result;
    result = deterministic_pressure();
    if (result) return result;
    result = injected_failures();
    if (result) return result;
    for (unsigned phase = 1; phase <= 3; ++phase) if ((result = silence_at_hook(phase))) return result;
    for (unsigned nonempty = 0; nonempty < 2; ++nonempty) {
        if ((result = inject_wrap(1,nonempty))) return result;
        if ((result = inject_wrap(4096,nonempty))) return result;
    }
    return compare_product_and_instrumented();
}
#endif

#ifdef MO_QUEUE_TEST_MAIN
static int compare_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}
static bool parse_number(const char *s, uint32_t *out) {
    if (!s || !*s) return false;
    for (const char *p = s; *p; ++p) if (*p < '0' || *p > '9') return false;
    errno = 0;
    char *end;
    unsigned long v = strtoul(s, &end, 10);
    if (errno || *end || v > UINT32_MAX || !v) return false;
    *out = (uint32_t)v;
    return true;
}
static int load_test(uint32_t seconds, uint32_t rate, uint32_t frames) {
    const uint64_t period = (uint64_t)frames * UINT64_C(1000000000) / rate;
    const uint64_t count = ((uint64_t)seconds * rate + frames - 1) / frames;
    if (count > 20000000) return 40;
    uint64_t *durations = calloc((size_t)count, sizeof(*durations));
    float *left = calloc(frames, sizeof(float)), *right = calloc(frames, sizeof(float));
    Trial t = {.queue = mo_queue_create(4096, 0), .limit = UINT64_MAX,
               .deadline = now_ns() + ((uint64_t)seconds + 30) * UINT64_C(1000000000)};
    atomic_init(&t.producer_calls, 0); atomic_init(&t.consumer_calls, 0); atomic_init(&t.observer_calls, 0);
    atomic_init(&t.stop, false); atomic_init(&t.producer_done, false);
    atomic_init(&t.consumer_done, false); atomic_init(&t.failed, 0);
    if (!durations || !left || !right || !t.queue) {
        free(durations); free(left); free(right); mo_queue_destroy(t.queue); return 41;
    }
    pthread_t producer;
    if (pthread_create(&producer, NULL, produce, &t)) {
        free(durations); free(left); free(right); mo_queue_destroy(t.queue); return 42;
    }
    uint64_t begin = now_ns(), consumed = 0, late = 0, max_late = 0, completed = 0, audio_calls = 0;
    int failed = 0;
    for (uint64_t i = 0; i < count; ++i) {
        uint64_t target = begin + i * period, current = now_ns();
        if (current < target) sleep_ns(target - current);
        uint64_t start = now_ns(), tardiness = start > target ? start - target : 0;
        if (tardiness >= period) ++late;
        if (tardiness > max_late) max_late = tardiness;
        uint64_t before = consumed;
        MORenderResult result = mo_queue_render(t.queue, (MOFloatBuffer){left,frames}, (MOFloatBuffer){right,frames}, frames);
        durations[i] = now_ns() - start;
        ++completed;
        if (result == MO_RENDER_FAULT || result == MO_RENDER_SILENCED || check_output(left, right, frames, 0, &consumed) || atomic_load(&t.failed)) { failed = 43; break; }
        if (consumed > before) ++audio_calls;
        if (durations[i] > period) failed = 44;
    }
    uint64_t end_target = begin + (uint64_t)seconds * UINT64_C(1000000000);
    uint64_t current = now_ns();
    if (!failed && current < end_target) sleep_ns(end_target - current);
    uint64_t elapsed = now_ns() - begin;
    mo_queue_silence(t.queue); atomic_store(&t.stop, true); pthread_join(producer, NULL);
    MOQueueStats stats = mo_queue_read_stats(t.queue);
    if (!consumed || stats.rendered_frames != consumed || stats.faulted || stats.invalid_samples || stats.invalid_buffers || stats.high_water_frames > 4096) failed = 45;
    qsort(durations, (size_t)completed, sizeof(*durations), compare_u64);
    printf("load seconds_requested=%u elapsed_seconds=%.6f rate=%u frames=%u calls=%llu audio_calls=%llu max_ns=%llu p99_ns=%llu period_ns=%llu late_periods=%llu max_late_ns=%llu underruns=%llu high_water=%u rendered=%llu result=%d\n",
        seconds, elapsed / 1e9, rate, frames, (unsigned long long)completed, (unsigned long long)audio_calls,
        (unsigned long long)durations[completed-1], (unsigned long long)durations[(completed-1)*99/100],
        (unsigned long long)period, (unsigned long long)late, (unsigned long long)max_late,
        (unsigned long long)stats.underruns, stats.high_water_frames, (unsigned long long)stats.rendered_frames, failed);
    free(durations); free(left); free(right); mo_queue_destroy(t.queue);
    return failed;
}
int main(int argc, char **argv) {
    if (argc == 1) {
        int boundary = product_boundaries(), order = mo_test_concurrent_order(), life = mo_test_lifecycle();
        printf("finite boundaries=%d order=%d lifecycle=%d\n", boundary, order, life);
        return boundary || order || life;
    }
    uint32_t seconds = 0, rate = 0, frames = 0;
    if (argc != 7) return 64;
    for (int i = 1; i < argc; i += 2) {
        uint32_t *value = !strcmp(argv[i], "--seconds") ? &seconds :
                          !strcmp(argv[i], "--rate") ? &rate :
                          !strcmp(argv[i], "--frames") ? &frames : NULL;
        if (!value || *value || !parse_number(argv[i+1], value)) return 64;
    }
    if (seconds > 86400 || (rate != 44100 && rate != 48000) || frames > MO_QUEUE_MAX_RENDER_FRAMES) return 64;
    return load_test(seconds, rate, frames);
}
#endif
