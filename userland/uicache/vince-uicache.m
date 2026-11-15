// vince-uicache: register the system apps in /Applications with LaunchServices.
//
// The root image is built on Linux, so nobody ever ran installd's system-app scan and the LaunchServices
// database knows only a handful of apps (Settings, App Store, Safari, ...), no app extensions (PosterBoard
// finds no wallpaper provider). This does what uicache does on a jailbroken iOS, in two steps:
//   1. -[LSApplicationWorkspace _LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:]
//   2. for every /Applications/*.app that is still missing: registerApplicationDictionary: (Info.plist +
//      ApplicationType=System + Path)
// Every line starts with "uicache:" and goes to stdout (/dev/console when run from launchd).
// Usage: vince-uicache [--force]     (without --force it runs once; the marker is /var/mobile/.vince-uicache)
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>
#import <sys/stat.h>
#import <unistd.h>
#import <dispatch/dispatch.h>

#define MARKER "/var/mobile/.vince-uicache"

// Run blk on its own thread and wait at most secs; a call into lsd that never returns must not stop the rest.
static BOOL timed(const char *name, double secs, void (^blk)(void)) {
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	printf("uicache: [%s] begin\n", name);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ @autoreleasepool { blk(); } dispatch_semaphore_signal(sem); });
	BOOL ok = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC))) == 0;
	printf("uicache: [%s] %s\n", name, ok ? "done" : "TIMEOUT (still blocked in lsd)");
	return ok;
}

static NSUInteger installedCount(id ws) {
	if ([ws respondsToSelector:@selector(allInstalledApplications)])
		return [[ws performSelector:@selector(allInstalledApplications)] count];
	return 0;
}

static BOOL has(id ws, NSString *bid) {
	if (![ws respondsToSelector:@selector(applicationIsInstalled:)]) return NO;
	return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, @selector(applicationIsInstalled:), bid);
}

int main(int argc, char **argv) {
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		printf("uicache: start pid %d\n", getpid());
		BOOL force = argc > 1 && !strcmp(argv[1], "--force");
		struct stat st;
		if (!force && !stat(MARKER, &st)) { printf("uicache: already done (%s), use --force\n", MARKER); return 0; }

		dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
		dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
		printf("uicache: frameworks loaded\n");
		Class cls = objc_getClass("LSApplicationWorkspace");
		id ws = cls ? [cls performSelector:@selector(defaultWorkspace)] : nil;
		if (!ws) { printf("uicache: no LSApplicationWorkspace\n"); return 1; }

		printf("uicache: workspace %p\n", (__bridge void *)ws);
		NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/Applications" error:nil];
		NSMutableArray *apps = [NSMutableArray array];
		for (NSString *d in dirs) if ([d hasSuffix:@".app"]) [apps addObject:d];
		printf("uicache: %lu apps in /Applications\n", (unsigned long)apps.count);
		__block BOOL pref = NO;
		timed("applicationIsInstalled Preferences", 30, ^{ pref = has(ws, @"com.apple.Preferences"); });
		printf("uicache: Preferences known: %d\n", pref);
		timed("allInstalledApplications", 30, ^{ printf("uicache: %lu known to LaunchServices\n", (unsigned long)installedCount(ws)); });

		printf("uicache: calling rebuild\n");
		SEL rebuild = NSSelectorFromString(@"_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:");
		if ([ws respondsToSelector:rebuild]) {
			timed("rebuild", 120, ^{
				BOOL r = ((BOOL (*)(id, SEL, BOOL, BOOL, BOOL))objc_msgSend)(ws, rebuild, YES, YES, NO);
				printf("uicache: rebuild(system) -> %d\n", r);
			});
		} else {
			printf("uicache: rebuild selector missing\n");
		}

		SEL regdict = NSSelectorFromString(@"registerApplicationDictionary:");
		SEL regurl = NSSelectorFromString(@"registerApplication:");
		printf("uicache: registering missing apps\n");
		unsigned added = 0, failed = 0;
		for (NSString *d in apps) {
			NSString *path = [@"/Applications" stringByAppendingPathComponent:d];
			NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
			NSString *bid = info[@"CFBundleIdentifier"];
			if (!bid) { printf("uicache: %s: no Info.plist\n", d.UTF8String); failed++; continue; }
			if (pref && has(ws, bid)) continue;
			info[@"ApplicationType"] = @"System";
			info[@"Path"] = path;
			BOOL ok = NO;
			__block BOOL r = NO;
			if (!timed(d.UTF8String, 20, ^{
				if ([ws respondsToSelector:regdict])
					r = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, regdict, info);
				if (!r && [ws respondsToSelector:regurl])
					r = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, regurl, [NSURL fileURLWithPath:path]);
			})) { printf("uicache: giving up, lsd does not answer\n"); failed++; break; }
			ok = r;
			printf("uicache: %s (%s) -> %d\n", d.UTF8String, bid.UTF8String, ok);
			ok ? added++ : failed++;
		}
		notify_post("com.apple.mobile.application_installed");
		printf("uicache: added %u, failed %u\n", added, failed);
		fflush(stdout);
		FILE *f = fopen(MARKER, "w"); if (f) fclose(f);
		return failed ? 2 : 0;
	}
}
