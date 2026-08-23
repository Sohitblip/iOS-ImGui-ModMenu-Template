#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <Security/Security.h>
#import <stddef.h>
#import <string.h>
#import <vector>

// Imgui library
#import "Esp/CaptainHook.h"
#import "Esp/ImGuiDrawView.h"
#import "IMGUI/imgui.h"
#import "IMGUI/imgui_impl_metal.h"
#import "IMGUI/Honkai.h"

// Patch library
#import "5Toubun/NakanoIchika.h"
#import "5Toubun/NakanoNino.h"
#import "5Toubun/NakanoMiku.h"
#import "5Toubun/NakanoYotsuba.h"
#import "5Toubun/NakanoItsuki.h"
#import "5Toubun/dobby.h"

#define kWidth  [UIScreen mainScreen].bounds.size.width
#define kHeight [UIScreen mainScreen].bounds.size.height
#define kScale  [UIScreen mainScreen].scale

// --- Vector structures ---
struct Vector3 { float X, Y, Z; };
struct Vector2 { float X, Y; };

// --- Global addresses (updated by scanner) ---
static uintptr_t g_BaseAddress = 0;
static uintptr_t g_GWorld = 0;
static uintptr_t g_GNames = 0;
static uintptr_t g_GUObjectArray = 0;
static uintptr_t g_World = 0;
static uintptr_t g_Controller = 0;
static uintptr_t g_CameraManager = 0;
static uintptr_t g_ActorArray = 0;
static int g_ActorCount = 0;
static int g_ViewMatOff = 0x30;
static int g_ProjMatOff = 0x70;

// --- Safe Memory Reader ---
template <typename T>
static inline T ReadMemory(uintptr_t address, T defaultValue = T()) {
    if (!address || address < 0x10000000 || address > 0x3000000000) return defaultValue;
    T buffer;
    vm_size_t size = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, sizeof(T), (vm_address_t)&buffer, &size);
    if (kr == KERN_SUCCESS && size == sizeof(T)) return buffer;
    return defaultValue;
}

// --- VTable validation ---
static bool IsValidVTable(uintptr_t obj) {
    if (!obj || obj < 0x10000000 || obj > 0x3000000000) return false;
    uintptr_t vtable = ReadMemory<uintptr_t>(obj);
    if (!vtable || vtable < g_BaseAddress || vtable > g_BaseAddress + 0x10000000) return false;
    return true;
}

// --------------------------------------------------------------------
// Matrix detection functions
// --------------------------------------------------------------------
struct FMinimalViewInfo {
    Vector3 Location;
    Vector3 Rotation;
    float FOV;
};

struct FCameraCacheEntry {
    float Timestamp;
    FMinimalViewInfo POV;
};

static bool DetectMatrixOffsets(uintptr_t CameraManager, int& outViewOff, int& outProjOff) {
    if (!CameraManager) return false;
    uintptr_t cacheAddr = CameraManager + 0x4B0;
    FCameraCacheEntry cache = ReadMemory<FCameraCacheEntry>(cacheAddr);
    if (cache.Timestamp == 0) return false;
    uintptr_t povAddr = cacheAddr + offsetof(FCameraCacheEntry, POV);
    int candidates[] = {0x10,0x20,0x30,0x40,0x50,0x60,0x70,0x80,0x90,0xA0,0xB0,0xC0};
    for (int vOff : candidates) {
        for (int pOff : candidates) {
            if (vOff == pOff) continue;
            float view[16], proj[16];
            memcpy(view, (void*)(povAddr + vOff), 16*sizeof(float));
            memcpy(proj, (void*)(povAddr + pOff), 16*sizeof(float));
            float sum = 0; for (int i=0;i<16;i++) sum += fabsf(view[i]);
            if (sum < 0.1f) continue;
            sum = 0; for (int i=0;i<16;i++) sum += fabsf(proj[i]);
            if (sum < 0.1f) continue;
            outViewOff = vOff;
            outProjOff = pOff;
            return true;
        }
    }
    return false;
}

// --- Pattern scanning for GNames ---
static uintptr_t FindGNames() {
    const char* pattern = "None";
    size_t len = strlen(pattern);
    uintptr_t end = g_BaseAddress + 0x1000000;
    for (uintptr_t addr = g_BaseAddress; addr < end; ++addr) {
        char buf[5];
        vm_size_t size = 0;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)addr, len, (vm_address_t)buf, &size) == KERN_SUCCESS && size == len) {
            if (strncmp(buf, pattern, len) == 0) {
                for (uintptr_t p = g_BaseAddress; p < g_BaseAddress + 0x1000000; p += 4) {
                    uintptr_t ptr = ReadMemory<uintptr_t>(p);
                    if (ptr == addr) {
                        return p;
                    }
                }
                break;
            }
        }
    }
    return 0;
}

// --- Enhanced scanner ---
static void ScanOffsets() {
    if (!g_BaseAddress) return;

    for (int off = 0; off < 0x1000; off += 4) {
        uintptr_t ptr = ReadMemory<uintptr_t>(g_BaseAddress + off);
        if (ptr > 0x10000000 && ptr < 0x3000000000) {
            if (IsValidVTable(ptr)) {
                uintptr_t level = ReadMemory<uintptr_t>(ptr + 0x30);
                if (level > 0x10000000 && IsValidVTable(level)) {
                    uintptr_t actors = ReadMemory<uintptr_t>(level + 0xA0);
                    int count = ReadMemory<int>(level + 0xA8);
                    if (actors > 0x10000000 && count > 0 && count < 5000) {
                        g_GWorld = ptr;
                        break;
                    }
                }
            }
        }
    }

    if (g_GWorld) {
        for (int off = 0x20; off < 0x100; off += 4) {
            uintptr_t gi = ReadMemory<uintptr_t>(g_GWorld + off);
            if (gi > 0x10000000 && IsValidVTable(gi)) {
                uintptr_t lpArray = ReadMemory<uintptr_t>(gi + 0x38);
                if (lpArray > 0x10000000) {
                    uintptr_t lp = ReadMemory<uintptr_t>(lpArray);
                    if (lp > 0x10000000 && IsValidVTable(lp)) {
                        for (int pcOff = 0x20; pcOff < 0x80; pcOff += 4) {
                            uintptr_t pc = ReadMemory<uintptr_t>(lp + pcOff);
                            if (pc > 0x10000000 && IsValidVTable(pc)) {
                                uintptr_t cam = ReadMemory<uintptr_t>(pc + 0x4D0);
                                if (cam > 0x10000000 && IsValidVTable(cam)) {
                                    g_Controller = pc;
                                    g_CameraManager = cam;
                                    break;
                                }
                            }
                        }
                        break;
                    }
                }
            }
        }

        for (int off = 0x20; off < 0x100; off += 4) {
            uintptr_t level = ReadMemory<uintptr_t>(g_GWorld + off);
            if (level > 0x10000000 && IsValidVTable(level)) {
                uintptr_t actors = ReadMemory<uintptr_t>(level + 0xA0);
                int count = ReadMemory<int>(level + 0xA8);
                if (actors > 0x10000000 && count > 0 && count < 5000) {
                    g_ActorArray = actors;
                    g_ActorCount = count;
                    break;
                }
            }
        }
    }

    if (!g_GNames) {
        g_GNames = FindGNames();
    }

    if (!g_GUObjectArray) {
        for (int off = 0; off < 0x1000000; off += 4) {
            uintptr_t ptr = ReadMemory<uintptr_t>(g_BaseAddress + off);
            if (ptr > 0x10000000 && ptr < 0x3000000000) {
                uintptr_t firstObj = ReadMemory<uintptr_t>(ptr);
                if (firstObj > 0x10000000 && IsValidVTable(firstObj)) {
                    uintptr_t classPriv = ReadMemory<uintptr_t>(firstObj + 0x10);
                    if (classPriv > 0x10000000 && IsValidVTable(classPriv)) {
                        g_GUObjectArray = ptr;
                        break;
                    }
                }
            }
        }
    }

    if (g_CameraManager) {
        int vOff, pOff;
        if (DetectMatrixOffsets(g_CameraManager, vOff, pOff)) {
            g_ViewMatOff = vOff;
            g_ProjMatOff = pOff;
        }
    }
}

// --- W2S ---
static bool GetViewProjectionMatrices(uintptr_t CameraManager, float* outViewMatrix, float* outProjMatrix) {
    if (!CameraManager) return false;
    uintptr_t cacheAddr = CameraManager + 0x4B0;
    FCameraCacheEntry cache = ReadMemory<FCameraCacheEntry>(cacheAddr);
    if (cache.Timestamp == 0) return false;
    uintptr_t povAddr = cacheAddr + offsetof(FCameraCacheEntry, POV);
    memcpy(outViewMatrix, (void*)(povAddr + g_ViewMatOff), 16 * sizeof(float));
    memcpy(outProjMatrix, (void*)(povAddr + g_ProjMatOff), 16 * sizeof(float));
    return true;
}

static bool ProjectWorldToScreen(Vector3 worldPos, Vector2& screenPos, float* viewMatrix, float* projMatrix, int screenWidth, int screenHeight) {
    float x = viewMatrix[0]*worldPos.X + viewMatrix[1]*worldPos.Y + viewMatrix[2]*worldPos.Z + viewMatrix[3];
    float y = viewMatrix[4]*worldPos.X + viewMatrix[5]*worldPos.Y + viewMatrix[6]*worldPos.Z + viewMatrix[7];
    float z = viewMatrix[8]*worldPos.X + viewMatrix[9]*worldPos.Y + viewMatrix[10]*worldPos.Z + viewMatrix[11];
    float w = viewMatrix[12]*worldPos.X + viewMatrix[13]*worldPos.Y + viewMatrix[14]*worldPos.Z + viewMatrix[15];
    if (w < 0.001f) return false;
    float clipX = projMatrix[0]*x + projMatrix[1]*y + projMatrix[2]*z + projMatrix[3]*w;
    float clipY = projMatrix[4]*x + projMatrix[5]*y + projMatrix[6]*z + projMatrix[7]*w;
    float clipW = projMatrix[12]*x + projMatrix[13]*y + projMatrix[14]*z + projMatrix[15]*w;
    if (clipW < 0.001f) return false;
    float ndcX = clipX / clipW;
    float ndcY = clipY / clipW;
    screenPos.X = (ndcX * 0.5f + 0.5f) * screenWidth;
    screenPos.Y = (-ndcY * 0.5f + 0.5f) * screenHeight;
    return true;
}

// --- UI globals ---
static bool MenDeal = true;
static bool show_ESPBox = true;
static bool show_ESPLine = true;
static bool show_ESPDistance = true;
static bool show_Diagnostics = true;
static bool autoScanDone = false;
static char scanResult[1024] = "Auto‑scan will start shortly...";
static CGRect g_ImGuiWindowRect = CGRectZero;

// ---- Logging helper ----
static void LogOffsetsToFile() {
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = [paths firstObject];
        NSString *filePath = [docDir stringByAppendingPathComponent:@"offset_log.txt"];
        NSString *log = [NSString stringWithFormat:
            @"========= URP OFFSET LOG =========\n"
            @"Timestamp: %@\n"
            @"Base: 0x%lx\nGWorld: 0x%lx\nGNames: 0x%lx\nGUObject: 0x%lx\n"
            @"World: 0x%lx\nController: 0x%lx\nCamMgr: 0x%lx\n"
            @"ActorArr: 0x%lx\nActorCount: %d\nViewMatOff: 0x%X\nProjMatOff: 0x%X\n\n",
            [NSDate date], g_BaseAddress, g_GWorld, g_GNames, g_GUObjectArray,
            g_World, g_Controller, g_CameraManager,
            g_ActorArray, g_ActorCount, g_ViewMatOff, g_ProjMatOff];
        [log writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// ---- Custom MTKView for Hit-Testing ----
@interface CustomMTKView : MTKView
@end

@implementation CustomMTKView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!MenDeal) {
        return NO;
    }
    // Agar click actual menu box ke andar hai, tabhi view touch capture kare
    if (CGRectContainsPoint(g_ImGuiWindowRect, point)) {
        return YES;
    }
    return NO;
}
@end

// ---- ImGuiDrawView ----
@interface ImGuiDrawView () <MTKViewDelegate>
@property (nonatomic, strong) id <MTLDevice> device;
@property (nonatomic, strong) id <MTLCommandQueue> commandQueue;
@end

@implementation ImGuiDrawView

void (*huy)(void *instance);
void _huy(void *instance) { huy(instance); }

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];
    if (!self.device) abort();
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); (void)io;
    ImGui::StyleColorsClassic();
    ImFont* font = io.Fonts->AddFontFromMemoryCompressedTTF((void*)Honkai_compressed_data, Honkai_compressed_size, 45.0f, NULL, io.Fonts->GetGlyphRangesDefault());
    ImGui_ImplMetal_Init(_device);
    return self;
}

+ (void)showChange:(BOOL)open { MenDeal = open; }
- (MTKView *)mtkView { return (MTKView *)self.view; }

- (void)loadView {
    CGFloat w = [UIApplication sharedApplication].windows[0].rootViewController.view.frame.size.width;
    CGFloat h = [UIApplication sharedApplication].windows[0].rootViewController.view.frame.size.height;
    self.view = [[CustomMTKView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.opaque = NO;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.mtkView.device = self.device;
    self.mtkView.delegate = self;
    self.mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.mtkView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0];
    self.mtkView.clipsToBounds = YES;
    self.view.userInteractionEnabled = YES;
    self.view.multipleTouchEnabled = YES;
    
    // Auto-scan after 6 seconds
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!autoScanDone) {
            ScanOffsets();
            autoScanDone = YES;
            snprintf(scanResult, sizeof(scanResult),
                     "GWorld: 0x%lx\nGNames: 0x%lx\nGUObjectArray: 0x%lx\n"
                     "World: 0x%lx\nController: 0x%lx\nCameraManager: 0x%lx\n"
                     "ActorArray: 0x%lx\nActorCount: %d\nViewMatOff: 0x%X\nProjMatOff: 0x%X",
                     g_GWorld, g_GNames, g_GUObjectArray,
                     g_World, g_Controller, g_CameraManager,
                     g_ActorArray, g_ActorCount, g_ViewMatOff, g_ProjMatOff);
            LogOffsetsToFile();
            if (!g_GWorld || !g_GNames || !g_GUObjectArray || !g_ActorArray) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ScanOffsets();
                    snprintf(scanResult, sizeof(scanResult),
                             "GWorld: 0x%lx\nGNames: 0x%lx\nGUObjectArray: 0x%lx\n"
                             "World: 0x%lx\nController: 0x%lx\nCameraManager: 0x%lx\n"
                             "ActorArray: 0x%lx\nActorCount: %d\nViewMatOff: 0x%X\nProjMatOff: 0x%X",
                             g_GWorld, g_GNames, g_GUObjectArray,
                             g_World, g_Controller, g_CameraManager,
                             g_ActorArray, g_ActorCount, g_ViewMatOff, g_ProjMatOff);
                    LogOffsetsToFile();
                });
            }
        }
    });
}

#pragma mark - Touch Handling

- (void)updateTouch:(NSSet<UITouch *> *)touches isDown:(BOOL)isDown {
    UITouch *touch = [touches anyObject];
    if (!touch) return;
    
    CGPoint loc = [touch locationInView:self.view];
    ImGuiIO& io = ImGui::GetIO();
    io.MousePos = ImVec2(loc.x, loc.y);
    io.MouseDown[0] = isDown;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateTouch:touches isDown:YES];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateTouch:touches isDown:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateTouch:touches isDown:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateTouch:touches isDown:NO];
}

#pragma mark - MTKViewDelegate

- (void)drawInMTKView:(MTKView*)view {
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize.x = view.bounds.size.width;
    io.DisplaySize.y = view.bounds.size.height;
    CGFloat framebufferScale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
    io.DisplayFramebufferScale = ImVec2(framebufferScale, framebufferScale);
    io.DeltaTime = 1 / float(view.preferredFramesPerSecond ?: 120);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    MTLRenderPassDescriptor* renderPassDescriptor = view.currentRenderPassDescriptor;
    
    if (renderPassDescriptor != nil) {
        id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [renderEncoder pushDebugGroup:@"ImGui"];

        ImGui_ImplMetal_NewFrame(renderPassDescriptor);
        ImGui::NewFrame();

        ImFont* font = ImGui::GetFont();
        font->Scale = 15.f / font->FontSize;

        CGFloat x = (view.bounds.size.width - 400) / 2;
        CGFloat y = (view.bounds.size.height - 350) / 2;
        ImGui::SetNextWindowPos(ImVec2(x, y), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(400, 350), ImGuiCond_FirstUseEver);

        // --- Menu ---
        if (MenDeal) {
            ImGui::Begin("URP Overlay", &MenDeal);
            
            // Hit-testing frame update
            ImVec2 winPos = ImGui::GetWindowPos();
            ImVec2 winSize = ImGui::GetWindowSize();
            g_ImGuiWindowRect = CGRectMake(winPos.x, winPos.y, winSize.x, winSize.y);
            
            ImGui::Text("Overlay Framework Active");
            ImGui::Separator();
            ImGui::Checkbox("Player 2D Box", &show_ESPBox);
            ImGui::Checkbox("Player Snaplines", &show_ESPLine);
            ImGui::Checkbox("Player Distance", &show_ESPDistance);
            ImGui::Checkbox("Show Offset Inspector", &show_Diagnostics);
            ImGui::Separator();
            ImGui::Text("FPS: %.1f", ImGui::GetIO().Framerate);
            ImGui::End();
        } else {
            g_ImGuiWindowRect = CGRectZero;
        }

        // --- ESP Drawing ---
        ImDrawList* drawList = ImGui::GetForegroundDrawList();
        float viewWidth = view.bounds.size.width;
        float viewHeight = view.bounds.size.height;

        float viewMat[16] = {0}, projMat[16] = {0};
        bool w2sReady = false;
        if (g_CameraManager) {
            w2sReady = GetViewProjectionMatrices(g_CameraManager, viewMat, projMat);
        }

        if (g_ActorArray && g_ActorCount > 0 && g_Controller && w2sReady) {
            for (int i = 0; i < g_ActorCount; i++) {
                uintptr_t actor = ReadMemory<uintptr_t>(g_ActorArray + (i * sizeof(uintptr_t)));
                if (!actor) continue;
                uintptr_t rootOffsets[] = {0x140, 0x130, 0x138, 0x148, 0x180};
                uintptr_t rootComp = 0;
                for (int r = 0; r < 5; r++) {
                    rootComp = ReadMemory<uintptr_t>(actor + rootOffsets[r]);
                    if (rootComp > 0x10000000 && IsValidVTable(rootComp)) break;
                }
                if (!rootComp) continue;
                Vector3 actorPos = ReadMemory<Vector3>(rootComp + 0x120);
                if (actorPos.X == 0 && actorPos.Y == 0 && actorPos.Z == 0) continue;
                Vector3 headPos = actorPos; headPos.Z += 80.0f;
                Vector3 feetPos = actorPos; feetPos.Z -= 80.0f;
                Vector2 screenHead, screenFeet, screenPos;
                if (ProjectWorldToScreen(headPos, screenHead, viewMat, projMat, viewWidth, viewHeight) &&
                    ProjectWorldToScreen(feetPos, screenFeet, viewMat, projMat, viewWidth, viewHeight) &&
                    ProjectWorldToScreen(actorPos, screenPos, viewMat, projMat, viewWidth, viewHeight)) {
                    float boxHeight = fabsf(screenFeet.Y - screenHead.Y);
                    float boxWidth = boxHeight / 2.0f;
                    float boxLeft = screenHead.X - (boxWidth / 2.0f);
                    if (show_ESPLine) {
                        drawList->AddLine(ImVec2(viewWidth/2, 60), ImVec2(screenHead.X, screenHead.Y), IM_COL32(255,235,59,255), 1.5f);
                    }
                    if (show_ESPBox) {
                        drawList->AddRect(ImVec2(boxLeft, screenHead.Y), ImVec2(boxLeft+boxWidth, screenFeet.Y), IM_COL32(255,40,40,255), 0.0f, 0, 1.6f);
                    }
                    if (show_ESPDistance) {
                        float dist = sqrtf(actorPos.X*actorPos.X + actorPos.Y*actorPos.Y + actorPos.Z*actorPos.Z) / 100.0f;
                        char txt[32]; snprintf(txt, sizeof(txt), "%.1fm", dist);
                        drawList->AddText(ImVec2(screenHead.X-10, screenHead.Y-20), IM_COL32(255,255,255,255), txt);
                    }
                }
            }
        }

        // --- Diagnostics Overlay ---
        if (show_Diagnostics) {
            char debugText[1024];
            snprintf(debugText, sizeof(debugText),
                     "[Engine Inspector]\n"
                     "Base: 0x%lx\n"
                     "GWorld: 0x%lx\n"
                     "GNames: 0x%lx\n"
                     "GUObject: 0x%lx\n"
                     "World: 0x%lx\n"
                     "Controller: 0x%lx\n"
                     "CamMgr: 0x%lx\n"
                     "ActorArr: 0x%lx\n"
                     "ActorCount: %d\n"
                     "ViewMatOff: 0x%X\n"
                     "ProjMatOff: 0x%X\n"
                     "--- Scan Result ---\n%s",
                     g_BaseAddress,
                     g_GWorld, g_GNames, g_GUObjectArray,
                     g_World, g_Controller, g_CameraManager,
                     g_ActorArray, g_ActorCount,
                     g_ViewMatOff, g_ProjMatOff,
                     scanResult);
            drawList->AddRectFilled(ImVec2(20,40), ImVec2(380, 320), IM_COL32(10,15,25,210), 6.0f);
            drawList->AddRect(ImVec2(20,40), ImVec2(380, 320), IM_COL32(0,255,200,180), 6.0f);
            drawList->AddText(ImVec2(28,46), IM_COL32(255,255,255,255), debugText);
        }

        // --- Render ImGui ---
        ImGui::Render();
        ImDrawData* draw_data = ImGui::GetDrawData();
        ImGui_ImplMetal_RenderDrawData(draw_data, commandBuffer, renderEncoder);

        [renderEncoder popDebugGroup];
        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:view.currentDrawable];
    }

    [commandBuffer commit];
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {}

@end

// =========================================================
// GLOBAL CONSTRUCTORS
// =========================================================

__attribute__((constructor))
static void initialize() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_BaseAddress = (uintptr_t)_dyld_get_image_header(0);
    });
}

__attribute__((constructor))
static void loadMenu() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in scene.windows) {
                        if (w.isKeyWindow) {
                            window = w;
                            break;
                        }
                    }
                }
            }
        } else {
            window = [[UIApplication sharedApplication] keyWindow];
        }
        if (window) {
            ImGuiDrawView *vc = [[ImGuiDrawView alloc] init];
            [window addSubview:vc.view];
            [window.rootViewController addChildViewController:vc];
            [ImGuiDrawView showChange:YES];
        }
    });
}
