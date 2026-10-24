/*
 * vpnrun — VPN Selectivo
 *
 * Launches an allowed program (an app listed in apps.conf) as the given user, but with the
 * dedicated "vpnselectivo" group as its real/effective/saved group. PF matches
 * that group and steers every TCP/UDP socket of the process, and of every child
 * it forks (browser helpers, Stremio's node...), into the Mullvad tunnel.
 *
 * Must be started as root (only vsctl does that); drops privileges before exec.
 *
 * usage: vpnrun <user> <absolute-program-path> [args...]
 *
 * Derived from VPNonly's app-engine/vpnrun.c
 *   Copyright (c) 2026 Kanishk Razdan — MIT License
 *   https://github.com/kanishkdan/vpnonly (commit 50d3627)
 * Changes: fixed group name, program allow-list (apps.conf), keeps the user's
 * supplementary groups (initgroups), new session + /dev/null stdio so the app
 * survives sudo's pty teardown, post-drop verification.
 * See third_party/licenses/VPNonly-engine-MIT.txt.
 */
#include <errno.h>
#include <limits.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define VS_GROUP   "vpnselectivo"
#define VS_GID_MIN 7300
#define VS_GID_MAX 7899

extern char **environ;
/* Exported by libSystem since macOS 10.14 (private header). Weak so a future
   macOS without it still launches; only TCC attribution would change. */
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim)
    __attribute__((weak_import));

/* Tools used only by `vsctl check-ip` / tests. */
static const char *const tools[] = { "/usr/bin/curl", "/usr/bin/dig", NULL };

#define APPS_CONF "/Library/VPNSelectivo/etc/apps.conf"

/* Allowed: a tool above, or "<app>/Contents/MacOS/<file>" for an app listed in
   apps.conf (root-owned, not writable by group/others). No "..", no symlinks
   on the final path, nothing below MacOS/. */
static int program_allowed(const char *prog) {
    for (int i = 0; tools[i]; i++)
        if (strcmp(prog, tools[i]) == 0) return 1;
    if (strstr(prog, "/../") || strstr(prog, "/./")) return 0;
    char real[PATH_MAX];
    if (!realpath(prog, real) || strcmp(real, prog) != 0) return 0;

    int fd = open(APPS_CONF, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != 0 || (st.st_mode & 022)) {
        close(fd); return 0;
    }
    FILE *f = fdopen(fd, "r");
    if (!f) { close(fd); return 0; }
    char line[2048];
    int ok = 0;
    while (!ok && fgets(line, sizeof line, f)) {
        char *hash = strchr(line, '#'); if (hash) *hash = 0;
        /* id | name | path | args  → third field */
        char *p1 = strchr(line, '|'); if (!p1) continue;
        char *p2 = strchr(p1 + 1, '|'); if (!p2) continue;
        char *p3 = strchr(p2 + 1, '|');
        char *start = p2 + 1, *end = p3 ? p3 : start + strlen(start);
        while (start < end && (*start == ' ' || *start == '\t')) start++;
        while (end > start && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\n' || end[-1] == '\r')) end--;
        size_t n = (size_t)(end - start);
        if (n < 6 || n > 1024 || strncmp(end - 4, ".app", 4) != 0) continue;
        char prefix[1100];
        snprintf(prefix, sizeof prefix, "%.*s/Contents/MacOS/", (int)n, start);
        size_t pl = strlen(prefix);
        if (strncmp(prog, prefix, pl) == 0 && prog[pl] && !strchr(prog + pl, '/')) ok = 1;
    }
    fclose(f);
    return ok;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <user> <program> [args...]\n", argv[0]);
        return 64;
    }
    if (getuid() != 0 || geteuid() != 0) {
        fprintf(stderr, "vpnrun: must be started as root\n");
        return 1;
    }

    if (!program_allowed(argv[2])) { fprintf(stderr, "vpnrun: program not allowed\n"); return 1; }

    struct group *g = getgrnam(VS_GROUP);
    if (!g) { fprintf(stderr, "vpnrun: group %s missing\n", VS_GROUP); return 1; }
    gid_t gid = g->gr_gid;
    if (gid < VS_GID_MIN || gid > VS_GID_MAX) {
        fprintf(stderr, "vpnrun: group id outside private range\n");
        return 1;
    }

    struct passwd *p = getpwnam(argv[1]);
    if (!p) { fprintf(stderr, "vpnrun: no such user\n"); return 1; }
    if (p->pw_uid == 0) { fprintf(stderr, "vpnrun: refusing to run as root\n"); return 1; }
    uid_t uid = p->pw_uid;

    /* setuid() changes credentials, not the environment sudo prepared. */
    const char *shell = (p->pw_shell && p->pw_shell[0]) ? p->pw_shell : "/bin/zsh";
    if (setenv("HOME", p->pw_dir, 1) || setenv("USER", p->pw_name, 1) ||
        setenv("LOGNAME", p->pw_name, 1) || setenv("SHELL", shell, 1) ||
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)) {
        perror("setenv");
        return 1;
    }
    unsetenv("SUDO_COMMAND"); unsetenv("SUDO_USER");
    unsetenv("SUDO_UID");     unsetenv("SUDO_GID");

    /* Supplementary groups stay the user's own (file access keeps working);
       the primary group, which PF matches, becomes vpnselectivo. */
    if (initgroups(p->pw_name, (int)gid) != 0) { perror("initgroups"); return 1; }
    if (setgid(gid) != 0) { perror("setgid"); return 1; }
    if (setuid(uid) != 0) { perror("setuid"); return 1; }
    if (getuid() != uid || geteuid() != uid || getgid() != gid || getegid() != gid) {
        fprintf(stderr, "vpnrun: credential drop could not be verified\n");
        return 1;
    }
    if (setuid(0) == 0) { fprintf(stderr, "vpnrun: privileges not dropped\n"); return 1; }

#ifdef _CS_DARWIN_USER_TEMP_DIR
    char tmp[1024];
    size_t n = confstr(_CS_DARWIN_USER_TEMP_DIR, tmp, sizeof tmp);
    if (n > 1 && n <= sizeof tmp) setenv("TMPDIR", tmp, 1); else unsetenv("TMPDIR");
#else
    unsetenv("TMPDIR");
#endif

    /* GUI apps: detach from sudo's pty session so its teardown cannot SIGHUP
       them. Command-line tests keep stdio so vsctl can read their output. */
    int gui = strstr(argv[2], ".app/Contents/MacOS/") != NULL;
    if (gui) {
        if (setsid() < 0 && errno != EPERM) { perror("setsid"); return 1; }
        int fd = open("/dev/null", O_RDWR);
        if (fd >= 0) {
            dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
            if (fd > 2) close(fd);
        }
    }
    /* vsctl ignores SIGHUP until the new session exists; the app itself gets
       the normal disposition back. */
    signal(SIGHUP, SIG_DFL);

    /* Exec in place, but make the program responsible for itself (privacy
       prompts are attributed to it, as when Terminal or open(1) launch it). */
    posix_spawnattr_t attrs;
    if (posix_spawnattr_init(&attrs) != 0) return 1;
    if (posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETEXEC) != 0) return 1;
    if (responsibility_spawnattrs_setdisclaim != NULL)
        responsibility_spawnattrs_setdisclaim(&attrs, 1);
    int rc = posix_spawn(NULL, argv[2], NULL, &attrs, &argv[2], environ);
    fprintf(stderr, "vpnrun: posix_spawn: %s\n", strerror(rc));
    return 1;
}
