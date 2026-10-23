// BiliPiliAutoOpen.mm
// PiliPlus 剪贴板自动打开 dylib
//
// 行为：
//   1. 冷启动 1.5s 后读一次剪贴板
//   2. 每次回到前台（DidBecomeActive）0.5s 后读一次
//   3. 剪贴板里有 BV 号 -> 拼 bilibili://video/{BV}?t={秒} -> openURL
//   4. 同一条剪贴板内容只处理一次（NSUserDefaults 指纹）
//   5. 处理完不清空剪贴板（避免吃掉用户内容）
//
// 编译见 build-dylib.sh / .github/workflows/build.yml

#import <UIKit/UIKit.h>

static NSString *const kLastHashKey = @"bpa_last_hash";

// FNV-1a 32bit，做剪贴板内容指纹，避免存整段文本
static NSString *bpa_hash(NSString *s) {
    const char *p = s.UTF8String;
    uint32_t h = 2166136261u;
    while (p && *p) {
        h ^= (uint8_t)(*p++);
        h *= 16777619u;
    }
    return [NSString stringWithFormat:@"%08x", h];
}

static void bpa_tryOpen(void) {
    @autoreleasepool {
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        NSString *str = pb.string;
        if (str.length < 12) return;

        NSString *hash = bpa_hash(str);
        NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
        if ([[def stringForKey:kLastHashKey] isEqualToString:hash]) return;

        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"BV[0-9A-Za-z]{10}"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *hit =
            [re firstMatchInString:str
                           options:0
                             range:NSMakeRange(0, str.length)];
        if (!hit) return;

        NSString *bv = [str substringWithRange:hit.range];

        // t= 秒，PiliPlus 内部 *1000 转毫秒
        NSString *query = @"";
        NSRange tr = [str rangeOfString:@"t="];
        if (tr.location != NSNotFound) {
            NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
            NSUInteger i = tr.location + 2, j = i;
            while (j < str.length &&
                   [digits characterIsMember:[str characterAtIndex:j]]) {
                j++;
            }
            if (j > i) {
                query = [@"?t=" stringByAppendingString:
                         [str substringWithRange:NSMakeRange(i, j - i)]];
            }
        }

        NSString *full =
            [NSString stringWithFormat:@"bilibili://video/%@%@", bv, query];
        NSURL *url = [NSURL URLWithString:full];
        if (!url) return;

        [def setObject:hash forKey:kLastHashKey];
        [def synchronize];

        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication.sharedApplication openURL:url
                                             options:@{}
                                   completionHandler:nil];
        });
    }
}

static void bpa_schedule(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ bpa_tryOpen(); });
}

__attribute__((constructor))
static void bpa_init(void) {
    // 冷启动
    bpa_schedule(1.5);

    // 前台激活
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        bpa_schedule(0.5);
    }];
}
