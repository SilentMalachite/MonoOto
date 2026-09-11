#include "RenderContext.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#ifdef MO_RENDER_CONTEXT_TESTING
extern void mo_render_context_test_hook(MORenderContext *, unsigned);
#define MO_CONTEXT_TEST_HOOK(c, phase) mo_render_context_test_hook(c, phase)
#else
#define MO_CONTEXT_TEST_HOOK(c, phase) ((void)0)
#endif
struct MORenderContext {
    MOFrameQueue *queue;
    _Atomic bool held, faulted;
    _Atomic uint32_t active;
    _Atomic uint64_t entries, exits;
};
MORenderContext *mo_render_context_create(MOFrameQueue *q) {
    if (!q) return NULL;
    MORenderContext *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->queue = q;
    atomic_init(&c->held, true); atomic_init(&c->faulted, false);
    atomic_init(&c->active, 0); atomic_init(&c->entries, 0); atomic_init(&c->exits, 0);
    if (!atomic_is_lock_free(&c->held) || !atomic_is_lock_free(&c->faulted) ||
        !atomic_is_lock_free(&c->active) || !atomic_is_lock_free(&c->entries) || !atomic_is_lock_free(&c->exits)) {
        free(c); return NULL;
    }
    return c;
}
void mo_render_context_destroy(MORenderContext *c) { free(c); }
bool mo_render_context_set_hold(MORenderContext *c, bool hold) {
    if (!c) return false;
    if (!hold) {
        MOQueueStats s = mo_queue_read_stats(c->queue);
        if (s.silenced || s.faulted || atomic_load(&c->faulted)) return false;
    }
    atomic_store(&c->held, hold);
    return true;
}
static bool range(AudioBuffer b, uintptr_t *end) {
    uintptr_t p = (uintptr_t)b.mData;
    if (!p || p % _Alignof(float) || p > UINTPTR_MAX - b.mDataByteSize) return false;
    *end = p + b.mDataByteSize;
    return true;
}
MORenderResult mo_render_context_render(MORenderContext *c, AudioBufferList *abl, uint32_t frames, bool *silent) {
    if (silent) *silent = frames == 0;
    if (!frames) return MO_RENDER_OK;
    if (c) { atomic_fetch_add(&c->active, 1); atomic_fetch_add(&c->entries, 1); }
    MO_CONTEXT_TEST_HOOK(c, 1);
    AudioBuffer b[2] = {{0}, {0}};
    uint32_t n = abl ? (abl->mNumberBuffers < 2 ? abl->mNumberBuffers : 2) : 0;
    for (uint32_t i = 0; i < n; ++i) b[i] = abl->mBuffers[i];
    uintptr_t end[2] = {0, 0};
    bool reachable[2] = {range(b[0], &end[0]), range(b[1], &end[1])};
    bool valid = c && abl && abl->mNumberBuffers == 2 && frames <= MO_QUEUE_MAX_RENDER_FRAMES;
    for (unsigned i = 0; i < 2; ++i) {
        valid = valid && reachable[i] && b[i].mNumberChannels == 1 &&
            b[i].mDataByteSize % sizeof(float) == 0 && b[i].mDataByteSize / sizeof(float) >= frames;
        if (reachable[i]) {
            uint32_t clear = b[i].mDataByteSize / sizeof(float);
            if (clear > frames) clear = frames;
            if (clear > MO_QUEUE_MAX_RENDER_FRAMES) clear = MO_QUEUE_MAX_RENDER_FRAMES;
            memset(b[i].mData, 0, (size_t)clear * sizeof(float));
        }
    }
    valid = valid && !((uintptr_t)b[0].mData < end[1] && (uintptr_t)b[1].mData < end[0]);
    MORenderResult result = MO_RENDER_FAULT;
    if (!valid) {
        if (c) { atomic_store(&c->faulted, true); mo_queue_silence(c->queue); }
    } else if (atomic_load(&c->held)) {
        result = atomic_load(&c->faulted) ? MO_RENDER_FAULT : MO_RENDER_SILENCED;
    } else {
        result = mo_queue_render(c->queue,
            (MOFloatBuffer){b[0].mData, b[0].mDataByteSize / sizeof(float)},
            (MOFloatBuffer){b[1].mData, b[1].mDataByteSize / sizeof(float)}, frames);
        MO_CONTEXT_TEST_HOOK(c, 2);
        if (result == MO_RENDER_FAULT) atomic_store(&c->faulted, true);
    }
    if (valid && silent) {
        bool zero = true;
        for (uint32_t i = 0; i < frames; ++i)
            if (((float *)b[0].mData)[i] != 0 || ((float *)b[1].mData)[i] != 0) { zero = false; break; }
        *silent = zero;
    }
    if (c) { atomic_fetch_add(&c->exits, 1); atomic_fetch_sub(&c->active, 1); }
    return result;
}
MORenderContextStats mo_render_context_read_stats(const MORenderContext *c) {
    if (!c) return (MORenderContextStats){.faulted=true, .held=true};
    return (MORenderContextStats){atomic_load(&c->entries), atomic_load(&c->exits),
        atomic_load(&c->active), atomic_load(&c->held), atomic_load(&c->faulted)};
}
