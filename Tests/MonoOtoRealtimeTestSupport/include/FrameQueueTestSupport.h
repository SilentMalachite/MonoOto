#ifndef MO_FRAME_QUEUE_TEST_SUPPORT_H
#define MO_FRAME_QUEUE_TEST_SUPPORT_H
/* Test-only pthread harness. Return zero on success; all workers join before destroy. */
int mo_test_concurrent_order(void);
int mo_test_lifecycle(void);
int mo_test_injected_contracts(void);
/* phase 1: after C entry; phase 2: after queue return. Both hold and silence. */
int mo_test_render_context_barriers(unsigned phase);
#endif
