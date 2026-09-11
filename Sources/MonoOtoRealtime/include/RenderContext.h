#ifndef MO_RENDER_CONTEXT_H
#define MO_RENDER_CONTEXT_H
#include "FrameQueue.h"
#include <CoreAudio/CoreAudioTypes.h>
typedef struct MORenderContext MORenderContext;
typedef struct { uint64_t entries, exits; uint32_t active_callbacks; bool held, faulted; } MORenderContextStats;
/* Context borrows queue. Destroy both only on control after producer completion,
 * backend callback closure ownership release, and all callbacks have exited.
 * Initial hold is true. Hold is reversible; queue silence/fault never is.
 * Exactly one render consumer. ABL allocation and the truthfulness/lifetime of its
 * mData ranges are caller contracts; outputs must not alias queue/context storage.
 * At most two buffer descriptors are inspected, and at most 16384 frames cleared.
 * A malformed list does not guarantee isSilence (unreachable buffers may remain).
 */
MORenderContext *mo_render_context_create(MOFrameQueue *queue);
void mo_render_context_destroy(MORenderContext *context);
bool mo_render_context_set_hold(MORenderContext *context, bool hold);
MORenderResult mo_render_context_render(MORenderContext *context, AudioBufferList *buffers, uint32_t frames, bool *is_silence);
MORenderContextStats mo_render_context_read_stats(const MORenderContext *context);
#endif
