#define FUSE_USE_VERSION FUSE_MAKE_VERSION(3, 12)
#include <fuse_lowlevel.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct entry { uint64_t id, parent, size; int directory; char name[256]; };
struct api {
    void *context;
    int (*get)(void *, uint64_t, const char *, struct entry *);
    int (*list)(void *, uint64_t, struct entry **, size_t *);
    void (*free)(struct entry *, size_t);
    int (*open)(void *, uint64_t, struct entry *, int *);
    int writable;
    int wal;
    int (*prepare)(void *, uint64_t, int, struct entry *, void **);
    int (*commit)(void *);
    int (*write)(void *, const char *, size_t, uint64_t, uint64_t *);
    int (*truncate)(void *, uint64_t);
    int (*read)(void *, char *, size_t, uint64_t);
    void (*close_writer)(void *);
    int (*size)(void *, uint64_t *);
    int (*create)(void *, uint64_t, const char *, int, struct entry *);
    int (*remove)(void *, uint64_t, const char *, int);
    int (*rename)(void *, uint64_t, const char *, uint64_t, const char *);
};
struct handle {
    struct entry *entries;
    size_t count;
    int fd;
    struct entry node;
    int writable, failed;
    void *writer;
    struct handle *next;
};
struct state { const struct api *api; struct handle *handles; size_t count; };

static void attr(const struct entry *e, struct stat *st, int writable) {
    memset(st, 0, sizeof(*st));
    st->st_ino = e->id;
    st->st_mode = e->directory ? S_IFDIR | (writable ? 0755 : 0555) : S_IFREG | (writable ? 0644 : 0444);
    st->st_nlink = e->directory ? 2 : 1;
    st->st_uid = getuid();
    st->st_gid = getgid();
    st->st_size = (off_t)e->size;
}

static void lookup(fuse_req_t req, fuse_ino_t parent, const char *name) {
    struct state *s = fuse_req_userdata(req);
    struct entry node;
    int err = s->api->get(s->api->context, parent, name, &node);
    if (err) { fuse_reply_err(req, err); return; }
    struct fuse_entry_param e = {0};
    e.ino = node.id;
    e.generation = 1;
    attr(&node, &e.attr, s->api->writable);
    fuse_reply_entry(req, &e);
}

static void getattr_cb(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
    struct state *s = fuse_req_userdata(req);
    struct entry node;
    struct handle *h = fi ? (void *)(uintptr_t)fi->fh : NULL;
    if (h && (h->fd >= 0 || h->writer)) {
        if (s->api->wal && h->writer) {
            int err = s->api->size(h->writer, &h->node.size);
            if (err) { h->failed = err; fuse_reply_err(req, err); return; }
        }
        node = h->node;
    } else {
        int err = s->api->get(s->api->context, ino, NULL, &node);
        if (err) { fuse_reply_err(req, err); return; }
    }
    struct stat st;
    attr(&node, &st, s->api->writable);
    fuse_reply_attr(req, &st, 0);
}

static void release_handle(struct state *s, struct handle *h) {
    struct handle **p = &s->handles;
    while (*p && *p != h) p = &(*p)->next;
    if (!*p) return;
    *p = h->next;
    if (h->writer) s->api->close_writer(h->writer);
    else if (h->fd >= 0) close(h->fd);
    else s->api->free(h->entries, h->count);
    free(h);
    s->count--;
}

static void opendir_cb(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
    struct state *s = fuse_req_userdata(req);
    if (s->count >= 64) { fuse_reply_err(req, EMFILE); return; }
    struct handle *h = calloc(1, sizeof(*h));
    if (!h) { fuse_reply_err(req, ENOMEM); return; }
    h->fd = -1;
    int err = s->api->list(s->api->context, ino, &h->entries, &h->count);
    if (err) { free(h); fuse_reply_err(req, err); return; }
    h->next = s->handles;
    s->handles = h;
    s->count++;
    fi->fh = (uint64_t)(uintptr_t)h;
    if (fuse_reply_open(req, fi) != 0) release_handle(s, h);
}

static void readdir_cb(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, struct fuse_file_info *fi) {
    (void)ino;
    struct handle *h = (void *)(uintptr_t)fi->fh;
    if (off < 0 || (uint64_t)off > h->count) { fuse_reply_err(req, EINVAL); return; }
    if (size > 1024 * 1024) size = 1024 * 1024;
    char *buffer = malloc(size ? size : 1);
    if (!buffer) { fuse_reply_err(req, ENOMEM); return; }
    size_t used = 0;
    for (size_t i = (size_t)off; i < h->count; i++) {
        struct stat st;
        struct state *s = fuse_req_userdata(req);
        attr(&h->entries[i], &st, s->api->writable);
        size_t length = fuse_add_direntry(req, buffer + used, size - used, h->entries[i].name, &st, (off_t)i + 1);
        if (length > size - used) break;
        used += length;
    }
    fuse_reply_buf(req, buffer, used);
    free(buffer);
}

static void releasedir_cb(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
    (void)ino;
    release_handle(fuse_req_userdata(req), (void *)(uintptr_t)fi->fh);
    fuse_reply_err(req, 0);
}

static int save(struct state *s, struct handle *h) {
    if (h->failed) return h->failed;
    if (h->writer) h->failed = s->api->commit(h->writer);
    // An uncertain publication freezes the handle. Never mutate or republish it.
    return h->failed;
}

static int make_handle(struct state *s, fuse_ino_t ino, int writable, int truncate, struct handle **out) {
    if (writable && !s->api->writable) return EROFS;
    if (s->count >= 64) return EMFILE;
    for (struct handle *p = s->handles; writable && p; p = p->next)
        if (p->writable && p->node.id == ino) return EBUSY;
    struct handle *h = calloc(1, sizeof(*h));
    if (!h) return ENOMEM;
    h->fd = -1;
    h->writable = writable;
    int err;
    if (writable || s->api->wal) {
        err = s->api->prepare(s->api->context, ino, truncate, &h->node, &h->writer);
    } else {
        err = s->api->open(s->api->context, ino, &h->node, &h->fd);
    }
    if (err) { if (h->fd >= 0) close(h->fd); free(h); return err; }
    h->next = s->handles;
    s->handles = h;
    s->count++;
    *out = h;
    return 0;
}

static void open_cb(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
    struct state *s = fuse_req_userdata(req);
    if ((fi->flags & O_TRUNC) && (fi->flags & O_ACCMODE) == O_RDONLY) {
        fuse_reply_err(req, EACCES); return;
    }
    struct handle *h;
    int err = make_handle(s, ino, (fi->flags & O_ACCMODE) != O_RDONLY, !!(fi->flags & O_TRUNC), &h);
    if (err) { fuse_reply_err(req, err); return; }
    if (fi->flags & O_TRUNC) {
        if (!h->writable) err = EACCES;
        else if (fi->flags & (O_SYNC | O_DSYNC)) err = save(s, h);
        if (err) { release_handle(s, h); fuse_reply_err(req, err); return; }
    }
    fi->fh = (uint64_t)(uintptr_t)h;
    // Kernel page cache is inode-scoped; two open handles may pin different versions.
    fi->direct_io = 1;
    fi->keep_cache = 0;
    if (fuse_reply_open(req, fi) != 0) release_handle(s, h);
}

static void read_cb(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, struct fuse_file_info *fi) {
    (void)ino;
    struct handle *h = (void *)(uintptr_t)fi->fh;
    if (h->failed) { fuse_reply_err(req, h->failed); return; }
    if (off < 0) { fuse_reply_err(req, EINVAL); return; }
    struct state *s = fuse_req_userdata(req);
    if (s->api->wal && h->writer) {
        int err = s->api->size(h->writer, &h->node.size);
        if (err) { h->failed = err; fuse_reply_err(req, err); return; }
    }
    if ((uint64_t)off >= h->node.size || size == 0) { fuse_reply_buf(req, NULL, 0); return; }
    if (size > 1024 * 1024) size = 1024 * 1024;
    if (size > h->node.size - (uint64_t)off) size = h->node.size - (uint64_t)off;
    char *buffer = malloc(size);
    if (!buffer) { fuse_reply_err(req, ENOMEM); return; }
    if (h->writer) {
        int err = s->api->read(h->writer, buffer, size, (uint64_t)off);
        if (err) { h->failed = err; fuse_reply_err(req, err); }
        else fuse_reply_buf(req, buffer, size);
        free(buffer);
        return;
    }
    size_t used = 0;
    while (used < size) {
        ssize_t n = pread(h->fd, buffer + used, size - used, off + (off_t)used);
        if (n < 0 && errno == EINTR) continue;
        // A premature EOF means the supposedly immutable object was truncated.
        if (n <= 0) { free(buffer); fuse_reply_err(req, EIO); return; }
        used += (size_t)n;
    }
    fuse_reply_buf(req, buffer, used);
    free(buffer);
}

static void write_cb(fuse_req_t req, fuse_ino_t ino, const char *buffer, size_t size, off_t off, struct fuse_file_info *fi) {
    (void)ino;
    struct state *s = fuse_req_userdata(req);
    struct handle *h = (void *)(uintptr_t)fi->fh;
    if (!h->writable) { fuse_reply_err(req, EBADF); return; }
    if (h->failed) { fuse_reply_err(req, h->failed); return; }
    if (off < 0 || size > INT64_MAX - (uint64_t)off) { fuse_reply_err(req, EFBIG); return; }
    h->failed = s->api->write(h->writer, buffer, size, (uint64_t)off, &h->node.size);
    int err = h->failed;
    if (!err && size && (fi->flags & (O_SYNC | O_DSYNC))) err = save(s, h);
    if (err) fuse_reply_err(req, err);
    else fuse_reply_write(req, size);
}

static void flush_cb(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
    (void)ino;
    struct handle *h = (void *)(uintptr_t)fi->fh;
    fuse_reply_err(req, save(fuse_req_userdata(req), h));
}

static void fsync_cb(fuse_req_t req, fuse_ino_t ino, int datasync, struct fuse_file_info *fi) {
    (void)datasync;
    flush_cb(req, ino, fi);
}

static void release_cb(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
    (void)ino;
    struct state *s = fuse_req_userdata(req);
    struct handle *h = (void *)(uintptr_t)fi->fh;
    int err = save(s, h);
    release_handle(s, h);
    fuse_reply_err(req, err);
}

static void setattr_cb(fuse_req_t req, fuse_ino_t ino, struct stat *st, int changes, struct fuse_file_info *fi) {
    struct state *s = fuse_req_userdata(req);
    if (!s->api->writable) { fuse_reply_err(req, EROFS); return; }
    // Ownership, modes and persistent timestamps are not yet part of the metadata model.
    if (changes & ~FUSE_SET_ATTR_SIZE) { fuse_reply_err(req, EOPNOTSUPP); return; }
    if (!(changes & FUSE_SET_ATTR_SIZE)) { getattr_cb(req, ino, fi); return; }
    if (st->st_size < 0) { fuse_reply_err(req, EINVAL); return; }
    struct handle *h = fi ? (void *)(uintptr_t)fi->fh : NULL;
    int temporary = !h;
    int err = temporary ? make_handle(s, ino, 1, st->st_size == 0, &h) : 0;
    if (!err && !h->writable) err = EBADF;
    if (!err) err = h->failed;
    if (!err) err = h->failed = s->api->truncate(h->writer, (uint64_t)st->st_size);
    if (!err) h->node.size = (uint64_t)st->st_size;
    if (!err && (temporary || (fi->flags & (O_SYNC | O_DSYNC)))) err = save(s, h);
    struct stat result;
    if (!err) attr(&h->node, &result, 1);
    if (temporary && h) release_handle(s, h);
    if (err) fuse_reply_err(req, err);
    else fuse_reply_attr(req, &result, 0);
}

static void create_cb(fuse_req_t req, fuse_ino_t parent, const char *name, mode_t mode, struct fuse_file_info *fi) {
    (void)mode;
    struct state *s = fuse_req_userdata(req);
    if (!s->api->writable) { fuse_reply_err(req, EROFS); return; }
    if (s->count >= 64) { fuse_reply_err(req, EMFILE); return; }
    struct entry node;
    int err = s->api->create(s->api->context, parent, name, 0, &node);
    struct handle *h = NULL;
    if (!err) err = make_handle(s, node.id, 1, 1, &h);
    if (!err && (fi->flags & (O_SYNC | O_DSYNC))) err = save(s, h);
    if (err) { if (h) release_handle(s, h); fuse_reply_err(req, err); return; }
    struct fuse_entry_param e = {0};
    e.ino = node.id;
    e.generation = 1;
    attr(&node, &e.attr, 1);
    fi->fh = (uint64_t)(uintptr_t)h;
    fi->direct_io = 1;
    if (fuse_reply_create(req, &e, fi) != 0) release_handle(s, h);
}

static void mkdir_cb(fuse_req_t req, fuse_ino_t parent, const char *name, mode_t mode) {
    (void)mode;
    struct state *s = fuse_req_userdata(req);
    struct entry node;
    int err = s->api->create(s->api->context, parent, name, 1, &node);
    if (err) { fuse_reply_err(req, err); return; }
    struct fuse_entry_param e = {0};
    e.ino = node.id;
    e.generation = 1;
    attr(&node, &e.attr, 1);
    fuse_reply_entry(req, &e);
}

static void unlink_cb(fuse_req_t req, fuse_ino_t parent, const char *name) {
    struct state *s = fuse_req_userdata(req);
    fuse_reply_err(req, s->api->remove(s->api->context, parent, name, 0));
}

static void rmdir_cb(fuse_req_t req, fuse_ino_t parent, const char *name) {
    struct state *s = fuse_req_userdata(req);
    fuse_reply_err(req, s->api->remove(s->api->context, parent, name, 1));
}

static void rename_cb(fuse_req_t req, fuse_ino_t parent, const char *name, fuse_ino_t new_parent, const char *new_name, unsigned int flags) {
    struct state *s = fuse_req_userdata(req);
    if (flags & ~RENAME_NOREPLACE) { fuse_reply_err(req, EOPNOTSUPP); return; }
    // Like metadata rename, this prototype rejects replacement of an existing target.
    fuse_reply_err(req, s->api->rename(s->api->context, parent, name, new_parent, new_name));
}

int nas_fuse_run(const char *path, const struct api *api) {
    char *argv[] = { "nas-fs", "-o", api->writable ? "default_permissions,fsname=nas-fs" : "ro,default_permissions,fsname=nas-fs" };
    struct fuse_args args = FUSE_ARGS_INIT(3, argv);
    struct state state = { .api = api };
    const struct fuse_lowlevel_ops ops = {
        .lookup = lookup, .getattr = getattr_cb, .opendir = opendir_cb,
        .readdir = readdir_cb, .releasedir = releasedir_cb, .open = open_cb,
        .read = read_cb, .release = release_cb,
        .write = write_cb, .flush = flush_cb, .fsync = fsync_cb, .setattr = setattr_cb,
        .create = create_cb, .mkdir = mkdir_cb, .unlink = unlink_cb, .rmdir = rmdir_cb, .rename = rename_cb,
    };
    struct fuse_session *session = fuse_session_new(&args, &ops, sizeof(ops), &state);
    int result = -1;
    if (!session) goto done;
    if (fuse_set_signal_handlers(session) != 0) goto destroy;
    if (fuse_session_mount(session, path) != 0) goto signals;
    result = fuse_session_loop(session);
    if (result == SIGINT || result == SIGTERM) result = 0;
    fuse_session_unmount(session);
signals:
    fuse_remove_signal_handlers(session);
destroy:
    fuse_session_destroy(session);
    while (state.handles) release_handle(&state, state.handles);
done:
    fuse_opt_free_args(&args);
    return result;
}
