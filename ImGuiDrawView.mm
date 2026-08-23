#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>

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

// --- Vector structures for UE4 coordinates ---
struct Vector3 { float X; float Y; float Z; };
struct Vector2 { float X; float Y; };

// --- PUBG GL 4.5 OFFSETS ---
#define OFF_UWorld              0x10C034388
#define OFF_BonePos             0x10356B00C
#define OFF_GWorld_Data         0x10AA11EA0
#define OFF_GWorld_Fn           0x10219A0F0
#define OFF_GName_Data          0x10A5BD5F0
#define OFF_GName_Fn            0x105014128
#define OFF_GUObject            0x10A7F93E0
#define OFF_LineOfSight         0x1062126D4
#define OFF_ActorArray          0x1063693F0
#define OFF_W2S_Function        0x1062B69B8

// Function pointer signature
typedef bool (*_ProjectWorldLocationToScreen)(void* PlayerController, Vector3 WorldLocation, Vector2& ScreenLocation, bool bPlayerViewportRelative);
typedef Vector3 (*_GetBonePos)(void* Mesh, int BoneId);

static _ProjectWorldLocationToScreen ProjectWorldLocationToScreen = nullptr;
static _GetBonePos GetBonePos = nullptr;
static uintptr_t g_BaseAddress = 0;

// Safe Memory Reader
template <typename T>
static inline T ReadMemory(uintptr_t address, T defaultValue = T()) {
    if (!address || address < 0x100000000 || address > 0x3000000000) return defaultValue;
    T buffer;
    vm_size_t size = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, sizeof(T), (vm_address_t)&buffer, &size);
    if (kr == KERN_SUCCESS && size == sizeof(T)) {
        return buffer;
    }
    return defaultValue;
}

// Bools for menu switches
static bool MenDeal = true;
static bool show_ESPBox = true;
static bool show_ESPLine = true;
static bool show_ESPDistance = true;
static bool show_DebugMonitor = true;

@interface ImGuiDrawView () <MTKViewDelegate>
@property (nonatomic, strong) id <MTLDevice> device;
@property (nonatomic, strong) id <MTLCommandQueue> commandQueue;
@end

@implementation ImGuiDrawView

void (*huy)(void *instance);
void _huy(void *instance) {
    huy(instance);
}

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil
{
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

+ (void)showChange:(BOOL)open
{
    MenDeal = open;
}

- (MTKView *)mtkView
{
    return (MTKView *)self.view;
}

- (void)loadView
{
    CGFloat w = [UIApplication sharedApplication].windows[0].rootViewController.view.frame.size.width;
    CGFloat h = [UIApplication sharedApplication].windows[0].rootViewController.view.frame.size.height;
    self.view = [[MTKView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.mtkView.device = self.device;
    self.mtkView.delegate = self;
    self.mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.mtkView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0];
    self.mtkView.clipsToBounds = YES;
}

#pragma mark - Interaction
- (void)updateIOWithTouchEvent:(UIEvent *)event
{
    UITouch *anyTouch = event.allTouches.anyObject;
    CGPoint touchLocation = [anyTouch locationInView:self.view];
    ImGuiIO &io = ImGui::GetIO();
    io.MousePos = ImVec2(touchLocation.x, touchLocation.y);

    BOOL hasActiveTouch = NO;
    for (UITouch *touch in event.allTouches)
    {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled)
        {
            hasActiveTouch = YES;
            break;
        }
    }
    io.MouseDown[0] = hasActiveTouch;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateIOWithTouchEvent:event]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateIOWithTouchEvent:event]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateIOWithTouchEvent:event]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateIOWithTouchEvent:event]; }

#pragma mark - MTKViewDelegate

- (void)drawInMTKView:(MTKView*)view
{
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize.x = view.bounds.size.width;
    io.DisplaySize.y = view.bounds.size.height;

    CGFloat framebufferScale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
    io.DisplayFramebufferScale = ImVec2(framebufferScale, framebufferScale);
    io.DeltaTime = 1 / float(view.preferredFramesPerSecond ?: 120);
    
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    [self.view setUserInteractionEnabled:(MenDeal ? YES : NO)];

    MTLRenderPassDescriptor* renderPassDescriptor = view.currentRenderPassDescriptor;
    if (renderPassDescriptor != nil)
    {
        id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [renderEncoder pushDebugGroup:@"ImGui Jane"];

        ImGui_ImplMetal_NewFrame(renderPassDescriptor);
        ImGui::NewFrame();
        
        ImFont* font = ImGui::GetFont();
        font->Scale = 15.f / font->FontSize;
        
        CGFloat x = (([UIApplication sharedApplication].windows[0].rootViewController.view.frame.size.width) - 360) / 2;
        CGFloat y = (([UIApplication sharedApplication].windows[0].rootViewController.view.frame.size.height) - 300) / 2;
        
        ImGui::SetNextWindowPos(ImVec2(x, y), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(360, 260), ImGuiCond_FirstUseEver); 
        
        // ------------------ ImGui Mod Menu ------------------
        if (MenDeal) 
        {     
            ImGui::Begin("PUBG GL 4.5 Overlay", &MenDeal);
                ImGui::Text("Engine Status: Active");
                ImGui::Separator();
                
                ImGui::Checkbox("Player 2D Box", &show_ESPBox);
                ImGui::Checkbox("Player Snaplines", &show_ESPLine);
                ImGui::Checkbox("Player Distance", &show_ESPDistance);
                ImGui::Checkbox("Debug Telemetry", &show_DebugMonitor);
                
                ImGui::Separator();
                ImGui::Text("FPS: %.1f", ImGui::GetIO().Framerate);
            ImGui::End();   
        }
        
        // ------------------ Real Dynamic ESP Engine ------------------
        ImDrawList* drawList = ImGui::GetForegroundDrawList();

        uintptr_t gWorldPtr = 0;
        void* playerController = nullptr;
        int validActorsFound = 0;

        if (g_BaseAddress) {
            // Read UWorld via offset pointer or static Data address
            gWorldPtr = ReadMemory<uintptr_t>(g_BaseAddress + OFF_UWorld);
            if (!gWorldPtr) {
                gWorldPtr = ReadMemory<uintptr_t>(g_BaseAddress + OFF_GWorld_Data);
            }

            if (gWorldPtr) {
                // GameInstance -> LocalPlayer -> PlayerController
                uintptr_t gameInstance = ReadMemory<uintptr_t>(gWorldPtr + 0x24);
                if (gameInstance) {
                    uintptr_t localPlayers = ReadMemory<uintptr_t>(gameInstance + 0x38);
                    uintptr_t localPlayer = ReadMemory<uintptr_t>(localPlayers);
                    playerController = (void*)ReadMemory<uintptr_t>(localPlayer + 0x30);
                }

                // PersistentLevel -> ActorArray
                uintptr_t persistentLevel = ReadMemory<uintptr_t>(gWorldPtr + 0x30);
                if (!persistentLevel) persistentLevel = ReadMemory<uintptr_t>(gWorldPtr + 0x20);

                uintptr_t actorArrayAddr = ReadMemory<uintptr_t>(persistentLevel + 0x98);
                if (!actorArrayAddr) actorArrayAddr = ReadMemory<uintptr_t>(persistentLevel + 0xA0);
                int actorCount = ReadMemory<int>(persistentLevel + 0xA0);

                if (actorCount > 0 && actorCount < 2048 && actorArrayAddr && playerController && ProjectWorldLocationToScreen) {
                    for (int i = 0; i < actorCount; i++) {
                        uintptr_t actor = ReadMemory<uintptr_t>(actorArrayAddr + (i * sizeof(uintptr_t)));
                        if (!actor) continue;

                        uintptr_t rootComp = ReadMemory<uintptr_t>(actor + 0x140);
                        if (!rootComp) rootComp = ReadMemory<uintptr_t>(actor + 0x130);
                        if (!rootComp) continue;

                        Vector3 actorPos = ReadMemory<Vector3>(rootComp + 0x120);
                        if (actorPos.X == 0 && actorPos.Y == 0 && actorPos.Z == 0) continue;

                        Vector3 headPos = actorPos; headPos.Z += 80.0f;
                        Vector3 feetPos = actorPos; feetPos.Z -= 80.0f;

                        Vector2 screenHead, screenFeet, screenPos;

                        if (ProjectWorldLocationToScreen(playerController, headPos, screenHead, false) &&
                            ProjectWorldLocationToScreen(playerController, feetPos, screenFeet, false) &&
                            ProjectWorldLocationToScreen(playerController, actorPos, screenPos, false)) {

                            validActorsFound++;

                            float boxHeight = fabsf(screenFeet.Y - screenHead.Y);
                            float boxWidth = boxHeight / 2.0f;
                            float boxLeft = screenHead.X - (boxWidth / 2.0f);
                            float boxRight = screenHead.X + (boxWidth / 2.0f);

                            if (show_ESPLine) {
                                drawList->AddLine(
                                    ImVec2(view.bounds.size.width / 2.0f, 60.0f),
                                    ImVec2(screenHead.X, screenHead.Y),
                                    IM_COL32(255, 235, 59, 255), 1.5f
                                );
                            }

                            if (show_ESPBox) {
                                drawList->AddRect(
                                    ImVec2(boxLeft, screenHead.Y),
                                    ImVec2(boxRight, screenFeet.Y),
                                    IM_COL32(255, 40, 40, 255), 0.0f, 0, 1.6f
                                );
                            }
                        }
                    }
                }
            }
        }

        // ------------------ Force Preview Overlay (If not in match) ------------------
        if (show_DebugMonitor) {
            char debugText[256];
            snprintf(debugText, sizeof(debugText), 
                     "PUBG Telemetry\nBase: 0x%lx\nGWorld: 0x%lx\nController: %p\nLive ESP Rendered: %d", 
                     g_BaseAddress, gWorldPtr, playerController, validActorsFound);
            drawList->AddRectFilled(ImVec2(20, 40), ImVec2(240, 120), IM_COL32(0, 0, 0, 160), 6.0f);
            drawList->AddText(ImVec2(28, 48), IM_COL32(0, 255, 128, 255), debugText);

            // Match ke bahar Lobby me check karne ke liye live screen indicators
            if (validActorsFound == 0 && show_ESPLine) {
                drawList->AddLine(
                    ImVec2(view.bounds.size.width / 2.0f, 60.0f),
                    ImVec2(view.bounds.size.width / 2.0f, view.bounds.size.height / 2.0f),
                    IM_COL32(0, 255, 255, 180), 1.0f
                );
                drawList->AddText(
                    ImVec2(view.bounds.size.width / 2.0f - 50.0f, view.bounds.size.height / 2.0f + 10.0f),
                    IM_COL32(0, 255, 255, 255), "Radar Active"
                );
            }
        }

        // ------------------ ImGui Render Pass ------------------
        ImGui::Render();
        ImDrawData* draw_data = ImGui::GetDrawData();
        ImGui_ImplMetal_RenderDrawData(draw_data, commandBuffer, renderEncoder);
      
        [renderEncoder popDebugGroup];
        [renderEncoder endEncoding];

        [commandBuffer presentDrawable:view.currentDrawable];
    }

    [commandBuffer commit];
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size
{
    
}

@end

// =========================================================
// GLOBAL CONSTRUCTORS
// =========================================================

__attribute__((constructor))
static void initializePUBGOffsets() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_BaseAddress = (uintptr_t)_dyld_get_image_header(0);
        if (g_BaseAddress) {
            ProjectWorldLocationToScreen = (_ProjectWorldLocationToScreen)(g_BaseAddress + OFF_W2S_Function);
            GetBonePos = (_GetBonePos)(g_BaseAddress + OFF_BonePos);
        }
    });
}

__attribute__((constructor))
static void forceLoadMenuInEsign() {
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
