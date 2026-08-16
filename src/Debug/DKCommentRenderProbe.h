//
//  DKCommentRenderProbe.h
//  DYKiller
//
//  iOS 27 评论文字白块的只读因果探针。它只记录调用、runloop / frame / CA commit
//  边界以及模型层 / presentation layer / UILabel 私有子层身份，不主动刷新或改写 UI。
//

#ifndef DKCommentRenderProbe_h
#define DKCommentRenderProbe_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 供评论玻璃现有刷新路径写入明确的脉冲/调度标记；不读取或修改视图状态。
void DKCommentRenderProbeMarkViewEvent(UIView *view, NSString *event);

/// 当前事件环的 JSON Lines 快照。每行一个完整 JSON 对象。
NSString *DKCommentRenderProbeTraceJSONL(void);

/// 探针容量、丢弃量、动态 Cell hook 结果及运行时方法清单。
NSDictionary *DKCommentRenderProbeSummaryJSON(void);

/// 主线程只读快照：当前可见 CommentNewCell / Footer、全部 UILabel 和私有文字层。
NSDictionary *DKCommentRenderProbeCurrentSnapshotJSON(void);

/// probe/tabbar.txt 中使用的一行摘要。
NSString *DKCommentRenderProbeDiagnosticSummary(void);

#ifdef __cplusplus
}
#endif

#endif /* DKCommentRenderProbe_h */
