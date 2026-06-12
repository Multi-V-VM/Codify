// Exercises the WASI sysroot provided by the CodifyOne wasm runtime:
// working directory, relative and absolute file I/O, /tmp, /etc, HOME and
// argument passing. Exits non-zero on the first failure so it can be used
// as a smoke test for the runtime's filesystem setup.
//
// Build: clang --target=wasm32-wasi --sysroot=$WASI_SYSROOT sysroot_test.c -o sysroot_test.wasm
// Run inside the app: ./sysroot_test.wasm arg1 arg2

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;

static void check(const char *name, int ok, const char *detail) {
    printf("[%s] %s%s%s\n", ok ? "PASS" : "FAIL", name,
           detail ? ": " : "", detail ? detail : "");
    if (!ok) failures++;
}

int main(int argc, char *argv[]) {
    char buf[4096];

    check("getcwd", getcwd(buf, sizeof(buf)) != NULL, buf);

    // Relative write + read back in the working directory
    FILE *f = fopen("sysroot_test.out", "w");
    int ok = f != NULL;
    if (ok) {
        fputs("hello sysroot\n", f);
        fclose(f);
        f = fopen("sysroot_test.out", "r");
        ok = f != NULL && fgets(buf, sizeof(buf), f) != NULL
            && strcmp(buf, "hello sysroot\n") == 0;
        if (f) fclose(f);
        remove("sysroot_test.out");
    }
    check("relative file I/O", ok, NULL);

    // /tmp must be writable
    f = fopen("/tmp/sysroot_test.tmp", "w");
    ok = f != NULL;
    if (ok) {
        fputs("tmp\n", f);
        fclose(f);
        remove("/tmp/sysroot_test.tmp");
    }
    check("/tmp writable", ok, NULL);

    // /etc/passwd must exist and be readable
    f = fopen("/etc/passwd", "r");
    ok = f != NULL && fgets(buf, sizeof(buf), f) != NULL;
    if (f) fclose(f);
    check("/etc/passwd readable", ok, ok ? buf : NULL);

    const char *home = getenv("HOME");
    check("HOME set", home != NULL, home);

    snprintf(buf, sizeof(buf), "argc=%d argv[0]=%s", argc, argv[0]);
    check("arguments", argc >= 1, buf);

    printf("%s\n", failures == 0 ? "ALL TESTS PASSED" : "TESTS FAILED");
    return failures == 0 ? 0 : 1;
}
