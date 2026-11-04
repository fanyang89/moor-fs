#define FUSE_USE_VERSION 35
#define _FILE_OFFSET_BITS 64
#include <fuse_lowlevel.h>
#include <stdio.h>

int main(void) {
    struct fuse_lowlevel_ops operations = {0};
    printf("libfuse %s; low-level operations: %zu bytes\n",
           fuse_pkgversion(), sizeof(operations));
    return fuse_version() >= 300 ? 0 : 1;
}
