#ifndef MO_FRAME_QUEUE_H
#define MO_FRAME_QUEUE_H
#include <stdbool.h>
#include <stdint.h>
enum { MO_QUEUE_MAX_CAPACITY = 4096, MO_QUEUE_MAX_RENDER_FRAMES = 16384 };
typedef struct MOFrameQueue MOFrameQueue;
typedef struct { float *data; uint32_t capacity; } MOFloatBuffer;
typedef enum { MO_RENDER_OK, MO_RENDER_UNDERRUN, MO_RENDER_SILENCED, MO_RENDER_FAULT } MORenderResult;
typedef struct {
 uint64_t underruns, invalid_samples, invalid_buffers, rendered_frames;
 uint32_t high_water_frames;
 bool silenced, faulted;
} MOQueueStats;
/* Internal, rate-independent Float32 mono PCM queue. Frames are the unit throughout.
 * Capacity: power of two in 1...4096; ear: 0=left, 1=right. Creation allocates on
 * the control thread and fails if any atomic (including diagnostics) is not lock-free.
 * No gain or conversion: finite samples within Float32(pow(10,-3/20)) retain bits.
 * Exactly one producer owns push; exactly one consumer owns render. Control may
 * concurrently silence/read stats. Destroy only after ALL callers have finished.
 * Silence is irreversible, not a join; create a new queue for a new generation.
 */
MOFrameQueue *mo_queue_create(uint32_t capacity, unsigned ear);
void mo_queue_destroy(MOFrameQueue *q);
/* count=0 takes priority over every other argument/state and touches nothing.
 * Otherwise input must contain count readable aligned floats (count <= 4096).
 * Full/partial pushes are backpressure: retry unaccepted frames; only accepted
 * candidates are inspected. Any invalid candidate faults the entire push.
 * Input/output/internal storage must not alias; callers guarantee concurrent
 * input/output non-aliasing, pointer lifetime and truthfulness of capacities.
 */
uint32_t mo_queue_push(MOFrameQueue *q, const float *input, uint32_t count);
/* count <= 16384; both output capacities independently cover count. Declared
 * capacity ranges must be aligned, writable and non-overlapping in their entirety.
 * Invalid requests latch fault+silence and zero only reachable aligned ranges up
 * to min(count, capacity, 16384); invalid address arithmetic/storage aliases are
 * never dereferenced. C cannot detect dangling pointers or false capacities.
 * A render observing silence returns all zeros. A concurrent render already past
 * its final check may still return PCM; OS buffers cannot be recalled here.
 * NULL q: nonzero render clears reachable outputs and returns FAULT; push returns
 * zero, destroy/silence are no-ops, stats returns zeros with faulted=true.
 */
MORenderResult mo_queue_render(MOFrameQueue *q, MOFloatBuffer left, MOFloatBuffer right, uint32_t count);
void mo_queue_silence(MOFrameQueue *q);
/* Independent atomic snapshots, not a coherent instant. uint64 counters wrap.
 * underruns counts normal short render calls; invalid_samples counts all detected
 * invalid candidates; invalid_buffers counts invalid nonzero API requests.
 * rendered_frames counts original PCM (including real zeros) returned by normal
 * OK/UNDERRUN renders, excluding padding/silence/fault; not an OS playback cursor.
 * high_water_frames is producer-observed occupancy, bounded by capacity.
 */
MOQueueStats mo_queue_read_stats(const MOFrameQueue *q);
#endif
