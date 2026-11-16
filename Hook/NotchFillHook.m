// NotchFillHook: loaded into a game with DYLD_INSERT_LIBRARIES (no SIP change needed).
// Makes native macOS full screen cover the strip beside the notch.
//
// How (measured on macOS 27, see docs/RESEARCH.md):
// 1. The Dock already gives the full screen tile the whole display (1117 pt on a 16"),
//    but AppKit cuts it to the area below the notch in -[NSWindow _frameForFullScreenMode].
//    We stretch that frame back up to the top edge of the screen.
// 2. In full screen, WindowServer keeps the (black) menu bar over the strip at level 24.
//    While a window is in full screen we put it one level above the menu bar.
//
// 3. Engines with their own full screen (Unity: borderless window sized from
//    -[NSScreen safeAreaInsets]) keep below the notch. Inside the game we report a top
//    safe-area inset of 0, so they size their window to the whole screen.
// 4. NOTCHFILL_RESOLUTION=WxH (set by notchfill-run --resolution): for Unity games, write
//    it into Unity's saved screen settings before Unity reads them. An env variable, not
//    an argument, because wrapper apps (Contents/MacOS/load → inner .app) drop arguments.
//
// Set NOTCHFILL_DISABLE=1 to load the library without changes.

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static IMP sOrigFrame;
static IMP sOrigFrameInRect;
static IMP sOrigVisibleTileFrame;
static IMP sOrigSafeArea;
static const void *kSavedLevelKey = &kSavedLevelKey;

static BOOL NFScreenHasNotch(NSScreen *screen) {
    if (screen == nil) return NO;
    if (@available(macOS 12.0, *)) {
        // safeAreaInsets is patched below, so look at the areas beside the notch.
        return !NSIsEmptyRect(screen.auxiliaryTopLeftArea);
    }
    return NO;
}

static NSEdgeInsets NFSafeAreaInsets(NSScreen *self, SEL _cmd) {
    NSEdgeInsets insets = ((NSEdgeInsets (*)(id, SEL))sOrigSafeArea)(self, _cmd);
    insets.top = 0;
    return insets;
}

// WxH from NOTCHFILL_RESOLUTION, else from NotchFill's "Game Resolution" setting (used by
// games patched with scripts/patch-game.py, which start without notchfill-run).
static NSString *NFResolution(void) {
    const char *env = getenv("NOTCHFILL_RESOLUTION");
    if (env != NULL && env[0] != 0) return @(env);
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("gameResolution"), CFSTR("dev.notchfill.NotchFill"));
    if (v == NULL) return nil;
    NSString *s = [(__bridge id)v isKindOfClass:NSString.class] ? [(__bridge NSString *)v copy] : nil;
    CFRelease(v);
    return s;
}

static void NFApplyUnityResolution(void) {
    NSString *res = NFResolution();
    int w = 0, h = 0;
    if (res == nil || sscanf(res.UTF8String, "%dx%d", &w, &h) != 2 || w <= 0 || h <= 0) return;
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    NSString *player = [frameworks stringByAppendingPathComponent:@"UnityPlayer.dylib"];
    if (frameworks == nil || ![NSFileManager.defaultManager fileExistsAtPath:player]) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:w forKey:@"Screenmanager Resolution Width"];
    [d setInteger:h forKey:@"Screenmanager Resolution Height"];
    [d setInteger:0 forKey:@"Screenmanager Resolution Use Native"];
    NSLog(@"NotchFillHook: Unity resolution %dx%d", w, h);
}

static NSRect NFStretch(NSWindow *window, NSRect rect) {
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    if (!NFScreenHasNotch(screen)) return rect;
    CGFloat top = NSMaxY(screen.frame);
    if (NSMaxY(rect) >= top - 0.5) return rect;
    rect.size.height = top - rect.origin.y;
    return rect;
}

static NSRect NFFrameForFullScreenMode(NSWindow *self, SEL _cmd) {
    NSRect r = ((NSRect (*)(id, SEL))sOrigFrame)(self, _cmd);
    return NFStretch(self, r);
}

static NSRect NFFrameForFullScreenModeInRect(NSWindow *self, SEL _cmd, NSRect inRect) {
    NSRect r = ((NSRect (*)(id, SEL, NSRect))sOrigFrameInRect)(self, _cmd, inRect);
    return NFStretch(self, r);
}

// Mission Control recalculates this frame when restoring a full screen Space.
static NSRect NFVisibleTileFrameForFullScreen(NSWindow *self, SEL _cmd) {
    NSRect r = ((NSRect (*)(id, SEL))sOrigVisibleTileFrame)(self, _cmd);
    return NFStretch(self, r);
}

static IMP NFReplace(Class cls, NSString *name, IMP replacement) {
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (m == NULL) {
        NSLog(@"NotchFillHook: %@ not found, this macOS is not supported", name);
        return NULL;
    }
    return method_setImplementation(m, replacement);
}

static void NFRaiseAboveMenuBar(NSWindow *window) {
    if (!NFScreenHasNotch(window.screen)) return;
    if (objc_getAssociatedObject(window, kSavedLevelKey) == nil) {
        objc_setAssociatedObject(window, kSavedLevelKey, @(window.level), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    window.level = CGWindowLevelForKey(kCGMainMenuWindowLevelKey) + 1;
    // The frame from AppKit is already stretched; set it again in case the app changed it.
    NSRect full = NFFrameForFullScreenMode(window, NSSelectorFromString(@"_frameForFullScreenMode"));
    if (!NSEqualRects(window.frame, full)) [window setFrame:full display:YES];
}

static void NFRestoreLevel(NSWindow *window) {
    NSNumber *saved = objc_getAssociatedObject(window, kSavedLevelKey);
    if (saved == nil) return;
    window.level = saved.integerValue;
    objc_setAssociatedObject(window, kSavedLevelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

__attribute__((constructor))
static void NotchFillHookInit(void) {
    const char *disable = getenv("NOTCHFILL_DISABLE");
    if (disable != NULL && disable[0] == '1') return;

    @autoreleasepool {
        Class cls = NSWindow.class;
        sOrigFrame = NFReplace(cls, @"_frameForFullScreenMode", (IMP)NFFrameForFullScreenMode);
        sOrigFrameInRect = NFReplace(cls, @"_frameForFullScreenModeInRect:", (IMP)NFFrameForFullScreenModeInRect);
        sOrigVisibleTileFrame = NFReplace(cls, @"_visibleTileFrameForFullScreen", (IMP)NFVisibleTileFrameForFullScreen);
        if (@available(macOS 12.0, *)) {
            sOrigSafeArea = method_setImplementation(
                class_getInstanceMethod(NSScreen.class, @selector(safeAreaInsets)), (IMP)NFSafeAreaInsets);
        }
        NFApplyUnityResolution();
        if (sOrigFrame == NULL && sOrigFrameInRect == NULL) return;

        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) { NFRaiseAboveMenuBar(n.object); }];
        [nc addObserverForName:NSWindowWillExitFullScreenNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) { NFRestoreLevel(n.object); }];
        NSLog(@"NotchFillHook: loaded");
    }
}
