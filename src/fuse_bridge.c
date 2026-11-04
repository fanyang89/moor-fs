#define FUSE_USE_VERSION FUSE_MAKE_VERSION(3, 12)
#include <fuse_lowlevel.h>
#include <errno.h>
#include <stdint.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct entry { uint64_t id, parent; int directory; char name[256]; };
struct api {
    void *context;
    int (*get)(void *, uint64_t, const char *, struct entry *);
    int (*list)(void *, uint64_t, struct entry **, size_t *);
    void (*free)(struct entry *, size_t);
};
struct handle { struct entry *entries; size_t count; struct handle *next; };
struct state { const struct api *api; struct handle *handles; size_t count; };

static void attr(const struct entry *e, struct stat *st) {
    memset(st, 0, sizeof(*st));
    st->st_ino = e->id;
    st->st_mode = e->directory ? S_IFDIR | 0555 : S_IFREG | 0444;
    st->st_nlink = e->directory ? 2 : 1;
    st->st_uid = getuid();
    st->st_gid = getgid();
}

static void lookup(fuse_req_t req, fuse_ino_t parent, const char *name) {
    struct state *s = fuse_req_userdata(req);
    struct entry node;
    int err = s->api->get(s->api->context, parent, name, &node);
    if (err) { fuse_reply_err(req, err); return; }
    struct fuse_entry_param e = {0};
    e.ino = node.id;
    e.generation = 1;
    attr(&node, &e.attr);
    fuse_reply_entry(req, &e);
}

static void getattr_cb(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
    (void)fi;
    struct state *s = fuse_req_userdata(req);
    struct entry node;
    int err = s->api->get(s->api->context, ino, NULL, &node);
    if (err) { fuse_reply_err(req, err); return; }
    struct stat st;
    attr(&node, &st);
    fuse_reply_attr(req, &st, 0);
}

static void release_handle(struct state *s, struct handle *h) {
    struct handle **p = &s->handles;
    while (*p && *p != h) p = &(*p)->next;
    if (!*p) return;
    *p = h->next;
    s->api->free(h->entries, h->count);
    free(h);
    s->count--;
}

static void opendir_cb(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
    struct state *s = fuse_req_userdata(req);
    if (s->count >= 64) { fuse_reply_err(req, EMFILE); return; }
    struct handle *h = calloc(1, sizeof(*h));
    if (!h) { fuse_reply_err(req, ENOMEM); return; }
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
        attr(&h->entries[i], &st);
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

static void open_cb(fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi) {
    (void)ino;
    (void)fi;
    fuse_reply_err(req, EOPNOTSUPP);
}

int nas_fuse_run(const char *path, const struct api *api) {
    char *argv[] = { "nas-fs", "-o", "ro,default_permissions,fsname=nas-fs" };
    struct fuse_args args = FUSE_ARGS_INIT(3, argv);
    struct state state = { .api = api };
    const struct fuse_lowlevel_ops ops = {
        .lookup = lookup, .getattr = getattr_cb, .opendir = opendir_cb,
        .readdir = readdir_cb, .releasedir = releasedir_cb, .open = open_cb,
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
