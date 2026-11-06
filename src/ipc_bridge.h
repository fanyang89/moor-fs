/* Local synchronous IPC ABI for the Samba adapter. Return values are errno codes. */
#ifndef NAS_FS_IPC_BRIDGE_H
#define NAS_FS_IPC_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
struct nas_ipc;
#define NAS_MAX_PATH_GUARDS 32
struct nas_attr {
    uint64_t inode, parent, size;
    int directory;
    char name[256];
};
struct nas_page {
    struct nas_attr entries[16];
    size_t count;
    char next[256];
};
int nas_ipc_connect(const char *, struct nas_ipc **);
void nas_ipc_disconnect(struct nas_ipc *);
int nas_ipc_stat(struct nas_ipc *, uint64_t, struct nas_attr *);
int nas_ipc_lookup(struct nas_ipc *, uint64_t, const char *, struct nas_attr *);
int nas_ipc_list(struct nas_ipc *, uint64_t, const char *, struct nas_page *);
int nas_ipc_open(struct nas_ipc *, uint64_t, uint64_t *);
int nas_ipc_open_write(struct nas_ipc *, uint64_t, uint64_t *);
int nas_ipc_open_guarded(struct nas_ipc *, const struct nas_attr *, int, const struct nas_attr *, size_t, uint64_t *);
int nas_ipc_create_file(struct nas_ipc *, uint64_t, const char *, uint64_t, uint64_t *);
int nas_ipc_mkdir(struct nas_ipc *, uint64_t, const char *, uint64_t, uint64_t *);
int nas_ipc_rename(struct nas_ipc *, uint64_t, uint64_t, const char *, uint64_t);
int nas_ipc_remove(struct nas_ipc *, uint64_t, uint64_t);
int nas_ipc_rename_checked(struct nas_ipc *, const struct nas_attr *, uint64_t, const char *, uint64_t);
int nas_ipc_remove_checked(struct nas_ipc *, const struct nas_attr *, uint64_t);
int nas_ipc_rename_guarded(struct nas_ipc *, const struct nas_attr *, uint64_t, const char *, const struct nas_attr *, size_t, uint64_t);
int nas_ipc_remove_guarded(struct nas_ipc *, const struct nas_attr *, const struct nas_attr *, size_t, uint64_t);
int nas_ipc_create_guarded(struct nas_ipc *, uint64_t, const char *, int, const struct nas_attr *, size_t, uint64_t, uint64_t *);
int nas_ipc_create_open(struct nas_ipc *, uint64_t, const char *, int, const struct nas_attr *, size_t, uint64_t, uint64_t *, uint64_t *);
int nas_ipc_read(struct nas_ipc *, uint64_t, uint64_t, void *, size_t, size_t *);
int nas_ipc_write(struct nas_ipc *, uint64_t, uint64_t, const void *, size_t);
int nas_ipc_truncate(struct nas_ipc *, uint64_t, uint64_t);
int nas_ipc_sync(struct nas_ipc *, uint64_t);
int nas_ipc_close(struct nas_ipc *, uint64_t);
#endif
