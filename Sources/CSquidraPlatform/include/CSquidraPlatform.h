#ifndef SQUIDRA_PLATFORM_H
#define SQUIDRA_PLATFORM_H
#include <stdint.h>
/* 1 = known local filesystem; 0 = unsupported; -1 = syscall failed.
 * The caller retains ownership of fd. No paths or filesystem data are returned. */
int squidra_filesystem_is_local(int fd);
/* Pure Linux magic-number classifier, also exposed for deterministic tests. */
int squidra_linux_filesystem_type_is_local(uint64_t type);
#endif
