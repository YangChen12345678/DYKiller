//
//  DKCommentGlass.xm
//  用 iOS 26 系统液态玻璃替换评论面板与输入框的不透明底色。
//  默认使用自适应的 Regular，用户可切换为 Clear；两种材质都不接管文字渲染。
//
//  实现约束：
//
//  · 槽位判据是「子树里唯一不透明的背景色」——面板在 CommentContainerInnerViewController.view，
//    输入栏与输入框各一处。不写死 frame / 层级；其他形态找不到槽位时自动不生效。
//
//  · Regular 不叠加任何 tint，通过玻璃视图的 overrideUserInterfaceStyle 跟随真实场景外观。
//    Clear 浅色不染色，深色沿用 DKGlassTintForStyle 的黑色 30% 染色。
//
//  · 玻璃自身必须有有效圆角，宿主 masksToBounds 只是硬裁、不会给玻璃折射与高光。
//    顶部半径取槽位实时 layer.cornerRadius 作为同心圆角下限；输入框用 capsule。
//
//  · 新建时 effect=nil 挂载，再在转场协调器或短动画中写入 effect，走系统 materialize；
//    禁止用 alpha 淡入（UIVisualEffectView 文档：alpha < 1 会失真甚至不显示）。
//
//  · 主面板玻璃恒为槽位满幅。输入栏容器是面板槽位的兄弟且落在它的矩形之内，所以铺满就已经
//    盖住输入区——输入栏底色槽只清成透明让它透上来，不再单独挂一块玻璃。
//    输入框保持独立胶囊，不使用 UIGlassContainerEffect（嵌套会被合并成同一形状）。
//
//  · 深浅色从 UIWindowScene 的 trait 取：抖音把 window override 钉死为浅色。
//  · interactive 恒为 YES；玻璃不参与 hit-test，触摸源重定向到对应槽位及其子树。
//  · 主面板若已有其他插件的 effect view，整项让行，只移除自身创建的视图。
//

#import "DouyinHeaders.h"
#import "DKCommentGlass.h"
#import "DKGlassFlexView.h"
#import "DKGlassGuard.h"
#import "DKKeys.h"
#import "DKSettings.h"
#import "DKUtils.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>

// 依赖的抖音类名集中在此，抖音改名时只改这里。
static NSString *const kDKInnerControllerClass =
    @"AWECommentPanelContainerSwiftImpl.CommentContainerInnerViewController";
static NSString *const kDKInputContainerClass =
    @"AWECommentInputViewSwiftImpl.CommentInputContainerView";

// 输入栏底色槽的尺寸比对容差。
static const CGFloat kDKSlotSizeTolerance = 0.5;
// 槽位尚未写入圆角时的顶部半径下限，保证玻璃有效半径 > 0。
static const CGFloat kDKTopRadiusFloor = 8.0;
// 没有可复用的页面转场时，材质更换使用这个短动画。
static const NSTimeInterval kDKGlassAnimationDuration = 0.25;

#pragma mark - 状态（全部挂在被改动的视图上，多个评论面板并存也互不干扰）

static char kSlotOriginalColorKey;     // 槽位：抖音写的底色
static char kSlotGlassKey;             // 槽位：我们插的玻璃层
static char kCoverOriginalColorKey;    // 满幅遮盖层：抖音写的底色
static char kTextRefreshScheduledKey;  // 面板：下一轮主线程已排入文字 backing store 刷新
static char kGlassClearModeKey;         // 玻璃：当前 effect 是否按 Clear 构造
static char kGlassStyleKey;             // 玻璃：当前 effect 对应的场景外观
static char kGlassMaterializingKey;     // 玻璃：已排入 materialize，防止重复排队

// 本次会话是否接管过槽位。开关一直关着的用户不必为每帧的查找与还原付出代价。
static BOOL gEverAttached = NO;
// 所有在场的玻璃层，供深浅色切换时统一更新。
static NSHashTable *gGlassCarriers = nil;
// 已清过底色的满幅遮盖层，关开关时还原。
static NSHashTable *gClearedCovers = nil;
// 已挂上深浅色监听的场景，避免重复注册。
static __weak UIWindowScene *gObservedScene = nil;
// 最近接管的面板槽位与输入框槽位，只给调试探针读。
static __weak UIView *gLastPanelSlot = nil;
static __weak UIView *gLastFieldSlot = nil;

UIView *DKCommentGlassCurrentSlot(void) {
    return gLastPanelSlot;
}

UIView *DKCommentGlassCurrentField(void) {
    return gLastFieldSlot;
}

#pragma mark - 小工具

static BOOL DKColorIsOpaque(UIColor *color) {
    return color && CGColorGetAlpha(color.CGColor) >= 0.99;
}

static BOOL DKViewIsVisible(UIView *view) {
    return view && !view.hidden && view.alpha >= 0.01;
}

// 评论列表的 UILabel 与 YYText 会缓存已经栅格化的 backing store。面板复用时，这些文字可能
// 先在不透明白底上完成绘制，随后才由本文件把满幅背景清成透明；属性快照虽然已经是 clear /
// opaque=NO，旧像素却仍会以黑底显示，直到点击触发下一次绘制。
//
// 只失效文字承载层，不碰文本、颜色或业务状态。刷新落到下一轮主线程，让抖音本轮布局和文字赋值
// 先收敛；同一个根视图在一轮 runloop 内只排一次，避免列表布局期间重复刷新。
static BOOL DKIsCachedTextSurface(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) return YES;

    NSString *layerName = NSStringFromClass(view.layer.class);
    return [layerName isEqualToString:@"_UILabelLayer"]
        || [layerName isEqualToString:@"YYTextAsyncLayer"];
}

static void DKInvalidateCachedTextSurfaces(UIView *view) {
    if (!view || [view isKindOfClass:UIVisualEffectView.class]) return;

    if (DKIsCachedTextSurface(view)) {
        [view setNeedsDisplay];
        [view.layer setNeedsDisplay];
    }
    for (UIView *subview in view.subviews) {
        DKInvalidateCachedTextSurfaces(subview);
    }
}

static void DKScheduleTextSurfaceRefresh(UIView *root) {
    if (!root) return;
    if (![NSThread isMainThread]) {
        __weak UIView *weakRoot = root;
        dispatch_async(dispatch_get_main_queue(), ^{
            DKScheduleTextSurfaceRefresh(weakRoot);
        });
        return;
    }
    if ([objc_getAssociatedObject(root, &kTextRefreshScheduledKey) boolValue]) return;

    objc_setAssociatedObject(root, &kTextRefreshScheduledKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakRoot = root;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongRoot = weakRoot;
        if (!strongRoot) return;
        objc_setAssociatedObject(strongRoot, &kTextRefreshScheduledKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DKInvalidateCachedTextSurfaces(strongRoot);
    });
}

// 已接管的背景再次被抖音写回不透明色时，从该视图向上找到玻璃槽位；这样多评论面板并存时，
// 刷新仍严格落在各自子树，不依赖全局的“最近一次面板”。
static UIView *DKTextRefreshRootForManagedView(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if (objc_getAssociatedObject(candidate, &kSlotGlassKey)) return candidate;
    }
    return view;
}

#pragma mark - 材质与外观

// 抖音的 window override 恒为浅色，真实系统外观从 UIWindowScene 取。
static UIUserInterfaceStyle gGlassStyle = UIUserInterfaceStyleUnspecified;

static BOOL DKColorsEqual(UIColor *lhs, UIColor *rhs) {
    return lhs == rhs || [lhs isEqual:rhs];
}

static UIUserInterfaceStyle DKGlassStyleForView(UIView *view) {
    UIUserInterfaceStyle style = view.window.windowScene.traitCollection.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified) style = gGlassStyle;
    if (style == UIUserInterfaceStyleUnspecified) style = view.traitCollection.userInterfaceStyle;
    return style == UIUserInterfaceStyleUnspecified ? UIUserInterfaceStyleLight : style;
}

static BOOL DKCommentGlassEnabled(void) {
    return DKGlassOSAvailable() && DKPrefBool(DKKeyCommentGlass);
}

static BOOL DKCommentGlassUsesClearMaterial(void) {
    return DKGlassOSAvailable() && DKPrefBool(DKKeyCommentGlassClear);
}

static UIUserInterfaceStyle DKGlassOverrideStyle(BOOL clear, UIUserInterfaceStyle style) {
    return clear ? UIUserInterfaceStyleUnspecified : style;
}

static UIColor *DKCommentGlassTint(BOOL clear, UIUserInterfaceStyle style) {
    return clear ? DKGlassTintForStyle(style) : nil;
}

static UIGlassEffect *DKMakeCommentGlassEffect(BOOL clear, UIUserInterfaceStyle style)
    API_AVAILABLE(ios(26.0)) {
    UIGlassEffect *effect = [UIGlassEffect effectWithStyle:
        clear ? UIGlassEffectStyleClear : UIGlassEffectStyleRegular];
    effect.tintColor = DKCommentGlassTint(clear, style);
    effect.interactive = YES;
    return effect;
}

static void DKRunGlassAnimation(UIViewController *controller, BOOL animated, void (^changes)(void)) {
    if (!changes) return;
    if (!animated || UIAccessibilityIsReduceMotionEnabled()) {
        [UIView performWithoutAnimation:changes];
        return;
    }

    id<UIViewControllerTransitionCoordinator> coordinator = controller.transitionCoordinator;
    if (coordinator && coordinator.isAnimated) {
        BOOL accepted = [coordinator
            animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                changes();
            }
            completion:nil];
        if (accepted) return;
    }

    [UIView animateWithDuration:kDKGlassAnimationDuration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                              | UIViewAnimationOptionAllowUserInteraction
                              | UIViewAnimationOptionCurveEaseInOut
                     animations:changes
                     completion:nil];
}

static void DKInstallGlassEffect(UIVisualEffectView *glass, UIGlassEffect *effect,
                                 BOOL clear, UIUserInterfaceStyle style)
    API_AVAILABLE(ios(26.0)) {
    glass.effect = effect;
    objc_setAssociatedObject(glass, &kGlassClearModeKey, @(clear), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(glass, &kGlassStyleKey, @(style), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL DKGlassNeedsAppearance(UIVisualEffectView *glass, BOOL clear, UIUserInterfaceStyle style)
    API_AVAILABLE(ios(26.0)) {
    if (glass.overrideUserInterfaceStyle != DKGlassOverrideStyle(clear, style)) return YES;

    UIGlassEffect *current = [glass.effect isKindOfClass:UIGlassEffect.class]
        ? (UIGlassEffect *)glass.effect : nil;
    if (!current) return glass.effect != nil;

    NSNumber *installedClear = objc_getAssociatedObject(glass, &kGlassClearModeKey);
    NSNumber *installedStyle = objc_getAssociatedObject(glass, &kGlassStyleKey);
    if (!installedClear || installedClear.boolValue != clear) return YES;
    if (!installedStyle || installedStyle.integerValue != style) return YES;
    if (!current.interactive) return YES;
    return !DKColorsEqual(current.tintColor, DKCommentGlassTint(clear, style));
}

// 外观、Regular/Clear 档位或 tint 不变时不重建 effect，避免布局回调打断动画。
static void DKApplyGlassStyle(UIUserInterfaceStyle style, BOOL animated) API_AVAILABLE(ios(26.0)) {
    if (style == UIUserInterfaceStyleUnspecified) return;
    gGlassStyle = style;

    BOOL clear = DKCommentGlassUsesClearMaterial();
    NSArray<UIVisualEffectView *> *carriers = gGlassCarriers.allObjects;
    BOOL needsUpdate = NO;
    for (UIVisualEffectView *glass in carriers) {
        if (DKGlassNeedsAppearance(glass, clear, style)) {
            needsUpdate = YES;
            break;
        }
    }
    if (!needsUpdate) return;

    DKRunGlassAnimation(nil, animated, ^{
        for (UIVisualEffectView *glass in carriers) {
            glass.overrideUserInterfaceStyle = DKGlassOverrideStyle(clear, style);
            if (!glass.effect || !DKGlassNeedsAppearance(glass, clear, style)) continue;
            DKInstallGlassEffect(glass, DKMakeCommentGlassEffect(clear, style), clear, style);
        }
    });
}

// 挂在场景上监听，系统一切深浅色即刻改；否则只能等抖音下次布局。
static void DKObserveGlassStyle(UIView *host) API_AVAILABLE(ios(26.0)) {
    UIWindowScene *scene = host.window.windowScene;
    if (!scene || scene == gObservedScene) return;
    gObservedScene = scene;
    [scene registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]
                       withHandler:^(UIWindowScene *changed, __unused UITraitCollection *previous) {
        DKApplyGlassStyle(changed.traitCollection.userInterfaceStyle, YES);
    }];
}

#pragma mark - 槽位

// 槽位候选：当前带不透明底色，或底色已被我们清掉但记忆还在。
static BOOL DKIsSlotCandidate(UIView *view) {
    return objc_getAssociatedObject(view, &kSlotOriginalColorKey) != nil
        || DKColorIsOpaque(view.backgroundColor);
}

static void DKCollectSlotCandidates(UIView *view, NSUInteger depth, NSMutableArray<UIView *> *candidates) {
    if (depth > 4) return;
    for (UIView *subview in view.subviews) {
        if (DKIsSlotCandidate(subview)) [candidates addObject:subview];
        DKCollectSlotCandidates(subview, depth + 1, candidates);
    }
}

// 半屏与全屏复用同一个评论控制器；槽位按结构解析，认不出时不接管。
static UIView *DKPanelSlot(UIViewController *controller) {
    UIViewController *inner = DKChildControllerNamed(controller, kDKInnerControllerClass);
    return inner.isViewLoaded ? inner.view : nil;
}

static UIView *DKInputContainer(UIViewController *controller) {
    Class containerClass = NSClassFromString(kDKInputContainerClass);
    if (!containerClass || !controller.isViewLoaded) return nil;
    for (UIView *subview in controller.view.subviews) {
        if ([subview isKindOfClass:containerClass]) return subview;
    }
    return nil;
}

// 输入栏有两个槽位：铺满容器的底色槽，以及输入框那枚圆角胶囊。
static void DKResolveInputSlots(UIView *container, UIView **backdrop, UIView **field) {
    *backdrop = nil;
    *field = nil;
    if (!container) return;

    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    DKCollectSlotCandidates(container, 0, candidates);

    CGSize size = container.bounds.size;
    for (UIView *candidate in candidates) {
        CGSize candidateSize = candidate.bounds.size;
        BOOL fillsContainer = fabs(candidateSize.width - size.width) <= kDKSlotSizeTolerance
            && fabs(candidateSize.height - size.height) <= kDKSlotSizeTolerance;
        if (!*backdrop && fillsContainer) {
            *backdrop = candidate;
        } else if (!*field && candidate.layer.cornerRadius > 0.0) {
            *field = candidate;
        }
    }
}

#pragma mark - 玻璃层

// 玻璃要垫在抖音内容之下。其他插件遍历子视图后可能改动层级，每轮校验一次，顺序对就不动。
static void DKEnsureBackmost(UIView *slot, UIView *glass) {
    if (slot.subviews.firstObject == glass) return;
    [slot insertSubview:glass atIndex:0];
}

typedef NS_ENUM(NSUInteger, DKGlassShape) {
    // 上圆下方：面板与输入栏底色槽；顶部半径跟槽位实时 cornerRadius。
    DKGlassShapeTopRounded = 0,
    // 正圆胶囊：输入框那枚控件。
    DKGlassShapeCapsule,
};

// 先以 nil effect 建好视图；挂上视图树并完成几何后再走系统 materialize。
// 用 DKGlassFlexView 而不是裸 UIVisualEffectView：它多一条触摸源重定向，除此之外行为一致。
static UIVisualEffectView *DKMakeGlassShell(void) API_AVAILABLE(ios(26.0)) {
    DKGlassFlexView *glass = [[DKGlassFlexView alloc] initWithEffect:nil];
    glass.userInteractionEnabled = NO;
    glass.alpha = 1.0;
    // 输入框会在常驻态与回复态之间改变尺寸；交给 UIKit 按槽位 bounds 自动跟随。
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    return glass;
}

// 顶部：同心圆角 + 槽位实时半径作下限，保证折射与高光所需的有效圆角。
// 胶囊：系统 capsuleConfiguration，正方形/扁矩形上都保证有效圆角 > 0。
static void DKApplyGlassShape(UIVisualEffectView *glass, UIView *slot, DKGlassShape shape)
    API_AVAILABLE(ios(26.0)) {
    if (shape == DKGlassShapeCapsule) {
        glass.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
        return;
    }

    CGFloat floor = slot.layer.cornerRadius;
    if (floor <= 0.0) floor = kDKTopRadiusFloor;
    UICornerRadius *top = [UICornerRadius containerConcentricRadiusWithMinimum:floor];
    glass.cornerConfiguration =
        [UICornerConfiguration configurationWithUniformTopRadius:top
                                                bottomLeftRadius:nil
                                               bottomRightRadius:nil];
}

// 仅在 effect 仍为 nil 时写入，让系统 materialize 动画跑一次。
static void DKMaterializeGlass(UIVisualEffectView *glass, UIViewController *controller)
    API_AVAILABLE(ios(26.0)) {
    if (!glass || glass.effect || [objc_getAssociatedObject(glass, &kGlassMaterializingKey) boolValue]) return;
    objc_setAssociatedObject(glass, &kGlassMaterializingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    DKRunGlassAnimation(controller, YES, ^{
        if (!glass.superview || !DKCommentGlassEnabled()) {
            objc_setAssociatedObject(glass, &kGlassMaterializingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }

        UIUserInterfaceStyle style = gGlassStyle;
        if (style == UIUserInterfaceStyleUnspecified) style = DKGlassStyleForView(glass);
        BOOL clear = DKCommentGlassUsesClearMaterial();
        glass.overrideUserInterfaceStyle = DKGlassOverrideStyle(clear, style);
        DKInstallGlassEffect(glass, DKMakeCommentGlassEffect(clear, style), clear, style);
        objc_setAssociatedObject(glass, &kGlassMaterializingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

// 记下并清掉槽位的不透明底色。返回 NO 表示这个槽位不该接管——它本来就没有底色。
// 输入栏底色槽只做到这一步：它落在主面板槽位的矩形之内，清成透明后主面板玻璃直接透上来，
// 不必也不该再给它单独一块玻璃。
static BOOL DKClearSlotColor(UIView *slot) {
    if (objc_getAssociatedObject(slot, &kSlotOriginalColorKey)) {
        if (DKColorIsOpaque(slot.backgroundColor)) slot.backgroundColor = UIColor.clearColor;
        return YES;
    }
    UIColor *current = slot.backgroundColor;
    if (!DKColorIsOpaque(current)) return NO;
    objc_setAssociatedObject(slot, &kSlotOriginalColorKey, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    slot.backgroundColor = UIColor.clearColor;
    gEverAttached = YES;
    return YES;
}

// 主面板列表若被涂成不透明色，会盖住垫在最底层的玻璃。只动满幅容器，不动文字/按钮/图片。
static const NSUInteger kDKCoverWalkDepth = 14;
static const CGFloat kDKCoverMinHeight = 8.0;

static BOOL DKIsCoverCandidate(UIView *view, UIView *slot) {
    if (!view || view == slot) return NO;
    if (view.hidden || view.alpha < 0.01) return NO;
    if ([view isKindOfClass:UILabel.class]
        || [view isKindOfClass:UIControl.class]
        || [view isKindOfClass:UIImageView.class]
        || [view isKindOfClass:UIVisualEffectView.class]) {
        return NO;
    }
    if (fabs(CGRectGetWidth(view.bounds) - CGRectGetWidth(slot.bounds)) > 1.0) return NO;
    if (CGRectGetHeight(view.bounds) < kDKCoverMinHeight) return NO;
    return YES;
}

static BOOL DKClearCoverColor(UIView *view) {
    if (objc_getAssociatedObject(view, &kCoverOriginalColorKey)) {
        if (!DKColorIsOpaque(view.backgroundColor)) return NO;
        view.backgroundColor = UIColor.clearColor;
        return YES;
    }
    if (!DKColorIsOpaque(view.backgroundColor)) return NO;
    objc_setAssociatedObject(view, &kCoverOriginalColorKey,
                             view.backgroundColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gClearedCovers addObject:view];
    view.backgroundColor = UIColor.clearColor;
    return YES;
}

static BOOL DKWalkClearCovers(UIView *view, UIView *slot, NSUInteger depth) {
    if (depth > kDKCoverWalkDepth) return NO;
    BOOL changed = NO;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:DKGlassFlexView.class]) continue;
        if (DKIsCoverCandidate(sub, slot)) changed |= DKClearCoverColor(sub);
        if ([sub isKindOfClass:UILabel.class] || [sub isKindOfClass:UIImageView.class]) continue;
        changed |= DKWalkClearCovers(sub, slot, depth + 1);
    }
    return changed;
}

static void DKClearCoverLayers(UIView *slot) {
    if (!slot) return;
    if (DKWalkClearCovers(slot, slot, 0)) DKScheduleTextSurfaceRefresh(slot);
}

static void DKRestoreCoverColor(UIView *view) {
    UIColor *original = objc_getAssociatedObject(view, &kCoverOriginalColorKey);
    if (!original) return;
    objc_setAssociatedObject(view, &kCoverOriginalColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.backgroundColor = original;
}

static void DKRestoreAllCovers(void) {
    NSArray<UIView *> *views = gClearedCovers.allObjects;
    [gClearedCovers removeAllObjects];
    for (UIView *view in views) DKRestoreCoverColor(view);
}

// 接管一个槽位：清掉它的不透明底色，在最底层插一层玻璃壳。
// requireOpaque：输入框胶囊必须本来有底色；主面板槽位按类名认定，底色透明也要挂。
// 返回 nil 表示这个槽位不该接管——已被别的插件插了玻璃，或（输入框）没有底色。
static UIView *DKAttachGlass(UIView *slot, DKGlassShape shape, BOOL requireOpaque)
    API_AVAILABLE(ios(26.0)) {
    UIView *glass = objc_getAssociatedObject(slot, &kSlotGlassKey);
    // 退让只在尚未接管时判定；接管之后层级由 DKEnsureBackmost 维持，不能再据此退出。
    if (!glass && [slot.subviews.firstObject isKindOfClass:UIVisualEffectView.class]) return nil;

    BOOL cleared = DKClearSlotColor(slot);
    if (requireOpaque && !cleared) return nil;

    if (!glass) {
        glass = DKMakeGlassShell();
        objc_setAssociatedObject(slot, &kSlotGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gGlassCarriers addObject:glass];
        gEverAttached = YES;
    }

    // 槽位作为触摸源时包含它的整棵子树，面板列表与输入控件都不必单独枚举。
    ((DKGlassFlexView *)glass).flexSourceView = slot;
    DKApplyGlassShape((UIVisualEffectView *)glass, slot, shape);
    return glass;
}

static void DKDetachGlass(UIView *slot) {
    UIView *glass = objc_getAssociatedObject(slot, &kSlotGlassKey);
    UIColor *original = objc_getAssociatedObject(slot, &kSlotOriginalColorKey);
    if (!glass && !original) return;

    [glass removeFromSuperview];
    objc_setAssociatedObject(slot, &kSlotOriginalColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slot, &kSlotGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // 先解除受管标记再还原；否则下面的 UIView hook 会把这次不透明写入再次拦成 clear。
    if (original) slot.backgroundColor = original;
}

#pragma mark - 同步

// 输入栏在「移除评论区底栏」开启时被压成 alpha 0，此时整段不做；它的显隐 owner 是
// DKCommentBottomBar，这里只读不写。只挂壳与几何，effect 由调用方在 CATransaction 外 materialize。
//
// 底色槽只清成透明，让主面板玻璃透上来；只有输入框那枚胶囊有自己的玻璃。
static void DKSyncInputGlass(UIView *container) API_AVAILABLE(ios(26.0)) {
    if (!DKViewIsVisible(container)) return;

    UIView *backdrop = nil;
    UIView *field = nil;
    DKResolveInputSlots(container, &backdrop, &field);

    if (backdrop) DKClearSlotColor(backdrop);
    if (!field) return;

    // 胶囊不用 UIGlassContainerEffect：嵌套会被合并成同一形状。
    UIVisualEffectView *glass = (UIVisualEffectView *)DKAttachGlass(field, DKGlassShapeCapsule, YES);
    if (!glass) return;
    gLastFieldSlot = field;
    if (!CGRectEqualToRect(glass.frame, field.bounds)) glass.frame = field.bounds;
    DKEnsureBackmost(field, glass);
}

static void DKMaterializeSlotGlass(UIView *slot, UIViewController *controller) API_AVAILABLE(ios(26.0)) {
    if (!slot) return;
    UIVisualEffectView *glass = objc_getAssociatedObject(slot, &kSlotGlassKey);
    if (glass) DKMaterializeGlass(glass, controller);
}

static void DKCommentGlassSync(UIViewController *controller) API_AVAILABLE(ios(26.0)) {
    BOOL enabled = DKCommentGlassEnabled();
    if (!enabled && !gEverAttached) return;

    UIView *panel = DKPanelSlot(controller);
    if (!panel) return;

    UIView *inputContainer = DKInputContainer(controller);

    if (!enabled) {
        // 还原一次即收敛：槽位记忆清空后，后续布局只剩几次空查找。
        DKDetachGlass(panel);
        UIView *backdrop = nil;
        UIView *field = nil;
        DKResolveInputSlots(inputContainer, &backdrop, &field);
        DKDetachGlass(backdrop);
        DKDetachGlass(field);
        DKRestoreAllCovers();
        DKScheduleTextSurfaceRefresh(panel);
        return;
    }

    DKObserveGlassStyle(panel);
    UIUserInterfaceStyle style = DKGlassStyleForView(panel);

    // 本函数可能落在抖音的布局或键盘动画里，隐式动画会让玻璃几何拖在内容后面。
    // materialize 在几何就位后单独执行，不受这个 CATransaction 影响。
    UIVisualEffectView *panelGlass = nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    panelGlass = (UIVisualEffectView *)DKAttachGlass(panel, DKGlassShapeTopRounded, NO);
    if (panelGlass) {
        gLastPanelSlot = panel;

        // 恒为槽位满幅：输入栏容器是本槽位的兄弟且落在它的矩形之内，铺满就已经盖住输入区，
        // 不需要给它让位，也就没有「让了位却没人盖」的时序窗口。
        if (!CGRectEqualToRect(panelGlass.frame, panel.bounds)) panelGlass.frame = panel.bounds;
        DKEnsureBackmost(panel, panelGlass);
        DKClearCoverLayers(panel);

        DKSyncInputGlass(inputContainer);
    }

    [CATransaction commit];

    // 几何就位后统一更新已存在的材质，再让新玻璃从 nil → effect materialize。
    if (panelGlass) {
        DKApplyGlassStyle(style, YES);
        DKMaterializeGlass(panelGlass, controller);
        if (DKViewIsVisible(inputContainer)) {
            UIView *backdrop = nil;
            UIView *field = nil;
            DKResolveInputSlots(inputContainer, &backdrop, &field);
            DKMaterializeSlotGlass(field, controller);
        }
    }
}

#pragma mark - Hook

// DKCommentBottomBar.xm 也在这两个方法上挂了一层（底栏抑制），两处分属两个功能、各有各的开关，
// 本文件这一层还整体受 iOS 26 可用性约束。多层 %hook 会正常串联，两条同时生效。
%group DKCommentGlassHooks

%hook AWECommentContainerViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (@available(iOS 26.0, *)) {
        DKCommentGlassSync(self);
        if (DKCommentGlassEnabled()) {
            DKScheduleTextSurfaceRefresh(DKPanelSlot(self));
        }
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (@available(iOS 26.0, *)) DKCommentGlassSync(self);
}

%end

%hook UIView

- (void)setBackgroundColor:(UIColor *)color {
    if ((objc_getAssociatedObject(self, &kCoverOriginalColorKey)
         || objc_getAssociatedObject(self, &kSlotOriginalColorKey))
        && DKColorIsOpaque(color)) {
        UIView *refreshRoot = DKTextRefreshRootForManagedView(self);
        %orig(UIColor.clearColor);
        DKScheduleTextSurfaceRefresh(refreshRoot);
        return;
    }
    %orig;
}

%end

%end

#pragma mark - 设置项注册

%ctor {
    gGlassCarriers = [NSHashTable weakObjectsHashTable];
    gClearedCovers = [NSHashTable weakObjectsHashTable];

    DKSettingsRegisterItem(@"评论区", ^AWESettingItemModel *{
        return DKMakeSwitch(
            DKKeyCommentGlass,
            @"评论区液态玻璃",
            @"把评论面板与输入框换成 iOS 26 系统液态玻璃；默认使用 Regular 自适应材质"
        );
    });

    DKSettingsRegisterItem(@"评论区", ^AWESettingItemModel *{
        AWESettingItemModel *item = DKMakeSwitch(
            DKKeyCommentGlassClear,
            @"清透玻璃",
            @"显示更多背后视频细节；关闭则使用系统 Regular 自适应材质"
        );
        void (^originalBlock)(void) = [item.switchChangedBlock copy];
        item.switchChangedBlock = ^{
            if (originalBlock) originalBlock();
            void (^refresh)(void) = ^{
                UIView *slot = gLastPanelSlot;
                UIUserInterfaceStyle current = gGlassStyle;
                if (slot.window.windowScene) current = DKGlassStyleForView(slot);
                else if (current == UIUserInterfaceStyleUnspecified && slot) current = DKGlassStyleForView(slot);
                if (@available(iOS 26.0, *)) DKApplyGlassStyle(current, YES);
            };
            if ([NSThread isMainThread]) refresh();
            else dispatch_async(dispatch_get_main_queue(), refresh);
        };
        return item;
    });

    if (DKGlassOSAvailable()) {
        %init(DKCommentGlassHooks);
    }
}
