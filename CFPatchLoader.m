// ============================================================================
// CFPatchLoader — CFM 1.0.590 (222.ipa) 热补丁加载器
//
// 目的：注入一次，之后换补丁只改一个数字配置文件，不用重装 IPA。
// 原理：
//   - 内置多套补丁预设（改 UnityFramework 函数入口的机器码）
//   - 从 ~/Documents/cfpatch.txt 读一个数字选择预设（0=原版，1=描边，2=激进描边）
//   - 运行时找到 UnityFramework 的加载基址，把补丁字节写进内存
//   - 补丁只存在于内存，重启游戏自动失效；改数字重启即换方案
//
// 注意：所有偏移基于 CFM 1.0.590 (222.ipa) 的 UnityFramework，
//       该版本相关段 vmaddr == fileoff，故运行时地址 = image_base + 偏移。
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <stdint.h>

#pragma mark - 补丁数据结构

typedef struct {
    uint32_t    offset;      // UnityFramework 文件偏移(=vmaddr)
    const char *old_hex;     // 原字节（用于校验，防版本错位）
    const char *new_hex;     // 目标字节（与 old 等长）
} HotPatch;

// ---- 预设 1：描边增强（已验证不闪退的 5 处）----
static const HotPatch kPresetOutline[] = {
    {0x3C39550, "f657bda9f44f01a9", "00008012c0035fd6"}, // OutlineRaycastLayerMask -> -1
    {0x82B443C, "00008052c0035fd6", "20008052c0035fd6"}, // OnlyFriendAssistAim -> 1
    {0x8034B40, "20008052c0035fd6", "00008052c0035fd6"}, // IsCurrentModeForbidOutline -> 0
    {0x3C38270, "f657bda9f44f01a9", "20008052c0035fd6"}, // ShouldEnableOutline -> 1
    {0x803477C, "00b04439c0035fd6", "20008052c0035fd6"}, // get_EnableEnemyOutline -> 1
};

// ---- 预设 2：激进透视（描边增强 + 射线不忽略 + 显示信息）----
static const HotPatch kPresetAggressive[] = {
    {0x3C39550, "f657bda9f44f01a9", "00008012c0035fd6"},
    {0x82B443C, "00008052c0035fd6", "20008052c0035fd6"},
    {0x8034B40, "20008052c0035fd6", "00008052c0035fd6"},
    {0x3C38270, "f657bda9f44f01a9", "20008052c0035fd6"},
    {0x803477C, "00b04439c0035fd6", "20008052c0035fd6"},
    {0x3C39440, "ff0301d1f65701a9", "00008052c0035fd6"}, // ShouldIgnore3PRayCast -> false
    {0x3C28870, "00008052c0035fd6", "20008052c0035fd6"}, // ShowPawnInfoWhenAimedAt -> 1
};

#pragma mark - 工具

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static NSData* data_from_hex(const char *s) {
    size_t n = strlen(s) / 2;
    NSMutableData *d = [NSMutableData dataWithCapacity:n];
    for (size_t i = 0; i < n; i++) {
        int hi = hex_nibble(s[i*2]), lo = hex_nibble(s[i*2+1]);
        if (hi < 0 || lo < 0) return nil;
        uint8_t b = (uint8_t)((hi << 4) | lo);
        [d appendBytes:&b length:1];
    }
    return d;
}

// 找 UnityFramework 在内存中的基址
static uintptr_t find_unityframework_base(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework")) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

// 在内存写一段字节（临时开 RW，写完恢复 RX）
static BOOL write_mem(uintptr_t addr, NSData *bytes) {
    if (!addr || !bytes) return NO;
    vm_map_t self = mach_task_self();
    vm_address_t page = addr & ~(vm_address_t)0xFFF;
    vm_size_t page_size = vm_page_size;
    // 覆盖可能跨页：按实际长度算页数
    vm_size_t span = (vm_size_t)(addr - page) + bytes.length;
    vm_size_t map_len = ((span + page_size - 1) / page_size) * page_size;
    vm_protect(self, page, map_len, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    memcpy((void *)addr, bytes.bytes, bytes.length);
    __builtin___clear_cache((char *)addr, (char *)(addr + bytes.length));
    vm_protect(self, page, map_len, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    return YES;
}

// 应用一套预设
static void apply_preset(const HotPatch *patches, int count, uintptr_t base) {
    for (int i = 0; i < count; i++) {
        const HotPatch *p = &patches[i];
        NSData *old = data_from_hex(p->old_hex);
        NSData *newd = data_from_hex(p->new_hex);
        if (!old || !newd || old.length != newd.length) {
            NSLog(@"[CFPatch] 补丁 %d 十六进制格式错误", i);
            continue;
        }
        uintptr_t addr = base + p->offset;
        // 校验原字节（防止版本不符导致写坏）
        if (memcmp((const void *)addr, old.bytes, old.length) != 0) {
            NSLog(@"[CFPatch] 补丁 %d @0x%X 原字节不匹配，跳过 (got=%@)",
                  i, p->offset, [NSData dataWithBytes:(const void *)addr length:old.length]);
            continue;
        }
        write_mem(addr, newd);
        NSLog(@"[CFPatch] 补丁 %d @0x%X 已应用", i, p->offset);
    }
}

#pragma mark - 配置读取

// 首次启动时把 bundle 内的默认配置复制到 Documents（给用户一个可编辑的文件）
static void ensure_config_file(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return;
    NSString *dst = [paths[0] stringByAppendingPathComponent:@"cfpatch.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dst]) return;
    NSString *src = [[NSBundle mainBundle] pathForResource:@"cfpatch" ofType:@"txt"];
    if (src) {
        [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:nil];
        NSLog(@"[CFPatch] 已创建默认配置 Documents/cfpatch.txt");
    }
}

static int read_preset(void) {
    // 优先级 1：剪贴板（最方便——复制一个数字 "0"/"1"/"2" 后重启游戏即可）
    @try {
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        NSString *clip = pb.string;
        if (clip) {
            NSString *t = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length <= 4) { // 只接受极短内容，避免误读备忘录整段文字
                int v = [t intValue];
                if (v >= 0 && v <= 2 && [[NSString stringWithFormat:@"%d", v] isEqualToString:t]) {
                    NSLog(@"[CFPatch] 从剪贴板读取预设=%d", v);
                    return v;
                }
            }
        }
    } @catch (NSException *e) { }
    // 优先级 2：Documents/cfpatch.txt（可用文件 App 或Filza编辑）
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        NSString *cfg = [paths[0] stringByAppendingPathComponent:@"cfpatch.txt"];
        NSString *txt = [NSString stringWithContentsOfFile:cfg encoding:NSUTF8StringEncoding error:nil];
        if (txt) {
            NSString *t = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            int v = [t intValue];
            if (v >= 0 && v <= 2) { NSLog(@"[CFPatch] 从配置读取预设=%d", v); return v; }
        }
    }
    // 默认：描边方案
    return 1;
}

#pragma mark - 入口

static int  gTried = 0;
static BOOL gDone  = NO;

static void try_apply(void) {
    @autoreleasepool {
        uintptr_t base = find_unityframework_base();
        if (!base) {
            if (gTried++ < 20) { // 最多等 ~10 秒
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    try_apply();
                });
            } else {
                NSLog(@"[CFPatch] 未找到 UnityFramework，放弃");
            }
            return;
        }
        // UnityFramework 已加载，稍等其完成初始化再写补丁
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @autoreleasepool {
                if (gDone) return;
                gDone = YES;
                ensure_config_file();
                int preset = read_preset();
                NSLog(@"[CFPatch] UnityFramework base=0x%lx, preset=%d", (unsigned long)base, preset);
                if (preset == 0) {
                    NSLog(@"[CFPatch] 预设0=原版，不打补丁");
                } else if (preset == 1) {
                    apply_preset(kPresetOutline, sizeof(kPresetOutline)/sizeof(HotPatch), base);
                } else if (preset == 2) {
                    apply_preset(kPresetAggressive, sizeof(kPresetAggressive)/sizeof(HotPatch), base);
                }
                NSLog(@"[CFPatch] 完成");
            }
        });
    }
}

__attribute__((constructor)) static void loader_init(void) {
    @autoreleasepool {
        NSLog(@"[CFPatch] CFPatchLoader 已加载");
        try_apply();
    }
}
