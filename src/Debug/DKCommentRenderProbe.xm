//
//  DKCommentRenderProbe.xm
//  DYKiller
//
//  诊断限定：本文件不调用 setNeedsDisplay / displayIfNeeded，不改颜色、文字、交互或选择状态。
//  事件入口只做紧凑的指针/标量采样；较重的私有层快照延后到 runloop 尾部和后续 frame，
//  避免把原本约 13 ms 的真实点击路径本身改造成另一种时序。
//

#import "DKCommentRenderProbe.h"
#import "DKCommentGlass.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <mach/mach.h>
#import <string.h>

static NSString *const kDKProbeCellClass =
    @"AWECommentPanelListSwiftImpl.CommentNewCell";
static NSString *const kDKProbeFooterClass =
    @"AWECommentPanelListSwiftImpl.CommentBaseFooterView";
static NSString *const kDKProbeInteractionLabelClass =
    @"AWECommentSwiftBizUI.CommentInteractionBaseLabel";
static NSString *const kDKProbeButtonLabelClass = @"UIButtonLabel";

static const NSUInteger kDKProbeEventLimit = 30000;
static const NSUInteger kDKProbePurgeBatch = 1000;

static NSMutableArray<NSDictionary *> *gDKProbeEvents;
static CFTimeInterval gDKProbeStartTime;
static NSUInteger gDKProbeSequence;
static NSUInteger gDKProbeDropped;
static NSUInteger gDKProbeFrameSequence;
static NSUInteger gDKProbeRunLoopSequence;
static CFRunLoopActivity gDKProbeRunLoopActivity;
static NSInteger gDKProbeCATransactionDepth;
static NSUInteger gDKProbeCATransactionSequence;
static CFTimeInterval gDKProbeCaptureUntil;
static NSUInteger gDKProbeCaptureGeneration;
static __weak UIView *gDKProbeTrackedContainer;
static NSUInteger gDKProbeFramesToSnapshot;
static NSUInteger gDKProbeRunLoopsToSnapshot;
static NSUInteger gDKProbeSnapshotCount;
static NSUInteger gDKProbeSnapshotDropped;
static CADisplayLink *gDKProbeDisplayLink;
static id gDKProbeClock;
static CFRunLoopObserverRef gDKProbeEarlyObserver;
static CFRunLoopObserverRef gDKProbeLateObserver;
static NSDictionary *gDKProbeOriginalCellRuntime;
static NSMutableArray<NSString *> *gDKProbeInstalledCellHooks;
static BOOL gDKProbeCellHooksInstalled;
static NSUInteger gDKProbeCellHookAttempts;
static char kDKProbeCellFirstLayoutKey;

static void DKProbeTryInstallCellHooks(void);

// 防止快照读取 presentationLayer / 私有 ivar 时被本探针自己的 CALayer hook 重新记一遍。
static __thread BOOL gDKProbeInternalRead = NO;

#pragma mark - 基础格式化与作用域

static NSString *DKProbePointer(const void *pointer) {
    return [NSString stringWithFormat:@"%p", pointer];
}

static NSString *DKProbeObjectPointer(id object) {
    return DKProbePointer((__bridge const void *)object);
}

static NSString *DKProbeImplementationPointer(IMP implementation) {
    return DKProbePointer(reinterpret_cast<const void *>(implementation));
}

static NSString *DKProbeClassName(id object) {
    if (!object) return @"";
    @try {
        return NSStringFromClass(object_getClass(object)) ?: @"";
    } @catch (__unused NSException *exception) {
        return @"<class threw>";
    }
}

static BOOL DKProbeClassEquals(id object, NSString *name) {
    return object && [DKProbeClassName(object) isEqualToString:name];
}

static UIView *DKProbeContainerForView(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        NSString *name = DKProbeClassName(candidate);
        if ([name isEqualToString:kDKProbeCellClass]
            || [name isEqualToString:kDKProbeFooterClass]) {
            return candidate;
        }
    }
    return nil;
}

static BOOL DKProbeViewIsInsidePanel(UIView *view) {
    UIView *panel = DKCommentGlassCurrentSlot();
    if (!view || !panel) return NO;
    return view == panel || [view isDescendantOfView:panel];
}

static BOOL DKProbeIsTargetLabel(UILabel *label) {
    if (!label) return NO;
    NSString *name = DKProbeClassName(label);
    UIView *container = DKProbeContainerForView(label);
    if ([name isEqualToString:kDKProbeInteractionLabelClass]) {
        return container && DKProbeClassEquals(container, kDKProbeCellClass);
    }
    if ([name isEqualToString:kDKProbeButtonLabelClass]) {
        return container && DKProbeClassEquals(container, kDKProbeFooterClass);
    }
    return NO;
}

static NSString *DKProbeRunLoopActivityName(CFRunLoopActivity activity) {
    switch (activity) {
        case kCFRunLoopEntry: return @"entry";
        case kCFRunLoopBeforeTimers: return @"beforeTimers";
        case kCFRunLoopBeforeSources: return @"beforeSources";
        case kCFRunLoopBeforeWaiting: return @"beforeWaiting";
        case kCFRunLoopAfterWaiting: return @"afterWaiting";
        case kCFRunLoopExit: return @"exit";
        default: return [NSString stringWithFormat:@"0x%lx", (unsigned long)activity];
    }
}

static NSString *DKProbeCurrentRunLoopMode(void) {
    if (![NSThread isMainThread]) return @"off-main";
    CFStringRef mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain());
    return CFBridgingRelease(mode) ?: @"(none)";
}

static BOOL DKProbeCaptureIsActive(void) {
    return CACurrentMediaTime() <= gDKProbeCaptureUntil;
}

static void DKProbeArmCapture(UIView *container, NSTimeInterval duration) {
    if (!container) return;
    CFTimeInterval until = CACurrentMediaTime() + MAX(duration, 0.05);
    if (until > gDKProbeCaptureUntil) gDKProbeCaptureUntil = until;
    gDKProbeTrackedContainer = container;
}

static NSDictionary *DKProbeCGColor(CGColorRef color) {
    if (!color) return @{};
    size_t count = CGColorGetNumberOfComponents(color);
    const CGFloat *components = CGColorGetComponents(color);
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
    for (size_t index = 0; components && index < count; index++) {
        [values addObject:@(components[index])];
    }
    return @{
        @"address": DKProbePointer(color),
        @"alpha": @(CGColorGetAlpha(color)),
        @"components": values,
    };
}

static NSDictionary *DKProbeUIColor(UIColor *color, UIView *view) {
    if (![color isKindOfClass:UIColor.class]) return @{};
    UIColor *resolved = view
        ? [color resolvedColorWithTraitCollection:view.traitCollection]
        : color;
    NSMutableDictionary *result = [DKProbeCGColor(resolved.CGColor) mutableCopy];
    result[@"object"] = DKProbeObjectPointer(color);
    result[@"class"] = DKProbeClassName(color);
    return result;
}

static NSDictionary *DKProbeObjectIdentity(id object) {
    if (!object) return @{};
    return @{
        @"address": DKProbeObjectPointer(object),
        @"class": DKProbeClassName(object),
    };
}

static NSDictionary *DKProbeContentsIdentity(id contents) {
    if (!contents) return @{};
    NSMutableDictionary *result = [DKProbeObjectIdentity(contents) mutableCopy];
    @try {
        result[@"hash"] = @([contents hash]);
    } @catch (__unused NSException *exception) {
        result[@"hashError"] = @YES;
    }
    return result;
}

static NSString *DKProbeStringFingerprint(NSString *string) {
    if (!string.length) return @"0000000000000000";
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger index = 0; index < data.length; index++) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
}

static NSDictionary *DKProbeStringIdentity(NSString *string) {
    if (!string.length) return @{};
    return @{
        @"utf16Length": @(string.length),
        @"fnv1a64Utf8": DKProbeStringFingerprint(string),
    };
}

#pragma mark - 事件环

static void DKProbeAppendEvent(NSString *event,
                               id object,
                               UIView *container,
                               NSDictionary *details) {
    if (gDKProbeInternalRead || !gDKProbeEvents || event.length == 0) return;

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"event"] = event;
    record[@"monoMs"] = @((CACurrentMediaTime() - gDKProbeStartTime) * 1000.0);
    record[@"mainThread"] = @([NSThread isMainThread]);
    record[@"thread"] = @(pthread_mach_thread_np(pthread_self()));
    record[@"frame"] = @(gDKProbeFrameSequence);
    record[@"runLoop"] = @(gDKProbeRunLoopSequence);
    record[@"runLoopActivity"] = DKProbeRunLoopActivityName(gDKProbeRunLoopActivity);
    record[@"runLoopMode"] = DKProbeCurrentRunLoopMode();
    record[@"caExplicitDepth"] = @(gDKProbeCATransactionDepth);
    record[@"caExplicitSequence"] = @(gDKProbeCATransactionSequence);
    record[@"captureGeneration"] = @(gDKProbeCaptureGeneration);
    if (object) {
        record[@"object"] = DKProbeObjectPointer(object);
        record[@"objectClass"] = DKProbeClassName(object);
    }
    if (container) {
        record[@"container"] = DKProbeObjectPointer(container);
        record[@"containerClass"] = DKProbeClassName(container);
    }
    if (details.count) record[@"details"] = details;

    @synchronized (gDKProbeEvents) {
        record[@"sequence"] = @(++gDKProbeSequence);
        if (gDKProbeEvents.count >= kDKProbeEventLimit) {
            NSUInteger purge = MIN(kDKProbePurgeBatch, gDKProbeEvents.count);
            [gDKProbeEvents removeObjectsInRange:NSMakeRange(0, purge)];
            gDKProbeDropped += purge;
        }
        [gDKProbeEvents addObject:[record copy]];
    }
}

void DKCommentRenderProbeMarkViewEvent(UIView *view, NSString *event) {
    if (!gDKProbeCellHooksInstalled && [NSThread isMainThread]) {
        DKProbeTryInstallCellHooks();
    }
    UIView *container = DKProbeContainerForView(view);
    if (container) DKProbeArmCapture(container, 0.35);
    DKProbeAppendEvent([@"glass." stringByAppendingString:event ?: @"marker"],
                       view, container, nil);
}

#pragma mark - UILabel / CALayer 只读状态

static Ivar DKProbeFindIvar(id object, const char *name) {
    if (!object || !name) return NULL;
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return ivar;
    }
    return NULL;
}

static id DKProbeObjectIvar(id object, const char *name) {
    Ivar ivar = DKProbeFindIvar(object, name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    @try {
        return object_getIvar(object, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL DKProbeBoolSelector(id object, SEL selector, BOOL fallback) {
    if (!object || ![object respondsToSelector:selector]) return fallback;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return fallback;
    }
}

static id DKProbeObjectSelector(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSDictionary *DKProbeSelectedIvars(id object) {
    if (!object) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSUInteger classDepth = 0;
    for (Class cls = object_getClass(object); cls && classDepth < 8;
         cls = class_getSuperclass(cls), classDepth++) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            Ivar ivar = ivars[index];
            const char *rawName = ivar_getName(ivar);
            const char *type = ivar_getTypeEncoding(ivar);
            if (!rawName || !type) continue;
            NSString *name = [NSString stringWithUTF8String:rawName] ?: @"";
            NSString *lower = name.lowercaseString;
            BOOL selected = [lower containsString:@"content"]
                || [lower containsString:@"backing"]
                || [lower containsString:@"render"]
                || [lower containsString:@"display"]
                || [lower containsString:@"highlight"]
                || [lower containsString:@"light"]
                || [lower containsString:@"cache"]
                || [lower containsString:@"opaque"];
            if (!selected) continue;

            uint8_t *address = (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
            id value = nil;
            if (type[0] == '@') {
                @try { value = object_getIvar(object, ivar); }
                @catch (__unused NSException *exception) { value = nil; }
                result[name] = value ? DKProbeObjectIdentity(value) : @{};
            } else if (type[0] == '^' || type[0] == '*') {
                void *pointer = NULL;
                memcpy(&pointer, address, sizeof(pointer));
                result[name] = DKProbePointer(pointer);
            } else if (strchr("BcC", type[0])) {
                unsigned char scalar = 0;
                memcpy(&scalar, address, sizeof(scalar));
                result[name] = @(scalar);
            } else if (strchr("sSiIlLqQ", type[0])) {
                unsigned long long scalar = 0;
                size_t size = 0;
                NSGetSizeAndAlignment(type, &size, NULL);
                memcpy(&scalar, address, MIN(size, sizeof(scalar)));
                result[name] = @(scalar);
            }
        }
        free(ivars);
    }
    return result;
}

static NSDictionary *DKProbeAttributeValue(id value) {
    if (!value) return @{};
    if ([value isKindOfClass:UIColor.class]) {
        return @{ @"kind": @"color", @"value": DKProbeUIColor(value, nil) };
    }
    if ([value isKindOfClass:UIFont.class]) {
        UIFont *font = value;
        return @{
            @"kind": @"font",
            @"name": font.fontName ?: @"",
            @"pointSize": @(font.pointSize),
        };
    }
    if ([value isKindOfClass:NSNumber.class]) {
        return @{ @"kind": @"number", @"value": value };
    }
    if ([value isKindOfClass:NSParagraphStyle.class]) {
        NSParagraphStyle *style = value;
        return @{
            @"kind": @"paragraph",
            @"alignment": @(style.alignment),
            @"lineBreakMode": @(style.lineBreakMode),
            @"lineSpacing": @(style.lineSpacing),
            @"paragraphSpacing": @(style.paragraphSpacing),
            @"minimumLineHeight": @(style.minimumLineHeight),
            @"maximumLineHeight": @(style.maximumLineHeight),
        };
    }
    if ([value isKindOfClass:NSShadow.class]) {
        NSShadow *shadow = value;
        return @{
            @"kind": @"shadow",
            @"offset": NSStringFromCGSize(shadow.shadowOffset),
            @"blurRadius": @(shadow.shadowBlurRadius),
            @"color": [shadow.shadowColor isKindOfClass:UIColor.class]
                ? DKProbeUIColor(shadow.shadowColor, nil) : @{},
        };
    }
    // 任意字符串/URL/附件内容可能含评论或用户数据；未知值只保留类型与身份。
    return @{
        @"kind": @"object",
        @"identity": DKProbeObjectIdentity(value),
    };
}

static NSArray *DKProbeAttributedRuns(NSAttributedString *text) {
    if (!text.length) return @[];
    NSMutableArray *runs = [NSMutableArray array];
    [text enumerateAttributesInRange:NSMakeRange(0, text.length)
                             options:0
                          usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attributes,
                                       NSRange range,
                                       __unused BOOL *stop) {
        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        [attributes enumerateKeysAndObjectsUsingBlock:^(NSAttributedStringKey key,
                                                         id value,
                                                         __unused BOOL *innerStop) {
            clean[[key description] ?: @"<key>"] = DKProbeAttributeValue(value);
        }];
        [runs addObject:@{
            @"location": @(range.location),
            @"length": @(range.length),
            @"attributes": clean,
        }];
    }];
    return runs;
}

static NSDictionary *DKProbeLayerState(CALayer *layer, BOOL includePresentation) {
    if (!layer) return @{};
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"address"] = DKProbeObjectPointer(layer);
    state[@"class"] = DKProbeClassName(layer);
    state[@"delegate"] = DKProbeObjectIdentity(layer.delegate);
    state[@"bounds"] = NSStringFromCGRect(layer.bounds);
    state[@"frame"] = NSStringFromCGRect(layer.frame);
    state[@"position"] = NSStringFromCGPoint(layer.position);
    state[@"anchorPoint"] = NSStringFromCGPoint(layer.anchorPoint);
    state[@"backgroundColor"] = DKProbeCGColor(layer.backgroundColor);
    state[@"contents"] = DKProbeContentsIdentity(layer.contents);
    state[@"contentsScale"] = @(layer.contentsScale);
    state[@"contentsGravity"] = layer.contentsGravity ?: @"";
    state[@"opacity"] = @(layer.opacity);
    state[@"opaque"] = @(layer.opaque);
    state[@"hidden"] = @(layer.hidden);
    state[@"masksToBounds"] = @(layer.masksToBounds);
    state[@"needsDisplay"] = @(layer.needsDisplay);
    state[@"needsDisplayOnBoundsChange"] = @(layer.needsDisplayOnBoundsChange);
    state[@"shouldRasterize"] = @(layer.shouldRasterize);
    state[@"rasterizationScale"] = @(layer.rasterizationScale);
    state[@"hasBeenCommitted"] = @(
        DKProbeBoolSelector(layer, NSSelectorFromString(@"hasBeenCommitted"), NO));
    state[@"contentsOpaque"] = @(
        DKProbeBoolSelector(layer, NSSelectorFromString(@"contentsOpaque"), layer.opaque));
    state[@"allowsDisplayCompositing"] = @(
        DKProbeBoolSelector(layer, NSSelectorFromString(@"allowsDisplayCompositing"), NO));
    state[@"rasterizationPrefersDisplayCompositing"] = @(
        DKProbeBoolSelector(layer,
            NSSelectorFromString(@"rasterizationPrefersDisplayCompositing"), NO));
    state[@"context"] = DKProbeObjectIdentity(
        DKProbeObjectSelector(layer, NSSelectorFromString(@"context")));
    state[@"renderID"] = DKProbeObjectIdentity(
        DKProbeObjectSelector(layer, NSSelectorFromString(@"UICLayerRenderID"))
        ?: DKProbeObjectSelector(layer, NSSelectorFromString(@"UICALayerRenderID")));

    NSMutableArray *sublayerIDs = [NSMutableArray array];
    for (CALayer *sublayer in layer.sublayers ?: @[]) {
        [sublayerIDs addObject:DKProbeObjectIdentity(sublayer)];
    }
    state[@"sublayers"] = sublayerIDs;

    if (includePresentation) {
        CALayer *presentation = layer.presentationLayer;
        state[@"presentation"] = presentation ? @{
            @"address": DKProbeObjectPointer(presentation),
            @"class": DKProbeClassName(presentation),
            @"bounds": NSStringFromCGRect(presentation.bounds),
            @"position": NSStringFromCGPoint(presentation.position),
            @"backgroundColor": DKProbeCGColor(presentation.backgroundColor),
            @"contents": DKProbeContentsIdentity(presentation.contents),
            @"opacity": @(presentation.opacity),
            @"hidden": @(presentation.hidden),
        } : @{};
    }
    return state;
}

static NSDictionary *DKProbeLayerTree(CALayer *layer,
                                      NSUInteger depth,
                                      NSUInteger *nodeCount) {
    if (!layer || depth > 8 || !nodeCount || *nodeCount >= 96) return @{};
    (*nodeCount)++;
    NSMutableDictionary *result = [DKProbeLayerState(layer, YES) mutableCopy];
    NSMutableArray *children = [NSMutableArray array];
    for (CALayer *sublayer in layer.sublayers ?: @[]) {
        NSDictionary *child = DKProbeLayerTree(sublayer, depth + 1, nodeCount);
        if (child.count) [children addObject:child];
    }
    result[@"children"] = children;
    return result;
}

static NSDictionary *DKProbeLabelCoreState(UILabel *label, BOOL deep) {
    if (!label) return @{};
    NSString *plain = label.attributedText.string ?: label.text ?: @"";
    id impl = DKProbeObjectIvar(label, "_impl");
    id content = DKProbeObjectIvar(label, "_content");
    CALayer *root = label.layer;
    NSArray<NSString *> *privateNames = @[
        @"_contentLayer", @"_lightReactiveLayer", @"_lightInertLayer"
    ];
    NSMutableDictionary *privateLayers = [NSMutableDictionary dictionary];
    for (NSString *name in privateNames) {
        id value = DKProbeObjectIvar(root, name.UTF8String);
        if ([value isKindOfClass:CALayer.class]) {
            privateLayers[name] = DKProbeLayerState(value, YES);
        } else {
            privateLayers[name] = DKProbeObjectIdentity(value);
        }
    }

    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"address"] = DKProbeObjectPointer(label);
    state[@"class"] = DKProbeClassName(label);
    state[@"accessibilityIdentifier"] = label.accessibilityIdentifier ?: @"";
    state[@"text"] = DKProbeStringIdentity(plain);
    state[@"attributedRuns"] = DKProbeAttributedRuns(label.attributedText);
    state[@"frame"] = NSStringFromCGRect(label.frame);
    state[@"bounds"] = NSStringFromCGRect(label.bounds);
    state[@"windowFrame"] = label.window
        ? NSStringFromCGRect([label convertRect:label.bounds toView:label.window]) : @"";
    state[@"backgroundColor"] = DKProbeUIColor(label.backgroundColor, label);
    state[@"textColor"] = DKProbeUIColor(label.textColor, label);
    state[@"highlightedTextColor"] = DKProbeUIColor(label.highlightedTextColor, label);
    state[@"tintColor"] = DKProbeUIColor(label.tintColor, label);
    state[@"alpha"] = @(label.alpha);
    state[@"hidden"] = @(label.hidden);
    state[@"opaque"] = @(label.opaque);
    state[@"highlighted"] = @(label.highlighted);
    state[@"enabled"] = @(label.enabled);
    state[@"impl"] = DKProbeObjectIdentity(impl);
    state[@"implSelectedIvars"] = deep ? DKProbeSelectedIvars(impl) : @{};
    state[@"content"] = DKProbeObjectIdentity(content);
    state[@"contentSelectedIvars"] = deep ? DKProbeSelectedIvars(content) : @{};
    NSDictionary *rootLayerState = nil;
    if (deep) {
        NSUInteger count = 0;
        rootLayerState = DKProbeLayerTree(root, 0, &count);
    } else {
        rootLayerState = DKProbeLayerState(root, YES);
    }
    state[@"rootLayer"] = rootLayerState ?: @{};
    state[@"privateLayers"] = privateLayers;
    state[@"lightContainerView"] = DKProbeObjectIdentity(
        DKProbeObjectIvar(root, "_lightContainerView"));
    return state;
}

static void DKProbeRecordLabelEvent(UILabel *label,
                                    NSString *event,
                                    NSDictionary *extra) {
    if (!DKProbeIsTargetLabel(label)) return;
    UIView *container = DKProbeContainerForView(label);
    BOOL previous = gDKProbeInternalRead;
    gDKProbeInternalRead = YES;
    NSDictionary *state = DKProbeLabelCoreState(label, NO);
    gDKProbeInternalRead = previous;
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithObject:state
                                                                       forKey:@"labelState"];
    if (extra.count) [details addEntriesFromDictionary:extra];
    DKProbeAppendEvent(event, label, container, details);
}

#pragma mark - Cell / Footer 深快照

static NSDictionary *DKProbeGestureState(UIGestureRecognizer *gesture) {
    if (!gesture) return @{};
    return @{
        @"address": DKProbeObjectPointer(gesture),
        @"class": DKProbeClassName(gesture),
        @"state": @(gesture.state),
        @"enabled": @(gesture.enabled),
        @"cancelsTouchesInView": @(gesture.cancelsTouchesInView),
        @"delaysTouchesBegan": @(gesture.delaysTouchesBegan),
        @"delaysTouchesEnded": @(gesture.delaysTouchesEnded),
        @"view": DKProbeObjectIdentity(gesture.view),
    };
}

static NSDictionary *DKProbeViewSnapshot(UIView *view,
                                         NSUInteger depth,
                                         NSUInteger *nodeCount) {
    if (!view || depth > 30 || !nodeCount || *nodeCount >= 384) return @{};
    (*nodeCount)++;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"address"] = DKProbeObjectPointer(view);
    result[@"class"] = DKProbeClassName(view);
    result[@"accessibilityIdentifier"] = view.accessibilityIdentifier ?: @"";
    result[@"accessibilityLabel"] = DKProbeStringIdentity(view.accessibilityLabel ?: @"");
    result[@"frame"] = NSStringFromCGRect(view.frame);
    result[@"bounds"] = NSStringFromCGRect(view.bounds);
    result[@"windowFrame"] = view.window
        ? NSStringFromCGRect([view convertRect:view.bounds toView:view.window]) : @"";
    result[@"backgroundColor"] = DKProbeUIColor(view.backgroundColor, view);
    result[@"tintColor"] = DKProbeUIColor(view.tintColor, view);
    result[@"alpha"] = @(view.alpha);
    result[@"hidden"] = @(view.hidden);
    result[@"opaque"] = @(view.opaque);
    result[@"clipsToBounds"] = @(view.clipsToBounds);
    result[@"userInteractionEnabled"] = @(view.userInteractionEnabled);
    result[@"contentMode"] = @(view.contentMode);
    result[@"layer"] = DKProbeLayerState(view.layer, YES);
    if ([view isKindOfClass:UILabel.class]) {
        result[@"label"] = DKProbeLabelCoreState((UILabel *)view, YES);
    }

    NSMutableArray *gestures = [NSMutableArray array];
    for (UIGestureRecognizer *gesture in view.gestureRecognizers ?: @[]) {
        [gestures addObject:DKProbeGestureState(gesture)];
    }
    result[@"gestures"] = gestures;

    NSMutableArray *children = [NSMutableArray array];
    for (UIView *subview in view.subviews) {
        NSDictionary *child = DKProbeViewSnapshot(subview, depth + 1, nodeCount);
        if (child.count) [children addObject:child];
    }
    result[@"children"] = children;
    return result;
}

static NSDictionary *DKProbeContainerSnapshot(UIView *container, NSString *reason) {
    if (!container) return @{};
    BOOL previous = gDKProbeInternalRead;
    gDKProbeInternalRead = YES;
    NSUInteger nodeCount = 0;
    NSDictionary *tree = DKProbeViewSnapshot(container, 0, &nodeCount);
    gDKProbeInternalRead = previous;
    return @{
        @"reason": reason ?: @"",
        @"nodeCount": @(nodeCount),
        @"truncated": @(nodeCount >= 384),
        @"tree": tree ?: @{},
    };
}

static void DKProbeAppendDeferredSnapshot(UIView *container, NSString *reason) {
    if (!container) return;
    // 防止长时间滑动产生无限大的深快照；紧凑调用时间线仍会完整保留在事件环中。
    if (gDKProbeSnapshotCount >= 256) {
        gDKProbeSnapshotDropped++;
        return;
    }
    NSDictionary *snapshot = DKProbeContainerSnapshot(container, reason);
    gDKProbeSnapshotCount++;
    DKProbeAppendEvent(@"snapshot.container", container, container, snapshot);
}

static void DKProbeArmTouchSnapshots(UIView *container, NSString *reason) {
    if (!container) return;
    gDKProbeCaptureGeneration++;
    DKProbeArmCapture(container, 0.65);
    gDKProbeFramesToSnapshot = MAX(gDKProbeFramesToSnapshot, 6);
    gDKProbeRunLoopsToSnapshot = MAX(gDKProbeRunLoopsToSnapshot, 8);
    DKProbeAppendEvent(@"snapshot.armed", container, container,
        @{ @"reason": reason ?: @"" });

    __weak UIView *weakContainer = container;
    NSUInteger generation = gDKProbeCaptureGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongContainer = weakContainer;
        if (!strongContainer || generation != gDKProbeCaptureGeneration) return;
        DKProbeAppendDeferredSnapshot(strongContainer, @"mainQueue.nextTurn");
    });
}

static void DKProbeCollectContainers(UIView *view, NSMutableArray<UIView *> *output) {
    if (!view) return;
    NSString *name = DKProbeClassName(view);
    if ([name isEqualToString:kDKProbeCellClass]
        || [name isEqualToString:kDKProbeFooterClass]) {
        [output addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) DKProbeCollectContainers(subview, output);
}

static UIView *DKProbeContainerAtWindowPoint(UIWindow *window, CGPoint point) {
    UIView *panel = DKCommentGlassCurrentSlot();
    if (!window || !panel || panel.window != window) return nil;
    NSMutableArray<UIView *> *containers = [NSMutableArray array];
    DKProbeCollectContainers(panel, containers);
    UIView *best = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    for (UIView *container in containers) {
        if (container.hidden || container.alpha < 0.01 || !container.window) continue;
        CGRect rect = [container convertRect:container.bounds toView:window];
        if (!CGRectContainsPoint(rect, point)) continue;
        CGFloat area = CGRectGetWidth(rect) * CGRectGetHeight(rect);
        if (area < bestArea) {
            best = container;
            bestArea = area;
        }
    }
    return best;
}

NSDictionary *DKCommentRenderProbeCurrentSnapshotJSON(void) {
    __block NSDictionary *snapshot = nil;
    void (^capture)(void) = ^{
        UIView *panel = DKCommentGlassCurrentSlot();
        if (!panel) {
            snapshot = @{
                @"schemaVersion": @"dykiller.comment-render-snapshot.v1",
                @"panel": @{},
                @"containers": @[],
            };
            return;
        }
        NSMutableArray<UIView *> *containers = [NSMutableArray array];
        DKProbeCollectContainers(panel, containers);
        NSMutableArray *containerJSON = [NSMutableArray arrayWithCapacity:containers.count];
        for (UIView *container in containers) {
            if (!container.window || container.hidden || container.alpha < 0.01) continue;
            [containerJSON addObject:DKProbeContainerSnapshot(container, @"debugExport.current")];
        }
        snapshot = @{
            @"schemaVersion": @"dykiller.comment-render-snapshot.v1",
            @"capturedMonoMs": @((CACurrentMediaTime() - gDKProbeStartTime) * 1000.0),
            @"frame": @(gDKProbeFrameSequence),
            @"runLoop": @(gDKProbeRunLoopSequence),
            @"panel": DKProbeObjectIdentity(panel),
            @"visibleContainerCount": @(containerJSON.count),
            @"containers": containerJSON,
        };
    };
    if ([NSThread isMainThread]) capture();
    else dispatch_sync(dispatch_get_main_queue(), capture);
    return snapshot ?: @{};
}

#pragma mark - 运行时方法清单

static NSDictionary *DKProbeRuntimeClassInventory(Class target) {
    if (!target) return @{};
    NSMutableArray *chain = [NSMutableArray array];
    NSUInteger depth = 0;
    for (Class cls = target; cls && depth < 20; cls = class_getSuperclass(cls), depth++) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        NSMutableArray *methodJSON = [NSMutableArray arrayWithCapacity:count];
        for (unsigned int index = 0; index < count; index++) {
            Method method = methods[index];
            SEL selector = method_getName(method);
            const char *types = method_getTypeEncoding(method);
            [methodJSON addObject:@{
                @"selector": NSStringFromSelector(selector) ?: @"",
                @"types": types ? [NSString stringWithUTF8String:types] : @"",
                @"implementation": DKProbeImplementationPointer(
                    method_getImplementation(method)),
            }];
        }
        free(methods);
        [methodJSON sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
            return [lhs[@"selector"] compare:rhs[@"selector"]];
        }];
        [chain addObject:@{
            @"class": NSStringFromClass(cls) ?: @"",
            @"address": DKProbePointer((__bridge const void *)cls),
            @"image": [NSString stringWithUTF8String:class_getImageName(cls) ?: ""] ?: @"",
            @"methods": methodJSON,
        }];
    }
    return @{
        @"target": NSStringFromClass(target) ?: @"",
        @"chain": chain,
    };
}

#pragma mark - CommentNewCell 精确动态 hook

static IMP gDKOrigCellSetHighlighted;
static IMP gDKOrigCellSetSelected;
static IMP gDKOrigCellSetHighlightedAnimated;
static IMP gDKOrigCellSetSelectedAnimated;
static IMP gDKOrigCellPrepareForReuse;
static IMP gDKOrigCellLayoutSubviews;
static IMP gDKOrigCellDidMoveToWindow;
static IMP gDKOrigCellTintColorDidChange;
static IMP gDKOrigCellTraitCollectionDidChange;
static IMP gDKOrigCellTouchesBegan;
static IMP gDKOrigCellTouchesMoved;
static IMP gDKOrigCellTouchesEnded;
static IMP gDKOrigCellTouchesCancelled;
static IMP gDKOrigCellApplyLayoutAttributes;
static IMP gDKOrigCellUpdateConfiguration;
static IMP gDKOrigCellWillTransitionState;
static IMP gDKOrigCellDidTransitionState;

static NSDictionary *DKProbeCellCoreState(UIView *cell) {
    if (!cell) return @{};
    BOOL highlighted = DKProbeBoolSelector(cell, @selector(isHighlighted), NO);
    BOOL selected = DKProbeBoolSelector(cell, @selector(isSelected), NO);
    return @{
        @"highlighted": @(highlighted),
        @"selected": @(selected),
        @"frame": NSStringFromCGRect(cell.frame),
        @"bounds": NSStringFromCGRect(cell.bounds),
        @"backgroundColor": DKProbeUIColor(cell.backgroundColor, cell),
        @"tintColor": DKProbeUIColor(cell.tintColor, cell),
        @"alpha": @(cell.alpha),
        @"hidden": @(cell.hidden),
        @"opaque": @(cell.opaque),
        @"layer": DKProbeLayerState(cell.layer, YES),
    };
}

static void DKProbeRecordCellCall(UIView *cell, NSString *event, NSDictionary *extra) {
    if (!DKProbeClassEquals(cell, kDKProbeCellClass)) return;
    BOOL previous = gDKProbeInternalRead;
    gDKProbeInternalRead = YES;
    NSDictionary *state = DKProbeCellCoreState(cell);
    gDKProbeInternalRead = previous;
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithObject:state
                                                                       forKey:@"cellState"];
    if (extra.count) [details addEntriesFromDictionary:extra];
    DKProbeAppendEvent(event, cell, cell, details);
}

static void DKProbeCellSetHighlighted(id self, SEL selector, BOOL value) {
    UIView *cell = self;
    DKProbeArmCapture(cell, 0.65);
    gDKProbeFramesToSnapshot = MAX(gDKProbeFramesToSnapshot, 6);
    gDKProbeRunLoopsToSnapshot = MAX(gDKProbeRunLoopsToSnapshot, 8);
    DKProbeRecordCellCall(cell, @"cell.setHighlighted.before", @{ @"value": @(value) });
    ((void (*)(id, SEL, BOOL))gDKOrigCellSetHighlighted)(self, selector, value);
    DKProbeRecordCellCall(cell, @"cell.setHighlighted.after", @{ @"value": @(value) });
}

static void DKProbeCellSetSelected(id self, SEL selector, BOOL value) {
    UIView *cell = self;
    DKProbeArmCapture(cell, 0.65);
    DKProbeRecordCellCall(cell, @"cell.setSelected.before", @{ @"value": @(value) });
    ((void (*)(id, SEL, BOOL))gDKOrigCellSetSelected)(self, selector, value);
    DKProbeRecordCellCall(cell, @"cell.setSelected.after", @{ @"value": @(value) });
}

static void DKProbeCellSetHighlightedAnimated(id self, SEL selector, BOOL value, BOOL animated) {
    UIView *cell = self;
    DKProbeArmCapture(cell, 0.65);
    NSDictionary *extra = @{ @"value": @(value), @"animated": @(animated) };
    DKProbeRecordCellCall(cell, @"cell.setHighlightedAnimated.before", extra);
    ((void (*)(id, SEL, BOOL, BOOL))gDKOrigCellSetHighlightedAnimated)(
        self, selector, value, animated);
    DKProbeRecordCellCall(cell, @"cell.setHighlightedAnimated.after", extra);
}

static void DKProbeCellSetSelectedAnimated(id self, SEL selector, BOOL value, BOOL animated) {
    UIView *cell = self;
    DKProbeArmCapture(cell, 0.65);
    NSDictionary *extra = @{ @"value": @(value), @"animated": @(animated) };
    DKProbeRecordCellCall(cell, @"cell.setSelectedAnimated.before", extra);
    ((void (*)(id, SEL, BOOL, BOOL))gDKOrigCellSetSelectedAnimated)(
        self, selector, value, animated);
    DKProbeRecordCellCall(cell, @"cell.setSelectedAnimated.after", extra);
}

static void DKProbeCellPrepareForReuse(id self, SEL selector) {
    UIView *cell = self;
    DKProbeRecordCellCall(cell, @"cell.prepareForReuse.before", nil);
    ((void (*)(id, SEL))gDKOrigCellPrepareForReuse)(self, selector);
    DKProbeRecordCellCall(cell, @"cell.prepareForReuse.after", nil);
}

static void DKProbeCellLayoutSubviews(id self, SEL selector) {
    UIView *cell = self;
    BOOL firstLayout = ![objc_getAssociatedObject(cell, &kDKProbeCellFirstLayoutKey) boolValue];
    if (firstLayout) {
        objc_setAssociatedObject(cell, &kDKProbeCellFirstLayoutKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL trace = DKProbeCaptureIsActive() || firstLayout;
    if (trace) DKProbeRecordCellCall(cell, @"cell.layoutSubviews.before", nil);
    ((void (*)(id, SEL))gDKOrigCellLayoutSubviews)(self, selector);
    if (trace) DKProbeRecordCellCall(cell, @"cell.layoutSubviews.after", nil);
}

static void DKProbeCellDidMoveToWindow(id self, SEL selector) {
    UIView *cell = self;
    DKProbeRecordCellCall(cell, @"cell.didMoveToWindow.before", nil);
    ((void (*)(id, SEL))gDKOrigCellDidMoveToWindow)(self, selector);
    DKProbeRecordCellCall(cell, @"cell.didMoveToWindow.after", nil);
}

static void DKProbeCellTintColorDidChange(id self, SEL selector) {
    UIView *cell = self;
    DKProbeRecordCellCall(cell, @"cell.tintColorDidChange.before", nil);
    ((void (*)(id, SEL))gDKOrigCellTintColorDidChange)(self, selector);
    DKProbeRecordCellCall(cell, @"cell.tintColorDidChange.after", nil);
}

static void DKProbeCellTraitCollectionDidChange(id self, SEL selector, id previous) {
    UIView *cell = self;
    DKProbeRecordCellCall(cell, @"cell.traitCollectionDidChange.before",
                          @{ @"previous": DKProbeObjectIdentity(previous) });
    ((void (*)(id, SEL, id))gDKOrigCellTraitCollectionDidChange)(self, selector, previous);
    DKProbeRecordCellCall(cell, @"cell.traitCollectionDidChange.after",
                          @{ @"previous": DKProbeObjectIdentity(previous) });
}

static void DKProbeCellTouches(id self, SEL selector, NSSet *touches, UIEvent *event,
                               IMP original, NSString *phase) {
    UIView *cell = self;
    DKProbeArmTouchSnapshots(cell, [@"cell." stringByAppendingString:phase]);
    NSDictionary *extra = @{
        @"touchCount": @(touches.count),
        @"event": DKProbeObjectIdentity(event),
    };
    DKProbeRecordCellCall(cell, [NSString stringWithFormat:@"cell.%@.before", phase], extra);
    ((void (*)(id, SEL, NSSet *, UIEvent *))original)(self, selector, touches, event);
    DKProbeRecordCellCall(cell, [NSString stringWithFormat:@"cell.%@.after", phase], extra);
}

static void DKProbeCellTouchesBegan(id self, SEL selector, NSSet *touches, UIEvent *event) {
    DKProbeCellTouches(self, selector, touches, event, gDKOrigCellTouchesBegan, @"touchesBegan");
}
static void DKProbeCellTouchesMoved(id self, SEL selector, NSSet *touches, UIEvent *event) {
    DKProbeCellTouches(self, selector, touches, event, gDKOrigCellTouchesMoved, @"touchesMoved");
}
static void DKProbeCellTouchesEnded(id self, SEL selector, NSSet *touches, UIEvent *event) {
    DKProbeCellTouches(self, selector, touches, event, gDKOrigCellTouchesEnded, @"touchesEnded");
}
static void DKProbeCellTouchesCancelled(id self, SEL selector, NSSet *touches, UIEvent *event) {
    DKProbeCellTouches(self, selector, touches, event, gDKOrigCellTouchesCancelled,
                       @"touchesCancelled");
}

static void DKProbeCellObjectArgument(id self, SEL selector, id argument,
                                      IMP original, NSString *event) {
    UIView *cell = self;
    DKProbeRecordCellCall(cell, [event stringByAppendingString:@".before"],
                          @{ @"argument": DKProbeObjectIdentity(argument) });
    ((void (*)(id, SEL, id))original)(self, selector, argument);
    DKProbeRecordCellCall(cell, [event stringByAppendingString:@".after"],
                          @{ @"argument": DKProbeObjectIdentity(argument) });
}

static void DKProbeCellApplyLayoutAttributes(id self, SEL selector, id argument) {
    DKProbeCellObjectArgument(self, selector, argument, gDKOrigCellApplyLayoutAttributes,
                              @"cell.applyLayoutAttributes");
}
static void DKProbeCellUpdateConfiguration(id self, SEL selector, id argument) {
    DKProbeCellObjectArgument(self, selector, argument, gDKOrigCellUpdateConfiguration,
                              @"cell.updateConfigurationUsingState");
}

static void DKProbeCellTransitionState(id self, SEL selector, NSUInteger state,
                                       IMP original, NSString *event) {
    UIView *cell = self;
    NSDictionary *extra = @{ @"state": @(state) };
    DKProbeRecordCellCall(cell, [event stringByAppendingString:@".before"], extra);
    ((void (*)(id, SEL, NSUInteger))original)(self, selector, state);
    DKProbeRecordCellCall(cell, [event stringByAppendingString:@".after"], extra);
}
static void DKProbeCellWillTransitionState(id self, SEL selector, NSUInteger state) {
    DKProbeCellTransitionState(self, selector, state, gDKOrigCellWillTransitionState,
                               @"cell.willTransitionToState");
}
static void DKProbeCellDidTransitionState(id self, SEL selector, NSUInteger state) {
    DKProbeCellTransitionState(self, selector, state, gDKOrigCellDidTransitionState,
                               @"cell.didTransitionToState");
}

static Method DKProbeDirectMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            found = methods[index];
            break;
        }
    }
    free(methods);
    return found;
}

static BOOL DKProbeInstallCellOverride(Class cls,
                                       SEL selector,
                                       IMP replacement,
                                       IMP *originalStorage,
                                       unsigned int expectedArguments) {
    Method resolved = class_getInstanceMethod(cls, selector);
    if (!resolved || method_getNumberOfArguments(resolved) != expectedArguments) return NO;
    IMP original = method_getImplementation(resolved);
    const char *types = method_getTypeEncoding(resolved);
    Method direct = DKProbeDirectMethod(cls, selector);
    if (direct) method_setImplementation(direct, replacement);
    else if (!class_addMethod(cls, selector, replacement, types)) return NO;
    *originalStorage = original;
    [gDKProbeInstalledCellHooks addObject:NSStringFromSelector(selector) ?: @""];
    return YES;
}

static void DKProbeTryInstallCellHooks(void) {
    if (gDKProbeCellHooksInstalled) return;
    gDKProbeCellHookAttempts++;
    Class cls = NSClassFromString(kDKProbeCellClass);
    if (!cls) {
        if (gDKProbeCellHookAttempts < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ DKProbeTryInstallCellHooks(); });
        }
        return;
    }

    gDKProbeOriginalCellRuntime = DKProbeRuntimeClassInventory(cls);
    DKProbeInstallCellOverride(cls, @selector(setHighlighted:),
        (IMP)DKProbeCellSetHighlighted, &gDKOrigCellSetHighlighted, 3);
    DKProbeInstallCellOverride(cls, @selector(setSelected:),
        (IMP)DKProbeCellSetSelected, &gDKOrigCellSetSelected, 3);
    DKProbeInstallCellOverride(cls, NSSelectorFromString(@"setHighlighted:animated:"),
        (IMP)DKProbeCellSetHighlightedAnimated, &gDKOrigCellSetHighlightedAnimated, 4);
    DKProbeInstallCellOverride(cls, NSSelectorFromString(@"setSelected:animated:"),
        (IMP)DKProbeCellSetSelectedAnimated, &gDKOrigCellSetSelectedAnimated, 4);
    DKProbeInstallCellOverride(cls, @selector(prepareForReuse),
        (IMP)DKProbeCellPrepareForReuse, &gDKOrigCellPrepareForReuse, 2);
    DKProbeInstallCellOverride(cls, @selector(layoutSubviews),
        (IMP)DKProbeCellLayoutSubviews, &gDKOrigCellLayoutSubviews, 2);
    DKProbeInstallCellOverride(cls, @selector(didMoveToWindow),
        (IMP)DKProbeCellDidMoveToWindow, &gDKOrigCellDidMoveToWindow, 2);
    DKProbeInstallCellOverride(cls, @selector(tintColorDidChange),
        (IMP)DKProbeCellTintColorDidChange, &gDKOrigCellTintColorDidChange, 2);
    DKProbeInstallCellOverride(cls, @selector(traitCollectionDidChange:),
        (IMP)DKProbeCellTraitCollectionDidChange, &gDKOrigCellTraitCollectionDidChange, 3);
    DKProbeInstallCellOverride(cls, @selector(touchesBegan:withEvent:),
        (IMP)DKProbeCellTouchesBegan, &gDKOrigCellTouchesBegan, 4);
    DKProbeInstallCellOverride(cls, @selector(touchesMoved:withEvent:),
        (IMP)DKProbeCellTouchesMoved, &gDKOrigCellTouchesMoved, 4);
    DKProbeInstallCellOverride(cls, @selector(touchesEnded:withEvent:),
        (IMP)DKProbeCellTouchesEnded, &gDKOrigCellTouchesEnded, 4);
    DKProbeInstallCellOverride(cls, @selector(touchesCancelled:withEvent:),
        (IMP)DKProbeCellTouchesCancelled, &gDKOrigCellTouchesCancelled, 4);
    DKProbeInstallCellOverride(cls, NSSelectorFromString(@"applyLayoutAttributes:"),
        (IMP)DKProbeCellApplyLayoutAttributes, &gDKOrigCellApplyLayoutAttributes, 3);
    DKProbeInstallCellOverride(cls, NSSelectorFromString(@"updateConfigurationUsingState:"),
        (IMP)DKProbeCellUpdateConfiguration, &gDKOrigCellUpdateConfiguration, 3);
    DKProbeInstallCellOverride(cls, NSSelectorFromString(@"willTransitionToState:"),
        (IMP)DKProbeCellWillTransitionState, &gDKOrigCellWillTransitionState, 3);
    DKProbeInstallCellOverride(cls, NSSelectorFromString(@"didTransitionToState:"),
        (IMP)DKProbeCellDidTransitionState, &gDKOrigCellDidTransitionState, 3);
    gDKProbeCellHooksInstalled = YES;
    DKProbeAppendEvent(@"probe.cellHooksInstalled", cls, nil, @{
        @"hooks": [gDKProbeInstalledCellHooks copy],
        @"attempts": @(gDKProbeCellHookAttempts),
    });
}

#pragma mark - 触摸与 UIKit 调用链

static NSString *DKProbeTouchPhaseName(UITouchPhase phase) {
    switch (phase) {
        case UITouchPhaseBegan: return @"began";
        case UITouchPhaseMoved: return @"moved";
        case UITouchPhaseStationary: return @"stationary";
        case UITouchPhaseEnded: return @"ended";
        case UITouchPhaseCancelled: return @"cancelled";
        default: return [NSString stringWithFormat:@"%ld", (long)phase];
    }
}

static NSArray *DKProbeTouchRecords(UIWindow *window,
                                    UIEvent *event,
                                    UIView **firstContainer) {
    NSMutableArray *records = [NSMutableArray array];
    for (UITouch *touch in event.allTouches ?: [NSSet set]) {
        UIView *view = touch.view;
        CGPoint point = [touch locationInView:window];
        UIView *container = DKProbeContainerForView(view);
        if (!container) container = DKProbeContainerAtWindowPoint(window, point);
        if (!*firstContainer && container) *firstContainer = container;
        if (!container && !DKProbeViewIsInsidePanel(view)) continue;

        NSMutableArray *gestures = [NSMutableArray array];
        for (UIGestureRecognizer *gesture in touch.gestureRecognizers ?: @[]) {
            [gestures addObject:DKProbeGestureState(gesture)];
        }
        CGPoint local = container ? [touch locationInView:container] : CGPointZero;
        [records addObject:@{
            @"touch": DKProbeObjectPointer(touch),
            @"phase": DKProbeTouchPhaseName(touch.phase),
            @"timestamp": @(touch.timestamp),
            @"tapCount": @(touch.tapCount),
            @"type": @(touch.type),
            @"majorRadius": @(touch.majorRadius),
            @"windowPoint": NSStringFromCGPoint(point),
            @"containerPoint": container ? NSStringFromCGPoint(local) : @"",
            @"view": DKProbeObjectIdentity(view),
            @"container": DKProbeObjectIdentity(container),
            @"gestures": gestures,
        }];
    }
    return records;
}

static NSDictionary *DKProbeCompactViewState(UIView *view) {
    if (!view) return @{};
    return @{
        @"backgroundColor": DKProbeUIColor(view.backgroundColor, view),
        @"tintColor": DKProbeUIColor(view.tintColor, view),
        @"alpha": @(view.alpha),
        @"hidden": @(view.hidden),
        @"opaque": @(view.opaque),
        @"clipsToBounds": @(view.clipsToBounds),
        @"userInteractionEnabled": @(view.userInteractionEnabled),
        @"frame": NSStringFromCGRect(view.frame),
        @"bounds": NSStringFromCGRect(view.bounds),
        @"layer": DKProbeLayerState(view.layer, YES),
    };
}

static void DKProbeRecordViewMutation(UIView *view,
                                      NSString *event,
                                      NSDictionary *requested) {
    UIView *container = DKProbeContainerForView(view);
    if (!container) return;
    BOOL previous = gDKProbeInternalRead;
    gDKProbeInternalRead = YES;
    NSDictionary *state = DKProbeCompactViewState(view);
    gDKProbeInternalRead = previous;
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithObject:state
                                                                       forKey:@"viewState"];
    if (requested.count) [details addEntriesFromDictionary:requested];
    DKProbeAppendEvent(event, view, container, details);
}

%group DKCommentRenderProbeUIKitHooks

%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    if (!gDKProbeCellHooksInstalled) DKProbeTryInstallCellHooks();
    if (event.type != UIEventTypeTouches) {
        %orig;
        return;
    }

    UIView *beforeContainer = nil;
    NSArray *beforeTouches = DKProbeTouchRecords(self, event, &beforeContainer);
    if (beforeContainer) {
        DKProbeArmTouchSnapshots(beforeContainer, @"UIWindow.sendEvent.before");
        DKProbeAppendEvent(@"window.sendEvent.before", event, beforeContainer,
                           @{ @"touches": beforeTouches });
    }
    %orig;

    UIView *afterContainer = nil;
    NSArray *afterTouches = DKProbeTouchRecords(self, event, &afterContainer);
    if (afterContainer) {
        if (!beforeContainer) {
            DKProbeArmTouchSnapshots(afterContainer, @"UIWindow.sendEvent.after");
        } else {
            DKProbeArmCapture(afterContainer, 0.65);
        }
        DKProbeAppendEvent(@"window.sendEvent.after", event, afterContainer,
                           @{ @"touches": afterTouches });
    }
}

%end

%hook UIApplication

- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    UIView *view = [sender isKindOfClass:UIView.class] ? sender : nil;
    if (!view && [sender isKindOfClass:UIGestureRecognizer.class]) {
        view = ((UIGestureRecognizer *)sender).view;
    }
    UIView *container = DKProbeContainerForView(view);
    BOOL trace = container || (DKProbeCaptureIsActive() && DKProbeViewIsInsidePanel(view));
    if (trace) {
        DKProbeAppendEvent(@"application.sendAction.before", sender, container, @{
            @"selector": NSStringFromSelector(action) ?: @"",
            @"target": DKProbeObjectIdentity(target),
            @"sender": DKProbeObjectIdentity(sender),
            @"event": DKProbeObjectIdentity(event),
        });
    }
    BOOL result = %orig;
    if (trace) {
        DKProbeAppendEvent(@"application.sendAction.after", sender, container,
                           @{ @"result": @(result) });
    }
    return result;
}

%end

%hook UIGestureRecognizer

- (void)setState:(UIGestureRecognizerState)state {
    UIView *view = self.view;
    UIView *container = DKProbeContainerForView(view);
    BOOL trace = container || (DKProbeCaptureIsActive() && DKProbeViewIsInsidePanel(view));
    UIGestureRecognizerState previous = self.state;
    if (trace) {
        DKProbeAppendEvent(@"gesture.setState.before", self, container, @{
            @"from": @(previous), @"to": @(state), @"view": DKProbeObjectIdentity(view)
        });
    }
    %orig;
    if (trace) {
        DKProbeAppendEvent(@"gesture.setState.after", self, container,
                           @{ @"state": @(self.state) });
    }
}

%end

%hook UIView

- (void)setBackgroundColor:(UIColor *)color {
    UIView *container = DKProbeContainerForView(self);
    if (container) {
        DKProbeRecordViewMutation(self, @"view.setBackgroundColor.before",
                                   @{ @"requested": DKProbeUIColor(color, self) });
    }
    %orig;
    if (container) DKProbeRecordViewMutation(self, @"view.setBackgroundColor.after", nil);
}

- (void)setOpaque:(BOOL)opaque {
    UIView *container = DKProbeContainerForView(self);
    if (container) {
        DKProbeRecordViewMutation(self, @"view.setOpaque.before",
                                   @{ @"requested": @(opaque) });
    }
    %orig;
    if (container) DKProbeRecordViewMutation(self, @"view.setOpaque.after", nil);
}

- (void)setAlpha:(CGFloat)alpha {
    UIView *container = DKProbeContainerForView(self);
    if (container) {
        DKProbeRecordViewMutation(self, @"view.setAlpha.before",
                                   @{ @"requested": @(alpha) });
    }
    %orig;
    if (container) DKProbeRecordViewMutation(self, @"view.setAlpha.after", nil);
}

- (void)setHidden:(BOOL)hidden {
    UIView *container = DKProbeContainerForView(self);
    if (container) {
        DKProbeRecordViewMutation(self, @"view.setHidden.before",
                                   @{ @"requested": @(hidden) });
    }
    %orig;
    if (container) DKProbeRecordViewMutation(self, @"view.setHidden.after", nil);
}

- (void)setTintColor:(UIColor *)color {
    UIView *container = DKProbeContainerForView(self);
    if (container) {
        DKProbeRecordViewMutation(self, @"view.setTintColor.before",
                                   @{ @"requested": DKProbeUIColor(color, self) });
    }
    %orig;
    if (container) DKProbeRecordViewMutation(self, @"view.setTintColor.after", nil);
}

- (void)setClipsToBounds:(BOOL)clips {
    UIView *container = DKProbeContainerForView(self);
    if (container) {
        DKProbeRecordViewMutation(self, @"view.setClipsToBounds.before",
                                   @{ @"requested": @(clips) });
    }
    %orig;
    if (container) DKProbeRecordViewMutation(self, @"view.setClipsToBounds.after", nil);
}

- (void)setUserInteractionEnabled:(BOOL)enabled {
    UIView *container = DKProbeContainerForView(self);
    if (container) {
        DKProbeRecordViewMutation(self, @"view.setUserInteractionEnabled.before",
                                   @{ @"requested": @(enabled) });
    }
    %orig;
    if (container) {
        DKProbeRecordViewMutation(self, @"view.setUserInteractionEnabled.after", nil);
    }
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    UIView *container = DKProbeContainerForView(self) ?: DKProbeContainerForView(subview);
    if (container) {
        DKProbeAppendEvent(@"view.didAddSubview", self, container, @{
            @"subview": DKProbeObjectIdentity(subview),
        });
    }
}

- (void)willRemoveSubview:(UIView *)subview {
    UIView *container = DKProbeContainerForView(self) ?: DKProbeContainerForView(subview);
    if (container) {
        DKProbeAppendEvent(@"view.willRemoveSubview", self, container,
                           @{ @"subview": DKProbeObjectIdentity(subview) });
    }
    %orig;
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
    BOOL trace = DKProbeIsTargetLabel(self);
    if (trace) DKProbeRecordLabelEvent(self, @"label.setText.before",
                                       @{ @"requested": DKProbeStringIdentity(text) });
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.setText.after", nil);
}

- (void)setAttributedText:(NSAttributedString *)text {
    BOOL trace = DKProbeIsTargetLabel(self);
    if (trace) DKProbeRecordLabelEvent(self, @"label.setAttributedText.before", @{
        @"requested": DKProbeStringIdentity(text.string),
        @"requestedRuns": DKProbeAttributedRuns(text),
    });
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.setAttributedText.after", nil);
}

- (void)setTextColor:(UIColor *)color {
    BOOL trace = DKProbeIsTargetLabel(self);
    if (trace) DKProbeRecordLabelEvent(self, @"label.setTextColor.before",
                                       @{ @"requested": DKProbeUIColor(color, self) });
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.setTextColor.after", nil);
}

- (void)setHighlightedTextColor:(UIColor *)color {
    BOOL trace = DKProbeIsTargetLabel(self);
    if (trace) DKProbeRecordLabelEvent(self, @"label.setHighlightedTextColor.before",
                                       @{ @"requested": DKProbeUIColor(color, self) });
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.setHighlightedTextColor.after", nil);
}

- (void)setHighlighted:(BOOL)highlighted {
    BOOL trace = DKProbeIsTargetLabel(self);
    UIView *container = trace ? DKProbeContainerForView(self) : nil;
    if (trace) {
        DKProbeArmCapture(container, 0.45);
        DKProbeRecordLabelEvent(self, @"label.setHighlighted.before",
                                @{ @"requested": @(highlighted) });
    }
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.setHighlighted.after", nil);
}

- (void)setEnabled:(BOOL)enabled {
    BOOL trace = DKProbeIsTargetLabel(self);
    if (trace) DKProbeRecordLabelEvent(self, @"label.setEnabled.before",
                                       @{ @"requested": @(enabled) });
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.setEnabled.after", nil);
}

- (void)_contentDidChange:(long long)change fromContent:(id)content {
    BOOL trace = DKProbeIsTargetLabel(self);
    if (trace) DKProbeRecordLabelEvent(self, @"label.contentDidChange.before", @{
        @"change": @(change), @"fromContent": DKProbeObjectIdentity(content)
    });
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.contentDidChange.after", nil);
}

- (void)setNeedsDisplay {
    BOOL trace = DKProbeIsTargetLabel(self);
    if (trace) DKProbeRecordLabelEvent(self, @"label.setNeedsDisplay.before", nil);
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.setNeedsDisplay.after", nil);
}

- (void)layerWillDraw:(CALayer *)layer {
    BOOL trace = DKProbeIsTargetLabel(self);
    if (trace) DKProbeRecordLabelEvent(self, @"label.layerWillDraw.before",
                                       @{ @"argumentLayer": DKProbeLayerState(layer, YES) });
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.layerWillDraw.after", nil);
}

- (void)drawTextInRect:(CGRect)rect {
    BOOL trace = DKProbeIsTargetLabel(self);
    if (trace) DKProbeRecordLabelEvent(self, @"label.drawText.before",
                                       @{ @"rect": NSStringFromCGRect(rect) });
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.drawText.after", nil);
}

- (void)drawRect:(CGRect)rect {
    BOOL trace = DKProbeIsTargetLabel(self);
    if (trace) DKProbeRecordLabelEvent(self, @"label.drawRect.before",
                                       @{ @"rect": NSStringFromCGRect(rect) });
    %orig;
    if (trace) DKProbeRecordLabelEvent(self, @"label.drawRect.after", nil);
}

%end

%end

#pragma mark - Runloop / frame 边界

@interface DKCommentRenderProbeClock : NSObject
- (void)displayLinkTick:(CADisplayLink *)link;
@end

@implementation DKCommentRenderProbeClock

- (void)displayLinkTick:(CADisplayLink *)link {
    gDKProbeFrameSequence++;
    if (DKProbeCaptureIsActive()) {
        DKProbeAppendEvent(@"frame.displayLink", link, gDKProbeTrackedContainer, @{
            @"timestamp": @(link.timestamp),
            @"targetTimestamp": @(link.targetTimestamp),
            @"duration": @(link.duration),
            @"maximumFramesPerSecond": @(UIScreen.mainScreen.maximumFramesPerSecond),
        });
    }
    UIView *container = gDKProbeTrackedContainer;
    if (container && gDKProbeFramesToSnapshot > 0) {
        gDKProbeFramesToSnapshot--;
        DKProbeAppendDeferredSnapshot(container,
            [NSString stringWithFormat:@"displayLink.frame.%lu",
             (unsigned long)gDKProbeFrameSequence]);
    }
}

@end


static void DKProbeRunLoopObserverCallback(CFRunLoopObserverRef observer,
                                           CFRunLoopActivity activity,
                                           __unused void *info) {
    BOOL early = observer == gDKProbeEarlyObserver;
    if (early && activity == kCFRunLoopAfterWaiting) gDKProbeRunLoopSequence++;
    gDKProbeRunLoopActivity = activity;
    if (DKProbeCaptureIsActive()) {
        DKProbeAppendEvent(early ? @"runLoop.early" : @"runLoop.late",
                           nil, gDKProbeTrackedContainer, @{
            @"activity": DKProbeRunLoopActivityName(activity),
            @"observerOrder": early ? @(-2147483000) : @(2147483000),
        });
    }

    if (!early && activity == kCFRunLoopBeforeWaiting
        && gDKProbeRunLoopsToSnapshot > 0) {
        UIView *container = gDKProbeTrackedContainer;
        gDKProbeRunLoopsToSnapshot--;
        if (container) {
            DKProbeAppendDeferredSnapshot(container,
                [NSString stringWithFormat:@"runLoop.beforeWaiting.%lu",
                 (unsigned long)gDKProbeRunLoopSequence]);
        }
    }
}

static void DKProbeInstallRunLoopAndFrameObservers(void) {
    if (gDKProbeDisplayLink || gDKProbeEarlyObserver || gDKProbeLateObserver) return;
    CFRunLoopObserverContext context = { 0, NULL, NULL, NULL, NULL };
    CFOptionFlags activities = kCFRunLoopAllActivities;
    gDKProbeEarlyObserver = CFRunLoopObserverCreate(kCFAllocatorDefault,
        activities, true, -2147483000, DKProbeRunLoopObserverCallback, &context);
    gDKProbeLateObserver = CFRunLoopObserverCreate(kCFAllocatorDefault,
        activities, true, 2147483000, DKProbeRunLoopObserverCallback, &context);
    if (gDKProbeEarlyObserver) {
        CFRunLoopAddObserver(CFRunLoopGetMain(), gDKProbeEarlyObserver,
                             kCFRunLoopCommonModes);
    }
    if (gDKProbeLateObserver) {
        CFRunLoopAddObserver(CFRunLoopGetMain(), gDKProbeLateObserver,
                             kCFRunLoopCommonModes);
    }

    gDKProbeClock = [DKCommentRenderProbeClock new];
    gDKProbeDisplayLink = [CADisplayLink displayLinkWithTarget:gDKProbeClock
                                                      selector:@selector(displayLinkTick:)];
    [gDKProbeDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    DKProbeAppendEvent(@"probe.clockInstalled", gDKProbeDisplayLink, nil, @{
        @"maximumFramesPerSecond": @(UIScreen.mainScreen.maximumFramesPerSecond),
    });
}

#pragma mark - 导出

NSString *DKCommentRenderProbeTraceJSONL(void) {
    NSArray<NSDictionary *> *events = nil;
    @synchronized (gDKProbeEvents) {
        events = [gDKProbeEvents copy] ?: @[];
    }
    NSMutableString *jsonl = [NSMutableString string];
    for (NSDictionary *event in events) {
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:event
                                                       options:NSJSONWritingSortedKeys
                                                         error:&error];
        if (data) {
            NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (line.length) [jsonl appendFormat:@"%@\n", line];
        } else {
            NSDictionary *fallback = @{
                @"event": @"probe.serializationError",
                @"message": error.localizedDescription ?: @"unknown",
            };
            NSData *fallbackData = [NSJSONSerialization dataWithJSONObject:fallback
                                                                    options:0
                                                                      error:nil];
            NSString *line = [[NSString alloc] initWithData:fallbackData
                                                    encoding:NSUTF8StringEncoding];
            if (line.length) [jsonl appendFormat:@"%@\n", line];
        }
    }
    return jsonl;
}

NSDictionary *DKCommentRenderProbeSummaryJSON(void) {
    NSUInteger eventCount = 0;
    NSUInteger dropped = 0;
    @synchronized (gDKProbeEvents) {
        eventCount = gDKProbeEvents.count;
        dropped = gDKProbeDropped;
    }
    Class cls = NSClassFromString(kDKProbeCellClass);
    return @{
        @"schemaVersion": @"dykiller.comment-render-probe.v1",
        @"eventCapacity": @(kDKProbeEventLimit),
        @"eventCount": @(eventCount),
        @"droppedEvents": @(dropped),
        @"deepSnapshotCount": @(gDKProbeSnapshotCount),
        @"droppedDeepSnapshots": @(gDKProbeSnapshotDropped),
        @"frame": @(gDKProbeFrameSequence),
        @"runLoop": @(gDKProbeRunLoopSequence),
        @"cellHookAttempts": @(gDKProbeCellHookAttempts),
        @"cellHooksInstalled": @(gDKProbeCellHooksInstalled),
        @"installedCellHooks": [gDKProbeInstalledCellHooks copy] ?: @[],
        @"cellRuntimeBeforeHooks": gDKProbeOriginalCellRuntime ?: @{},
        @"cellRuntimeAtExport": DKProbeRuntimeClassInventory(cls),
        @"textFingerprint": @"FNV-1a 64-bit over UTF-8; plaintext is never exported",
        @"coverage": @[
            @"UIWindow touch dispatch before/after",
            @"UIApplication action dispatch and UIGestureRecognizer state",
            @"CommentNewCell exact overrides and runtime method inventory",
            @"UIView and UILabel visual mutations/draw callbacks",
            @"CALayer contents/display/private render-copy/commit callbacks",
            @"_UILabelLayer content/light sublayer lifecycle",
            @"explicit CATransaction, early/late CFRunLoop and CADisplayLink boundaries",
            @"model/presentation/private UILabel layer snapshots",
        ],
    };
}

NSString *DKCommentRenderProbeDiagnosticSummary(void) {
    NSDictionary *summary = DKCommentRenderProbeSummaryJSON();
    return [NSString stringWithFormat:
        @"评论白块因果探针：events=%@/%@ dropped=%@ snapshots=%@ snapshotDropped=%@ "
         "cellHooks=%@ (%@)",
        summary[@"eventCount"], summary[@"eventCapacity"], summary[@"droppedEvents"],
        summary[@"deepSnapshotCount"], summary[@"droppedDeepSnapshots"],
        [summary[@"cellHooksInstalled"] boolValue] ? @"已安装" : @"未安装",
        [summary[@"installedCellHooks"] componentsJoinedByString:@","] ?: @""];
}

#pragma mark - Core Animation 内容、提交与 presentation

static UILabel *DKProbeTargetLabelForLayer(CALayer *layer, UIView **ownerView) {
    for (CALayer *candidate = layer; candidate; candidate = candidate.superlayer) {
        id delegate = candidate.delegate;
        if (![delegate isKindOfClass:UIView.class]) continue;
        UIView *view = delegate;
        if (ownerView && !*ownerView) *ownerView = view;
        for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
            if ([ancestor isKindOfClass:UILabel.class]
                && DKProbeIsTargetLabel((UILabel *)ancestor)) {
                return (UILabel *)ancestor;
            }
            if (DKProbeContainerForView(ancestor)) break;
        }
    }
    return nil;
}

static BOOL DKProbeResolveLayer(CALayer *layer,
                                UIView **ownerView,
                                UIView **container,
                                UILabel **targetLabel) {
    UIView *owner = nil;
    UILabel *label = DKProbeTargetLabelForLayer(layer, &owner);
    UIView *scope = DKProbeContainerForView(owner);
    if (!scope && label) scope = DKProbeContainerForView(label);
    BOOL relevant = label != nil;
    if (!relevant && scope && DKProbeCaptureIsActive()) {
        UIView *tracked = gDKProbeTrackedContainer;
        relevant = !tracked || tracked == scope;
    }
    if (ownerView) *ownerView = owner;
    if (container) *container = scope;
    if (targetLabel) *targetLabel = label;
    return relevant;
}

static void DKProbeRecordLayerEvent(CALayer *layer,
                                    NSString *event,
                                    NSDictionary *extra) {
    if (gDKProbeInternalRead) return;
    UIView *owner = nil;
    UIView *container = nil;
    UILabel *label = nil;
    if (!DKProbeResolveLayer(layer, &owner, &container, &label)) return;
    BOOL previous = gDKProbeInternalRead;
    gDKProbeInternalRead = YES;
    NSDictionary *state = DKProbeLayerState(layer, YES);
    gDKProbeInternalRead = previous;
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithObject:state
                                                                       forKey:@"layerState"];
    details[@"ownerView"] = DKProbeObjectIdentity(owner);
    details[@"targetLabel"] = DKProbeObjectIdentity(label);
    if (extra.count) [details addEntriesFromDictionary:extra];
    DKProbeAppendEvent(event, layer, container, details);
}

%group DKCommentRenderProbeCALayerHooks

%hook CALayer

- (void)setContents:(id)contents {
    DKProbeRecordLayerEvent(self, @"layer.setContents.before",
                            @{ @"requested": DKProbeContentsIdentity(contents) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setContents.after", nil);
}

- (void)setBackgroundColor:(CGColorRef)color {
    DKProbeRecordLayerEvent(self, @"layer.setBackgroundColor.before",
                            @{ @"requested": DKProbeCGColor(color) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setBackgroundColor.after", nil);
}

- (void)setOpaque:(BOOL)opaque {
    DKProbeRecordLayerEvent(self, @"layer.setOpaque.before", @{ @"requested": @(opaque) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setOpaque.after", nil);
}

- (void)setOpacity:(float)opacity {
    DKProbeRecordLayerEvent(self, @"layer.setOpacity.before", @{ @"requested": @(opacity) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setOpacity.after", nil);
}

- (void)setHidden:(BOOL)hidden {
    DKProbeRecordLayerEvent(self, @"layer.setHidden.before", @{ @"requested": @(hidden) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setHidden.after", nil);
}

- (void)setContentsOpaque:(BOOL)opaque {
    DKProbeRecordLayerEvent(self, @"layer.setContentsOpaque.before",
                            @{ @"requested": @(opaque) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setContentsOpaque.after", nil);
}

- (void)setAllowsDisplayCompositing:(BOOL)value {
    DKProbeRecordLayerEvent(self, @"layer.setAllowsDisplayCompositing.before",
                            @{ @"requested": @(value) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setAllowsDisplayCompositing.after", nil);
}

- (void)setRasterizationPrefersDisplayCompositing:(BOOL)value {
    DKProbeRecordLayerEvent(self, @"layer.setRasterizationPrefersDisplayCompositing.before",
                            @{ @"requested": @(value) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setRasterizationPrefersDisplayCompositing.after", nil);
}

- (void)setNeedsDisplay {
    DKProbeRecordLayerEvent(self, @"layer.setNeedsDisplay.before", nil);
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setNeedsDisplay.after", nil);
}

- (void)setNeedsDisplayInRect:(CGRect)rect {
    DKProbeRecordLayerEvent(self, @"layer.setNeedsDisplayInRect.before",
                            @{ @"rect": NSStringFromCGRect(rect) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setNeedsDisplayInRect.after", nil);
}

- (void)displayIfNeeded {
    DKProbeRecordLayerEvent(self, @"layer.displayIfNeeded.before", nil);
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.displayIfNeeded.after", nil);
}

- (void)display {
    DKProbeRecordLayerEvent(self, @"layer.display.before", nil);
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.display.after", nil);
}

- (void)_display {
    DKProbeRecordLayerEvent(self, @"layer._display.before", nil);
    %orig;
    DKProbeRecordLayerEvent(self, @"layer._display.after", nil);
}

- (void)prepareContents {
    DKProbeRecordLayerEvent(self, @"layer.prepareContents.before", nil);
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.prepareContents.after", nil);
}

- (void)invalidateContents {
    DKProbeRecordLayerEvent(self, @"layer.invalidateContents.before", nil);
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.invalidateContents.after", nil);
}

- (void)setContentsChanged {
    DKProbeRecordLayerEvent(self, @"layer.setContentsChanged.before", nil);
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.setContentsChanged.after", nil);
}

- (void)addSublayer:(CALayer *)sublayer {
    DKProbeRecordLayerEvent(self, @"layer.addSublayer.before",
                            @{ @"sublayer": DKProbeObjectIdentity(sublayer) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.addSublayer.after",
                            @{ @"sublayer": DKProbeObjectIdentity(sublayer) });
}

- (void)insertSublayer:(CALayer *)sublayer atIndex:(unsigned int)index {
    DKProbeRecordLayerEvent(self, @"layer.insertSublayer.before", @{
        @"sublayer": DKProbeObjectIdentity(sublayer), @"index": @(index)
    });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.insertSublayer.after", @{
        @"sublayer": DKProbeObjectIdentity(sublayer), @"index": @(index)
    });
}

- (void)removeFromSuperlayer {
    UIView *owner = nil;
    UIView *container = nil;
    UILabel *label = nil;
    BOOL trace = DKProbeResolveLayer(self, &owner, &container, &label);
    if (trace) DKProbeRecordLayerEvent(self, @"layer.removeFromSuperlayer.before", nil);
    %orig;
    if (trace) {
        DKProbeAppendEvent(@"layer.removeFromSuperlayer.after", self, container, @{
            @"ownerView": DKProbeObjectIdentity(owner),
            @"targetLabel": DKProbeObjectIdentity(label),
            @"superlayer": DKProbeObjectIdentity(self.superlayer),
        });
    }
}

- (void *)_copyRenderLayer:(void *)context
                layerFlags:(unsigned int)layerFlags
               commitFlags:(void *)commitFlags {
    DKProbeRecordLayerEvent(self, @"layer.copyRenderLayer.before", @{
        @"contextPointer": DKProbePointer(context),
        @"layerFlags": @(layerFlags),
        @"commitFlagsPointer": DKProbePointer(commitFlags),
    });
    void *renderLayer = %orig;
    DKProbeRecordLayerEvent(self, @"layer.copyRenderLayer.after", @{
        @"renderLayer": DKProbePointer(renderLayer),
        @"contextPointer": DKProbePointer(context),
        @"layerFlags": @(layerFlags),
        @"commitFlagsPointer": DKProbePointer(commitFlags),
    });
    return renderLayer;
}

- (void)_didCommitLayer:(void *)renderLayer {
    DKProbeRecordLayerEvent(self, @"layer.didCommit.before",
                            @{ @"renderLayer": DKProbePointer(renderLayer) });
    %orig;
    DKProbeRecordLayerEvent(self, @"layer.didCommit.after",
                            @{ @"renderLayer": DKProbePointer(renderLayer) });
}

%end

%hook _UILabelLayer

- (void)_clearContents {
    DKProbeRecordLayerEvent((CALayer *)self, @"uiLabelLayer.clearContents.before", nil);
    %orig;
    DKProbeRecordLayerEvent((CALayer *)self, @"uiLabelLayer.clearContents.after", nil);
}

- (void)_updateSublayers {
    DKProbeRecordLayerEvent((CALayer *)self, @"uiLabelLayer.updateSublayers.before", nil);
    %orig;
    DKProbeRecordLayerEvent((CALayer *)self, @"uiLabelLayer.updateSublayers.after", nil);
}

- (void)reactToLightChanged {
    DKProbeRecordLayerEvent((CALayer *)self, @"uiLabelLayer.reactToLight.before", nil);
    %orig;
    DKProbeRecordLayerEvent((CALayer *)self, @"uiLabelLayer.reactToLight.after", nil);
}

- (void)layoutSublayers {
    DKProbeRecordLayerEvent((CALayer *)self, @"uiLabelLayer.layoutSublayers.before", nil);
    %orig;
    DKProbeRecordLayerEvent((CALayer *)self, @"uiLabelLayer.layoutSublayers.after", nil);
}

- (void)setLightContainerView:(UIView *)view {
    DKProbeRecordLayerEvent((CALayer *)self, @"uiLabelLayer.setLightContainerView.before",
                            @{ @"requested": DKProbeObjectIdentity(view) });
    %orig;
    DKProbeRecordLayerEvent((CALayer *)self, @"uiLabelLayer.setLightContainerView.after", nil);
}

%end

%hook CATransaction

+ (void)begin {
    BOOL trace = DKProbeCaptureIsActive();
    if (trace) DKProbeAppendEvent(@"transaction.begin.before", self, gDKProbeTrackedContainer,
                                  @{ @"depth": @(gDKProbeCATransactionDepth) });
    %orig;
    if ([NSThread isMainThread]) {
        gDKProbeCATransactionDepth++;
        gDKProbeCATransactionSequence++;
    }
    if (trace) DKProbeAppendEvent(@"transaction.begin.after", self, gDKProbeTrackedContainer,
                                  @{ @"depth": @(gDKProbeCATransactionDepth) });
}

+ (void)commit {
    BOOL trace = DKProbeCaptureIsActive();
    if (trace) DKProbeAppendEvent(@"transaction.commit.before", self, gDKProbeTrackedContainer,
                                  @{ @"depth": @(gDKProbeCATransactionDepth) });
    %orig;
    if ([NSThread isMainThread]) {
        gDKProbeCATransactionDepth = MAX(0, gDKProbeCATransactionDepth - 1);
        gDKProbeCATransactionSequence++;
    }
    if (trace) DKProbeAppendEvent(@"transaction.commit.after", self, gDKProbeTrackedContainer,
                                  @{ @"depth": @(gDKProbeCATransactionDepth) });
}

+ (void)flush {
    BOOL trace = DKProbeCaptureIsActive();
    if (trace) DKProbeAppendEvent(@"transaction.flush.before", self, gDKProbeTrackedContainer, nil);
    %orig;
    if (trace) DKProbeAppendEvent(@"transaction.flush.after", self, gDKProbeTrackedContainer, nil);
}

+ (void)setDisableActions:(BOOL)value {
    BOOL trace = DKProbeCaptureIsActive();
    if (trace) DKProbeAppendEvent(@"transaction.setDisableActions.before", self,
                                  gDKProbeTrackedContainer, @{ @"value": @(value) });
    %orig;
    if (trace) DKProbeAppendEvent(@"transaction.setDisableActions.after", self,
                                  gDKProbeTrackedContainer,
                                  @{ @"effective": @([CATransaction disableActions]) });
}

+ (void)setAnimationDuration:(CFTimeInterval)duration {
    BOOL trace = DKProbeCaptureIsActive();
    if (trace) DKProbeAppendEvent(@"transaction.setAnimationDuration.before", self,
                                  gDKProbeTrackedContainer, @{ @"value": @(duration) });
    %orig;
    if (trace) DKProbeAppendEvent(@"transaction.setAnimationDuration.after", self,
                                  gDKProbeTrackedContainer,
                                  @{ @"effective": @([CATransaction animationDuration]) });
}

%end

%end

%ctor {
    gDKProbeEvents = [NSMutableArray array];
    gDKProbeInstalledCellHooks = [NSMutableArray array];
    gDKProbeStartTime = CACurrentMediaTime();
    %init(DKCommentRenderProbeUIKitHooks);
    %init(DKCommentRenderProbeCALayerHooks);

    dispatch_async(dispatch_get_main_queue(), ^{
        DKProbeInstallRunLoopAndFrameObservers();
        DKProbeTryInstallCellHooks();
    });
}
