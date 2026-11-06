/* SPDX-License-Identifier: GPL-3.0-or-later
 * Read-only opaque Samba 4.25.1 adapter. The pinned upstream opaque skeleton
 * supplies explicit unsupported operations, never local-filesystem fallbacks.
 */
#include "includes.h"
#include "smbd/smbd.h"
#include "ipc_bridge.h"
#include "../third_party/samba/examples/VFS/skel_opaque.c"

struct nas_file { uint64_t inode, handle; };
struct nas_dir {
    struct nas_ipc *client;
    uint64_t inode;
    struct nas_page page;
    size_t index;
    bool loaded, end;
    struct dirent entry;
};

static int nas_error(int error)
{
    if (error == 0) return 0;
    errno = error;
    return -1;
}

static void nas_free(void **data)
{
    if (*data != NULL) nas_ipc_disconnect(*data);
    *data = NULL;
}

static int nas_connect(struct vfs_handle_struct *h, const char *service, const char *user)
{
    struct nas_ipc *client = NULL;
    const char *path = lp_parm_const_string(SNUM(h->conn), "nas_fs", "socket", NULL);
    if (!path || !lp_read_only(SNUM(h->conn)) || lp_smb2_leases() || lp_oplocks(SNUM(h->conn))) return nas_error(EINVAL);
    if (nas_error(nas_ipc_connect(path, &client)) != 0) return -1;
    SMB_VFS_HANDLE_SET_DATA(h, client, nas_free, struct nas_ipc, return -1);
    return 0;
}

static void nas_disconnect(struct vfs_handle_struct *h)
{
    if (h->data != NULL) nas_free(&h->data);
}

static void nas_stat_value(const struct nas_attr *a, SMB_STRUCT_STAT *st)
{
    ZERO_STRUCTP(st);
    st->st_ex_dev = 0x4e4153;
    st->st_ex_ino = a->inode;
    st->st_ex_mode = (a->directory ? S_IFDIR | 0555 : S_IFREG | 0444);
    st->st_ex_nlink = a->directory ? 2 : 1;
    st->st_ex_uid = getuid();
    st->st_ex_gid = getgid();
    st->st_ex_size = a->size;
    st->st_ex_blksize = 65536;
    st->st_ex_blocks = (a->size + 511) / 512;
    /* Metadata does not yet persist timestamps. Use a stable synthetic epoch. */
    st->st_ex_atime.tv_sec = st->st_ex_mtime.tv_sec = 1704067200;
    st->st_ex_ctime.tv_sec = st->st_ex_btime.tv_sec = 1704067200;
}

static uint64_t nas_inode(struct vfs_handle_struct *h, const struct files_struct *fsp)
{
    struct nas_file *file = fsp ? VFS_FETCH_FSP_EXTENSION(h, fsp) : NULL;
    return file ? file->inode : 1;
}

/* No symlinks exist in the core. Paths are component-walked, bounded, and never
 * interpreted by the host filesystem. The share root is the virtual '/'. */
static int nas_resolve(struct vfs_handle_struct *h, uint64_t base, const char *path, struct nas_attr *out)
{
    char *copy, *save = NULL, *part;
    int error;
    if (strlen(path) > 4096) return nas_error(ENAMETOOLONG);
    if (path[0] == '/') base = 1;
    error = nas_ipc_stat(h->data, base, out);
    if (error) return nas_error(error);
    copy = talloc_strdup(talloc_tos(), path);
    if (!copy) return nas_error(ENOMEM);
    for (part = strtok_r(copy, "/", &save); part; part = strtok_r(NULL, "/", &save)) {
        if (!out->directory) { error = ENOTDIR; break; }
        if (strcmp(part, ".") == 0) continue;
        if (strcmp(part, "..") == 0) {
            error = nas_ipc_stat(h->data, out->parent ? out->parent : 1, out);
        } else {
            error = nas_ipc_lookup(h->data, out->inode, part, out);
        }
        if (error) break;
    }
    TALLOC_FREE(copy);
    return nas_error(error);
}

static int nas_stat(struct vfs_handle_struct *h, struct smb_filename *name)
{
    struct nas_attr attr;
    if (name->stream_name) return nas_error(ENOENT);
    if (nas_resolve(h, nas_inode(h, h->conn->cwd_fsp), name->base_name, &attr)) return -1;
    nas_stat_value(&attr, &name->st);
    return 0;
}

static int nas_fstat(struct vfs_handle_struct *h, struct files_struct *fsp, SMB_STRUCT_STAT *st)
{
    struct nas_attr attr;
    if (nas_error(nas_ipc_stat(h->data, nas_inode(h, fsp), &attr))) return -1;
    nas_stat_value(&attr, st);
    return 0;
}

static int nas_fstatat(struct vfs_handle_struct *h, const struct files_struct *dir,
                      const struct smb_filename *name, SMB_STRUCT_STAT *st, int flags)
{
    struct nas_attr attr;
    if (name->stream_name) return nas_error(ENOENT);
    if (nas_resolve(h, nas_inode(h, dir), name->base_name, &attr)) return -1;
    nas_stat_value(&attr, st);
    return 0;
}

static int nas_share_root(struct vfs_handle_struct *h, struct files_struct *root, const char *path)
{
    struct nas_attr attr;
    SMB_STRUCT_STAT st;
    if (strcmp(path, "/") != 0) return nas_error(EINVAL);
    if (nas_error(nas_ipc_stat(h->data, 1, &attr))) return -1;
    nas_stat_value(&attr, &st);
    return vfs_set_share_root(root, path, &st);
}

static int nas_openat(struct vfs_handle_struct *h, const struct files_struct *dir,
                      const struct smb_filename *name, struct files_struct *fsp,
                      const struct vfs_open_how *how)
{
    struct nas_attr attr;
    struct nas_file *file;
    int fd, error;
    uint64_t opened = 0;
    if ((how->resolve & ~(VFS_OPEN_HOW_WITH_BACKUP_INTENT | VFS_OPEN_HOW_RESOLVE_NO_XDEV)) != 0) return nas_error(ENOTSUP);
    if (name->stream_name) return nas_error(ENOENT);
    if ((how->flags & O_ACCMODE) != O_RDONLY || (how->flags & (O_CREAT | O_TRUNC))) return nas_error(EROFS);
    if (nas_resolve(h, nas_inode(h, dir), name->base_name, &attr)) return -1;
    if ((how->flags & O_DIRECTORY) && !attr.directory) return nas_error(ENOTDIR);
    if (!attr.directory && !fsp->fsp_flags.is_pathref) {
        if (nas_error(nas_ipc_open(h->data, attr.inode, &opened))) return -1;
    }
    /* Samba requires an fd identity. It is never used for namespace or data. */
    fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (fd == -1) { if (opened) nas_ipc_close(h->data, opened); return -1; }
    file = VFS_ADD_FSP_EXTENSION(h, fsp, struct nas_file, NULL);
    if (!file) {
        error = ENOMEM;
        close(fd);
        if (opened) nas_ipc_close(h->data, opened);
        return nas_error(error);
    }
    file->inode = attr.inode;
    file->handle = opened;
    fsp->fsp_flags.have_proc_fds = false;
    return fd;
}

static int nas_close(struct vfs_handle_struct *h, struct files_struct *fsp)
{
    struct nas_file *file = VFS_FETCH_FSP_EXTENSION(h, fsp);
    int error = 0;
    if (file && file->handle) error = nas_ipc_close(h->data, file->handle);
    if (close(fsp_get_pathref_fd(fsp)) != 0 && !error) error = errno;
    VFS_REMOVE_FSP_EXTENSION(h, fsp);
    return nas_error(error);
}

static ssize_t nas_pread(struct vfs_handle_struct *h, struct files_struct *fsp,
                        void *data, size_t length, off_t offset)
{
    struct nas_file *file = VFS_FETCH_FSP_EXTENSION(h, fsp);
    size_t done = 0;
    if (!file || !file->handle) return nas_error(EBADF);
    if (offset < 0 || length > (uint64_t)INT64_MAX - offset) return nas_error(EINVAL);
    while (done < length) {
        size_t count = 0, wanted = MIN(length - done, 65536);
        int error = nas_ipc_read(h->data, file->handle, offset + done,
                                 (char *)data + done, wanted, &count);
        if (error) return nas_error(error);
        done += count;
        if (count < wanted) break;
    }
    return done;
}

static int nas_fcntl(struct vfs_handle_struct *h, struct files_struct *fsp, int command, va_list args)
{
    int fd = fsp_get_pathref_fd(fsp);
    switch (command) {
    case F_GETFL: case F_GETFD:
        return fcntl(fd, command);
    case F_SETFL: case F_SETFD:
        return fcntl(fd, command, va_arg(args, int));
    default:
        return nas_error(ENOTSUP);
    }
}

struct nas_read_state { ssize_t count; struct vfs_aio_state aio; };
static struct tevent_req *nas_pread_send(struct vfs_handle_struct *h, TALLOC_CTX *ctx,
    struct tevent_context *ev, struct files_struct *fsp, void *data, size_t n, off_t offset)
{
    struct nas_read_state *state;
    struct tevent_req *req = tevent_req_create(ctx, &state, struct nas_read_state);
    if (!req) return NULL;
    state->count = nas_pread(h, fsp, data, n, offset);
    state->aio.error = state->count < 0 ? errno : 0;
    tevent_req_done(req);
    return tevent_req_post(req, ev);
}
static ssize_t nas_pread_recv(struct tevent_req *req, struct vfs_aio_state *aio)
{
    struct nas_read_state *state = tevent_req_data(req, struct nas_read_state);
    ssize_t count = state->count;
    *aio = state->aio;
    tevent_req_received(req);
    return count;
}

static DIR *nas_fdopendir(struct vfs_handle_struct *h, struct files_struct *fsp, const char *mask, uint32_t attrs)
{
    struct nas_dir *dir = talloc_zero(NULL, struct nas_dir);
    if (!dir) { errno = ENOMEM; return NULL; }
    dir->client = h->data;
    dir->inode = nas_inode(h, fsp);
    return (DIR *)dir;
}
static struct dirent *nas_readdir(struct vfs_handle_struct *h, struct files_struct *fsp, DIR *opaque)
{
    struct nas_dir *dir = (struct nas_dir *)opaque;
    struct nas_attr *attr;
    if (dir->end) { errno = 0; return NULL; }
    if (!dir->loaded || dir->index == dir->page.count) {
        char cursor[256] = {0};
        int error;
        if (dir->loaded) {
            if (!dir->page.next[0]) { dir->end = true; errno = 0; return NULL; }
            memcpy(cursor, dir->page.next, sizeof(cursor));
        }
        error = nas_ipc_list(dir->client, dir->inode, cursor, &dir->page);
        if (error) { errno = error; return NULL; }
        dir->loaded = true;
        dir->index = 0;
        if (!dir->page.count) { dir->end = true; errno = 0; return NULL; }
    }
    attr = &dir->page.entries[dir->index++];
    ZERO_STRUCT(dir->entry);
    dir->entry.d_ino = attr->inode;
    dir->entry.d_type = attr->directory ? DT_DIR : DT_REG;
    memcpy(dir->entry.d_name, attr->name, strlen(attr->name) + 1);
    return &dir->entry;
}
static void nas_rewind(struct vfs_handle_struct *h, DIR *opaque)
{
    struct nas_dir *dir = (struct nas_dir *)opaque;
    dir->loaded = dir->end = false;
    dir->index = 0;
}
static int nas_closedir(struct vfs_handle_struct *h, DIR *opaque)
{
    talloc_free(opaque);
    return 0;
}
static int nas_chdir(struct vfs_handle_struct *h, const struct smb_filename *name)
{
    struct nas_attr attr;
    if (nas_resolve(h, nas_inode(h, h->conn->cwd_fsp), name->base_name, &attr)) return -1;
    return attr.directory ? 0 : nas_error(ENOTDIR);
}
static struct smb_filename *nas_realpath(struct vfs_handle_struct *h, TALLOC_CTX *ctx, const struct smb_filename *name)
{
    const char *cwd = h->conn->cwd_fsp ? h->conn->cwd_fsp->fsp_name->base_name : "/";
    char *path = name->base_name[0] == '/' ? talloc_strdup(ctx, name->base_name) :
        talloc_asprintf(ctx, "%s/%s", cwd, name->base_name);
    struct smb_filename *result;
    if (!path) return NULL;
    result = cp_smb_basename(ctx, path);
    TALLOC_FREE(path);
    return result;
}
static uint64_t nas_disk_free(struct vfs_handle_struct *h, struct files_struct *fsp,
    uint64_t *bsize, uint64_t *dfree, uint64_t *dsize)
{
    *bsize = 4096; *dfree = 0; *dsize = 1;
    return 0;
}
static uint32_t nas_capabilities(struct vfs_handle_struct *h, enum timestamp_set_resolution *resolution)
{
    *resolution = TIMESTAMP_SET_SECONDS;
    return FILE_CASE_PRESERVED_NAMES | FILE_UNICODE_ON_DISK;
}

/* These default operations are Samba policy/pure path helpers. Their actual
 * filesystem calls re-enter this opaque module. No backend data is local. */
static NTSTATUS nas_create_file(struct vfs_handle_struct *h, struct smb_request *req,
    struct files_struct *dir, struct smb_filename *name, uint32_t access,
    uint32_t share, uint32_t disposition, uint32_t options, uint32_t attrs,
    uint32_t oplock, const struct smb2_lease *lease, uint64_t allocation,
    uint32_t private_flags, struct security_descriptor *sd, struct ea_list *ea,
    struct files_struct **result, int *info, const struct smb2_create_blobs *in,
    struct smb2_create_blobs *out)
{
    return SMB_VFS_NEXT_CREATE_FILE(h, req, dir, name, access, share, disposition,
        options, attrs, oplock, lease, allocation, private_flags, sd, ea, result, info, in, out);
}
static NTSTATUS nas_parent(struct vfs_handle_struct *h, TALLOC_CTX *ctx,
    const struct smb_filename *name, struct smb_filename **parent, struct smb_filename **base)
{ return SMB_VFS_NEXT_PARENT_PATHNAME(h, ctx, name, parent, base); }
static struct file_id nas_file_id(struct vfs_handle_struct *h, const SMB_STRUCT_STAT *st)
{ return SMB_VFS_NEXT_FILE_ID_CREATE(h, st); }
static uint64_t nas_fs_id(struct vfs_handle_struct *h, const SMB_STRUCT_STAT *st)
{ return st->st_ex_ino; }
static NTSTATUS nas_acl(struct vfs_handle_struct *h, struct files_struct *fsp,
    uint32_t info, TALLOC_CTX *ctx, struct security_descriptor **sd)
{ return SMB_VFS_NEXT_FGET_NT_ACL(h, fsp, info, ctx, sd); }
static bool nas_strict_lock(struct vfs_handle_struct *h, struct files_struct *fsp, struct lock_struct *lock)
{ return SMB_VFS_NEXT_STRICT_LOCK_CHECK(h, fsp, lock); }

static NTSTATUS nas_fget_dos(struct vfs_handle_struct *h, struct files_struct *fsp, uint32_t *mode)
{
    struct nas_attr attr;
    int error = nas_ipc_stat(h->data, nas_inode(h, fsp), &attr);
    if (error) return map_nt_error_from_unix(error);
    *mode = FILE_ATTRIBUTE_READONLY | (attr.directory ? FILE_ATTRIBUTE_DIRECTORY : 0);
    return NT_STATUS_OK;
}
static struct tevent_req *nas_get_dos_send(TALLOC_CTX *ctx, struct tevent_context *ev,
    struct vfs_handle_struct *h, struct files_struct *dir, struct smb_filename *name)
{
    struct skel_get_dos_attributes_state *state;
    struct nas_attr attr;
    struct tevent_req *req = tevent_req_create(ctx, &state, struct skel_get_dos_attributes_state);
    if (!req) return NULL;
    if (nas_resolve(h, nas_inode(h, dir), name->base_name, &attr)) {
        tevent_req_nterror(req, map_nt_error_from_unix(errno));
    } else {
        state->dosmode = FILE_ATTRIBUTE_READONLY | (attr.directory ? FILE_ATTRIBUTE_DIRECTORY : 0);
        tevent_req_done(req);
    }
    return tevent_req_post(req, ev);
}
static NTSTATUS nas_readdir_attr(struct vfs_handle_struct *h, struct files_struct *fsp,
    TALLOC_CTX *ctx, struct readdir_attr_data **out)
{ return NT_STATUS_NOT_SUPPORTED; }
static NTSTATUS nas_translate(struct vfs_handle_struct *h, const char *name,
    enum vfs_translate_direction direction, TALLOC_CTX *ctx, char **out)
{ *out = NULL; return NT_STATUS_NONE_MAPPED; }
static NTSTATUS nas_real_name(struct vfs_handle_struct *h, struct files_struct *dir,
    const char *name, TALLOC_CTX *ctx, char **out)
{
    struct nas_attr attr;
    int error = nas_ipc_lookup(h->data, nas_inode(h, dir), name, &attr);
    if (error) return map_nt_error_from_unix(error);
    *out = talloc_strdup(ctx, attr.name);
    return *out ? NT_STATUS_OK : NT_STATUS_NO_MEMORY;
}

NTSTATUS samba_init_module(TALLOC_CTX *ctx)
{
    struct vfs_fn_pointers *f = &skel_opaque_fns;
    f->connect_fn = nas_connect; f->disconnect_fn = nas_disconnect;
    f->open_share_root_fn = nas_share_root;
    f->stat_fn = nas_stat; f->lstat_fn = nas_stat; f->fstat_fn = nas_fstat; f->fstatat_fn = nas_fstatat;
    f->openat_fn = nas_openat; f->close_fn = nas_close;
    f->fcntl_fn = nas_fcntl;
    f->pread_fn = nas_pread; f->pread_send_fn = nas_pread_send; f->pread_recv_fn = nas_pread_recv;
    f->fdopendir_fn = nas_fdopendir; f->readdir_fn = nas_readdir;
    f->rewind_dir_fn = nas_rewind; f->closedir_fn = nas_closedir;
    f->chdir_fn = nas_chdir; f->realpath_fn = nas_realpath;
    f->disk_free_fn = nas_disk_free; f->fs_capabilities_fn = nas_capabilities;
    f->create_file_fn = nas_create_file; f->parent_pathname_fn = nas_parent;
    f->file_id_create_fn = nas_file_id; f->fs_file_id_fn = nas_fs_id;
    f->fget_nt_acl_fn = nas_acl; f->strict_lock_check_fn = nas_strict_lock;
    f->fget_dos_attributes_fn = nas_fget_dos;
    f->get_dos_attributes_send_fn = nas_get_dos_send;
    f->freaddir_attr_fn = nas_readdir_attr;
    f->translate_name_fn = nas_translate;
    f->get_real_filename_at_fn = nas_real_name;
    smb_vfs_assert_all_fns(f, "nas_fs");
    return smb_register_vfs(SMB_VFS_INTERFACE_VERSION, "nas_fs", f);
}
