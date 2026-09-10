#ifndef MO_FRAME_QUEUE_TEST_SUPPORT_H
#define MO_FRAME_QUEUE_TEST_SUPPORT_H
/* Test-only pthread harness. Return zero on success; all workers join before destroy. */
int mo_test_concurrent_order(void);
int mo_test_lifecycle(void);
int mo_test_injected_contracts(void);
#endif
