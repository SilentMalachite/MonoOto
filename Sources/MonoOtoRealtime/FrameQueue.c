#include "FrameQueue.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct MOFrameQueue {
    uint32_t capacity;
    unsigned ear;
    float peak;
    float *pcm;
    _Atomic uint32_t read_position, write_position;
    _Atomic bool silenced, faulted;
    _Atomic uint64_t underruns, rendered_frames;
    _Atomic uint64_t producer_invalid_samples, consumer_invalid_samples;
    _Atomic uint64_t producer_invalid_buffers, consumer_invalid_buffers;
    _Atomic uint32_t high_water_frames;
};

MOFrameQueue *mo_queue_create(uint32_t capacity, unsigned ear) {
    if (!capacity || capacity > MO_QUEUE_MAX_CAPACITY || (capacity & (capacity - 1)) || ear > 1) return NULL;
    MOFrameQueue *q = calloc(1, sizeof(*q));
    if (!q) return NULL;
    q->capacity = capacity;
    q->ear = ear;
    q->peak = (float)pow(10.0, -3.0 / 20.0);
#define INIT_ATOMIC(name) atomic_init(&q->name, 0)
    INIT_ATOMIC(read_position); INIT_ATOMIC(write_position);
    INIT_ATOMIC(silenced); INIT_ATOMIC(faulted);
    INIT_ATOMIC(underruns); INIT_ATOMIC(rendered_frames);
    INIT_ATOMIC(producer_invalid_samples); INIT_ATOMIC(consumer_invalid_samples);
    INIT_ATOMIC(producer_invalid_buffers); INIT_ATOMIC(consumer_invalid_buffers);
    INIT_ATOMIC(high_water_frames);
#undef INIT_ATOMIC
#define CHECK_ATOMIC(name) if (!atomic_is_lock_free(&q->name)) { free(q); return NULL; }
    CHECK_ATOMIC(read_position); CHECK_ATOMIC(write_position);
    CHECK_ATOMIC(silenced); CHECK_ATOMIC(faulted);
    CHECK_ATOMIC(underruns); CHECK_ATOMIC(rendered_frames);
    CHECK_ATOMIC(producer_invalid_samples); CHECK_ATOMIC(consumer_invalid_samples);
    CHECK_ATOMIC(producer_invalid_buffers); CHECK_ATOMIC(consumer_invalid_buffers);
    CHECK_ATOMIC(high_water_frames);
#undef CHECK_ATOMIC
    q->pcm = calloc(capacity, sizeof(float));
    if (!q->pcm) { free(q); return NULL; }
    return q;
}
void mo_queue_destroy(MOFrameQueue *q) { if (q) { free(q->pcm); free(q); } }
// Each counter has exactly one updating owner; observers only read snapshots.
static void add_counter(_Atomic uint64_t *counter, uint64_t value) {
    atomic_store_explicit(counter, atomic_load_explicit(counter, memory_order_relaxed) + value, memory_order_relaxed);
}
#ifdef MO_QUEUE_TESTING
extern void mo_queue_test_hook(MOFrameQueue *, unsigned);
#define MO_TEST_HOOK(q, phase) mo_queue_test_hook(q, phase)
#else
#define MO_TEST_HOOK(q, phase) ((void)0)
#endif

static void latch_fault(MOFrameQueue *q) {
    atomic_store_explicit(&q->faulted, true, memory_order_release);
    atomic_store_explicit(&q->silenced, true, memory_order_release);
}
static MORenderResult terminal_state(const MOFrameQueue *q) {
    // Observing fault's silence release orders the subsequent fault load.
    bool silenced = atomic_load_explicit(&q->silenced, memory_order_acquire);
    if (atomic_load_explicit(&q->faulted, memory_order_acquire)) return MO_RENDER_FAULT;
    return silenced ? MO_RENDER_SILENCED : MO_RENDER_OK;
}
static bool float_range(const float *data, uint32_t count, uintptr_t *end) {
    uintptr_t start = (uintptr_t)data;
    if (!data || start % _Alignof(float)) return false;
#if SIZE_MAX < UINT64_MAX
    if (count > SIZE_MAX / sizeof(float)) return false;
#endif
    size_t bytes = (size_t)count * sizeof(float);
    if (start > UINTPTR_MAX - bytes) return false;
    *end = start + bytes;
    return true;
}
static bool overlaps(uintptr_t a, uintptr_t a_end, uintptr_t b, uintptr_t b_end) {
    return a < b_end && b < a_end;
}
static bool aliases_storage(const MOFrameQueue *q, const float *data, uintptr_t end) {
    return q && overlaps((uintptr_t)data, end, (uintptr_t)q->pcm,
                         (uintptr_t)q->pcm + (size_t)q->capacity * sizeof(float));
}
static void zero_reachable(const MOFrameQueue *q, MOFloatBuffer output, uint32_t count) {
    uintptr_t end;
    // Reject invalid declared ranges before doing any address arithmetic or writes.
    if (!float_range(output.data, output.capacity, &end) || aliases_storage(q, output.data, end)) return;
    uint32_t n = count < output.capacity ? count : output.capacity;
    if (n > MO_QUEUE_MAX_RENDER_FRAMES) n = MO_QUEUE_MAX_RENDER_FRAMES;
    memset(output.data, 0, (size_t)n * sizeof(float));
}
static void zero_outputs(const MOFrameQueue *q, MOFloatBuffer left, MOFloatBuffer right, uint32_t count) {
    zero_reachable(q, left, count);
    zero_reachable(q, right, count);
}
uint32_t mo_queue_push(MOFrameQueue *q, const float *input, uint32_t count) {
    if (!count || !q) return 0;
    uintptr_t end;
    if (count > MO_QUEUE_MAX_CAPACITY || !float_range(input, count, &end) || aliases_storage(q, input, end)) {
        add_counter(&q->producer_invalid_buffers, 1); latch_fault(q); return 0;
    }
    if (terminal_state(q) != MO_RENDER_OK) return 0;
    uint32_t write = atomic_load_explicit(&q->write_position, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&q->read_position, memory_order_acquire);
    uint32_t occupied = write - read;
    if (occupied > q->capacity) {
        add_counter(&q->producer_invalid_buffers, 1); latch_fault(q); return 0;
    }
    uint32_t available = q->capacity - occupied;
    uint32_t n = count < available ? count : available;
    if (!n) return 0;
    uint64_t invalid = 0;
    for (uint32_t i = 0; i < n; ++i)
        if (!isfinite(input[i]) || fabsf(input[i]) > q->peak) ++invalid;
    if (invalid) {
        add_counter(&q->producer_invalid_samples, invalid); latch_fault(q); return 0;
    }
    for (uint32_t i = 0; i < n; ++i) q->pcm[(write + i) & (q->capacity - 1)] = input[i];
    MO_TEST_HOOK(q, 1);
    if (terminal_state(q) != MO_RENDER_OK) return 0;
    // The consumer may read these slots only after its acquire of this publication.
    atomic_store_explicit(&q->write_position, write + n, memory_order_release);
    if (occupied + n > atomic_load_explicit(&q->high_water_frames, memory_order_relaxed))
        atomic_store_explicit(&q->high_water_frames, occupied + n, memory_order_relaxed);
    return n;
}
MORenderResult mo_queue_render(MOFrameQueue *q, MOFloatBuffer left, MOFloatBuffer right, uint32_t count) {
    if (!count) return MO_RENDER_OK;
    uintptr_t left_end = 0, right_end = 0;
    bool valid_left = float_range(left.data, left.capacity, &left_end);
    bool valid_right = float_range(right.data, right.capacity, &right_end);
    bool valid = valid_left && valid_right && count <= MO_QUEUE_MAX_RENDER_FRAMES
        && left.capacity >= count && right.capacity >= count
        && !overlaps((uintptr_t)left.data, left_end, (uintptr_t)right.data, right_end)
        && !aliases_storage(q, left.data, left_end) && !aliases_storage(q, right.data, right_end);
    zero_outputs(q, left, right, count);
    if (!q) return MO_RENDER_FAULT;
    if (!valid) { add_counter(&q->consumer_invalid_buffers, 1); latch_fault(q); return MO_RENDER_FAULT; }
    MORenderResult state = terminal_state(q);
    if (state != MO_RENDER_OK) return state;
    uint32_t read = atomic_load_explicit(&q->read_position, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&q->write_position, memory_order_acquire);
    uint32_t available = write - read;
    if (available > q->capacity) {
        add_counter(&q->consumer_invalid_buffers, 1); latch_fault(q); return MO_RENDER_FAULT;
    }
    uint32_t n = count < available ? count : available;
    uint64_t invalid = 0;
    for (uint32_t i = 0; i < n; ++i) {
        float sample = q->pcm[(read + i) & (q->capacity - 1)];
        if (!isfinite(sample) || fabsf(sample) > q->peak) ++invalid;
    }
    if (invalid) {
        add_counter(&q->consumer_invalid_samples, invalid); latch_fault(q); return MO_RENDER_FAULT;
    }
    float *output = q->ear == 0 ? left.data : right.data;
    for (uint32_t i = 0; i < n; ++i) output[i] = q->pcm[(read + i) & (q->capacity - 1)];
    // Release only after all PCM reads; producer can then reuse consumed slots.
    atomic_store_explicit(&q->read_position, read + n, memory_order_release);
    MO_TEST_HOOK(q, 2);
    state = terminal_state(q);
    if (state != MO_RENDER_OK) { zero_outputs(q, left, right, count); return state; }
    MO_TEST_HOOK(q, 3);
    add_counter(&q->rendered_frames, n);
    if (n < count) { add_counter(&q->underruns, 1); return MO_RENDER_UNDERRUN; }
    return MO_RENDER_OK;
}
void mo_queue_silence(MOFrameQueue *q) { if (q) atomic_store_explicit(&q->silenced, true, memory_order_release); }
MOQueueStats mo_queue_read_stats(const MOFrameQueue *q) {
    if (!q) return (MOQueueStats){ .faulted = true };
#define LOAD(name) atomic_load_explicit(&q->name, memory_order_relaxed)
    return (MOQueueStats){ .underruns = LOAD(underruns), .rendered_frames = LOAD(rendered_frames),
        .invalid_samples = LOAD(producer_invalid_samples) + LOAD(consumer_invalid_samples),
        .invalid_buffers = LOAD(producer_invalid_buffers) + LOAD(consumer_invalid_buffers),
        .high_water_frames = LOAD(high_water_frames), .silenced = LOAD(silenced), .faulted = LOAD(faulted) };
#undef LOAD
}
