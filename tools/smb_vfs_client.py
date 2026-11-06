"""One-shot test worker using the installed libsmbclient, with JSON pipe commands."""

import ctypes as c
import ctypes.util
import json
import os
import sys


def main():
    lib = c.CDLL(ctypes.util.find_library("smbclient"), use_errno=True)
    auth_type = c.CFUNCTYPE(
        None,
        c.c_char_p,
        c.c_char_p,
        c.c_void_p,
        c.c_int,
        c.c_void_p,
        c.c_int,
        c.c_void_p,
        c.c_int,
    )

    @auth_type
    def auth(server, share, group, group_len, user, user_len, password, password_len):
        for pointer, length in (
            (group, group_len),
            (user, user_len),
            (password, password_len),
        ):
            if length:
                c.memset(pointer, 0, length)

    lib.smbc_init.argtypes = [auth_type, c.c_int]
    lib.smbc_open.argtypes = [c.c_char_p, c.c_int, c.c_uint]
    lib.smbc_close.argtypes = [c.c_int]
    lib.smbc_lseek.argtypes = [c.c_int, c.c_int64, c.c_int]
    lib.smbc_lseek.restype = c.c_int64
    lib.smbc_read.argtypes = [c.c_int, c.c_void_p, c.c_size_t]
    lib.smbc_read.restype = c.c_ssize_t
    lib.smbc_write.argtypes = [c.c_int, c.c_void_p, c.c_size_t]
    lib.smbc_write.restype = c.c_ssize_t
    lib.smbc_ftruncate.argtypes = [c.c_int, c.c_int64]
    assert lib.smbc_init(auth, 0) == 0
    fd = -1
    for line in sys.stdin:
        request = json.loads(line)
        op = request["op"]
        c.set_errno(0)
        result = {}
        if op == "open":
            assert fd == -1
            fd = lib.smbc_open(sys.argv[1].encode(), request["flags"], 0o666)
            value = fd
        elif op == "close":
            value = lib.smbc_close(fd)
            fd = -1
        elif op == "truncate":
            value = lib.smbc_ftruncate(fd, request["length"])
        else:
            assert op in ("read", "write")
            value = lib.smbc_lseek(fd, request["offset"], os.SEEK_SET)
            if value >= 0:
                if op == "write":
                    data = bytes.fromhex(request["hex"])
                    value = lib.smbc_write(fd, data, len(data))
                else:
                    data = c.create_string_buffer(request["length"])
                    value = lib.smbc_read(fd, data, len(data))
                    if value >= 0:
                        result["hex"] = data.raw[:value].hex()
        result.update(errno=c.get_errno() if value < 0 else 0, value=value)
        print(json.dumps(result), flush=True)
    if fd >= 0:
        lib.smbc_close(fd)


if __name__ == "__main__":
    main()
