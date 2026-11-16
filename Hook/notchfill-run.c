// notchfill-run: start a game with NotchFillHook loaded.
//
//   notchfill-run [--resolution WxH] /path/to/Game.app [args...]
//   notchfill-run [--resolution WxH] /path/to/Game.app/Contents/MacOS/Game [args...]
//   Steam launch option:  "/Applications/NotchFill.app/Contents/MacOS/notchfill-run" %command%
//
// --resolution: for Unity games (UnityPlayer.dylib somewhere in the .app, also inside
// wrapper apps) adds "-screen-width W -screen-height H". Other games ignore it.
//
// NotchFill's game profile for the app (defaults "profiles", by bundle id or
// "exe:<name>") wins over --resolution: its `unityResolution` is used instead, and with
// `fullScreen` Unity games also get "-screen-fullscreen 1".
//
// The hook library is found next to this binary: ../Resources/libNotchFillHook.dylib.
// The environment is set here (not in the shell) because macOS removes DYLD_* variables
// when a protected binary such as /bin/sh starts a process.

#include <CoreFoundation/CoreFoundation.h>
#include <fts.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int is_dir(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

// "/x/Game.app" -> "/x/Game.app/Contents/MacOS/<CFBundleExecutable>"
static int bundle_executable(const char *app, char *out, size_t size) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)app, strlen(app), true);
    if (!url) return 0;
    CFBundleRef bundle = CFBundleCreate(NULL, url);
    CFRelease(url);
    if (!bundle) return 0;
    CFURLRef exe = CFBundleCopyExecutableURL(bundle);
    CFRelease(bundle);
    if (!exe) return 0;
    Boolean ok = CFURLGetFileSystemRepresentation(exe, true, (UInt8 *)out, (CFIndex)size);
    CFRelease(exe);
    return ok;
}

// The outermost "*.app" that contains `path` ("" if none).
static void outer_app(const char *path, char *out, size_t size) {
    out[0] = 0;
    const char *p = strstr(path, ".app/");
    size_t len = p ? (size_t)(p - path) + 4 : 0;
    if (!p && strlen(path) > 4 && strcmp(path + strlen(path) - 4, ".app") == 0) len = strlen(path);
    if (len == 0 || len >= size) return;
    memcpy(out, path, len);
    out[len] = 0;
}

// Unity game: UnityPlayer.dylib anywhere in the bundle (max depth 8, also nested apps).
static int is_unity(const char *app) {
    char *roots[] = {(char *)app, NULL};
    FTS *fts = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!fts) return 0;
    int found = 0;
    FTSENT *e;
    while (!found && (e = fts_read(fts)) != NULL) {
        if (e->fts_info == FTS_D && e->fts_level >= 8) fts_set(fts, e, FTS_SKIP);
        if (e->fts_info == FTS_F && strcmp(e->fts_name, "UnityPlayer.dylib") == 0) found = 1;
    }
    fts_close(fts);
    return found;
}

// NotchFill's profile for `app` (outer .app, may be "") or the bare executable `exe`.
// Returns a retained dictionary or NULL.
static CFDictionaryRef copy_profile(const char *app, const char *exe) {
    CFStringRef key = NULL;
    if (app[0]) {
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)app, strlen(app), true);
        CFBundleRef bundle = url ? CFBundleCreate(NULL, url) : NULL;
        if (url) CFRelease(url);
        if (bundle) {
            CFStringRef id = CFBundleGetIdentifier(bundle);
            if (id) key = CFStringCreateCopy(NULL, id);
            CFRelease(bundle);
        }
    }
    if (!key) {
        const char *slash = strrchr(exe, '/');
        key = CFStringCreateWithFormat(NULL, NULL, CFSTR("exe:%s"), slash ? slash + 1 : exe);
    }
    CFDictionaryRef result = NULL;
    CFPropertyListRef all = CFPreferencesCopyAppValue(CFSTR("profiles"), CFSTR("dev.notchfill.NotchFill"));
    if (all && CFGetTypeID(all) == CFDictionaryGetTypeID()) {
        CFTypeRef p = CFDictionaryGetValue((CFDictionaryRef)all, key);
        if (p && CFGetTypeID(p) == CFDictionaryGetTypeID()) result = CFRetain(p);
    }
    if (all) CFRelease(all);
    CFRelease(key);
    return result;
}

static int profile_bool(CFDictionaryRef profile, CFStringRef name) {
    CFTypeRef v = profile ? CFDictionaryGetValue(profile, name) : NULL;
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) return CFBooleanGetValue(v);
    int n = 0;
    return v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue(v, kCFNumberIntType, &n) && n != 0;
}

// Profile's "unityResolution" ("WxH") into width/height; 0 if none.
static int profile_resolution(CFDictionaryRef profile, int *width, int *height) {
    CFTypeRef v = profile ? CFDictionaryGetValue(profile, CFSTR("unityResolution")) : NULL;
    char buf[32];
    if (!v || CFGetTypeID(v) != CFStringGetTypeID() ||
        !CFStringGetCString(v, buf, sizeof(buf), kCFStringEncodingUTF8)) return 0;
    int w = 0, h = 0;
    if (sscanf(buf, "%dx%d", &w, &h) != 2 || w <= 0 || h <= 0) return 0;
    *width = w;
    *height = h;
    return 1;
}

int main(int argc, char **argv) {
    int width = 0, height = 0;
    if (argc >= 3 && strcmp(argv[1], "--resolution") == 0) {
        if (sscanf(argv[2], "%dx%d", &width, &height) != 2 || width <= 0 || height <= 0) {
            fprintf(stderr, "notchfill-run: bad --resolution %s (use WxH)\n", argv[2]);
            return 64;
        }
        argv += 2;
        argc -= 2;
    }
    if (argc < 2) {
        fprintf(stderr, "usage: %s [--resolution WxH] /path/to/Game.app|executable [args...]\n", argv[0]);
        return 64;
    }

    char self[PATH_MAX], real[PATH_MAX], hook[PATH_MAX];
    uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0 || realpath(self, real) == NULL) {
        fprintf(stderr, "notchfill-run: cannot find own path\n");
        return 70;
    }
    snprintf(hook, sizeof(hook), "%s/../Resources/libNotchFillHook.dylib", dirname(real));
    if (realpath(hook, self) == NULL) {
        fprintf(stderr, "notchfill-run: hook library not found: %s\n", hook);
        return 70;
    }

    const char *old = getenv("DYLD_INSERT_LIBRARIES");
    if (old && *old) {
        char joined[PATH_MAX * 4];
        snprintf(joined, sizeof(joined), "%s:%s", self, old);
        setenv("DYLD_INSERT_LIBRARIES", joined, 1);
    } else {
        setenv("DYLD_INSERT_LIBRARIES", self, 1);
    }

    char target[PATH_MAX], app[PATH_MAX];
    const char *path = argv[1];
    outer_app(path, app, sizeof(app));
    if (is_dir(path)) {
        if (!bundle_executable(path, target, sizeof(target))) {
            fprintf(stderr, "notchfill-run: not an app bundle: %s\n", path);
            return 66;
        }
        path = target;
    }

    CFDictionaryRef profile = copy_profile(app, path);
    profile_resolution(profile, &width, &height);
    int full_screen = profile_bool(profile, CFSTR("fullScreen"));
    if (profile) CFRelease(profile);
    int unity = (width > 0 || full_screen) && app[0] && is_unity(app);

    // New argv: target, original args, then the Unity args.
    char **args = calloc((size_t)argc + 8, sizeof(char *));
    int n = 0;
    args[n++] = (char *)path;
    for (int i = 2; i < argc; i++) args[n++] = argv[i];
    char w[16], h[16];
    if (width > 0) {
        char res[32];
        snprintf(res, sizeof(res), "%dx%d", width, height);
        setenv("NOTCHFILL_RESOLUTION", res, 1);
        if (unity) {
            snprintf(w, sizeof(w), "%d", width);
            snprintf(h, sizeof(h), "%d", height);
            args[n++] = "-screen-width";
            args[n++] = w;
            args[n++] = "-screen-height";
            args[n++] = h;
        } else {
            fprintf(stderr, "notchfill-run: not a Unity game, resolution ignored\n");
        }
    }
    if (full_screen && unity) {
        args[n++] = "-screen-fullscreen";
        args[n++] = "1";
    }
    args[n] = NULL;
    execv(path, args);
    perror("notchfill-run: execv");
    return 71;
}
