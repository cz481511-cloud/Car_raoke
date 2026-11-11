#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 接住 Objective-C 例外。
/// AVAudioEngine、AVAudioPlayerNode 在狀態不對時（例如引擎說在跑、聲音其實卡住了）會丟出 Objective-C 例外，
/// Swift 的 do/catch 接不到，App 會直接閃退；包在這裡面執行，就會變成 Swift 接得到的錯誤。
@interface ObjCException : NSObject

/// 執行 block；裡面丟出例外時回傳 NO，error 的說明是例外的原因。Swift 裡寫成 try ObjCException.run { ... }
+ (BOOL)run:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
