#include "CSquidraPlatform.h"
#if defined(__APPLE__)
#include <sys/mount.h>
#elif defined(__linux__)
#include <sys/vfs.h>
#endif

int squidra_linux_filesystem_type_is_local(uint64_t type) {
    switch (type) {
        case 0xef53:     /* ext */
        case 0x01021994: /* tmpfs */
        case 0x58465342: /* XFS */
        case 0x9123683e: /* Btrfs */
        case 0x794c7630: /* overlay */
        case 0x2fc12fc1: /* ZFS */
        case 0x858458f6: /* ramfs */
            return 1;
        default:
            return 0;
    }
}

int squidra_filesystem_is_local(int fd) {
#if defined(__APPLE__)
    struct statfs filesystem;
    if (fstatfs(fd, &filesystem) != 0) return -1;
    return (filesystem.f_flags & MNT_LOCAL) != 0 ? 1 : 0;
#elif defined(__linux__)
    struct statfs filesystem;
    if (fstatfs(fd, &filesystem) != 0) return -1;
    return squidra_linux_filesystem_type_is_local((uint64_t)(unsigned long)filesystem.f_type);
#else
    (void)fd;
    return 0; /* Unknown platforms fail closed. */
#endif
}
