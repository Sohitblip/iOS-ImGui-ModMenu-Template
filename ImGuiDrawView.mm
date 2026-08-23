#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <Security/Security.h>

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

// --- URP OFFSETS (from the provided namespace) ---
#define OFF_GNames             0x86CA71C
#define OFF_GUObject           0xE6D36F0
#define OFF_GNativeAndroidApp  0xE40B6A8
#define OFF_GetActorArray      0xA45A314      // (optional, not used here)
#define OFF_ViewMatrix         0xE96E270      // actually GEngine pointer
#define OFF_ProcessEvent_Child 0x893C66C
#define OFF_ProcessEvent_Main  0x9FA1C34
#define OFF_LuaLoadBuffer      0xB2B0DD0
#define OFF_LuaPCall           0xB28D318
#define OFF_LuaLoad            0xB28B738
#define OFF_ShortEvent         0x6BB0CFC
#define OFF_MsgBox             0x84F7F9C
#define OFF_PostRender         0xA3633E8

// --- URP struct offsets (within UE4 objects) ---
#define OFF_Actors             0xA0           // ULevel::Actors (TArray)
#define OFF_GEngine            0xE96E270      // global UEngine*
#define OFF_ViewPort           0x58           // UEngine::GameViewportClient
#define OFF_World              0x78           // UGameViewportClient::World
#define OFF_LocalPlayer        0x4B0          // APlayerController::AcknowledgedPawn (or similar)
#define OFF_PlayerController   0x30           // ULocalPlayer::PlayerController
#define OFF_PlayerCameraManager 0x4D0         // APlayerController::PlayerCameraManager
#define OFF_CameraCache        0x4B0          // APlayerCameraManager::CameraCache (contains view/proj matrices)
#define OFF_RelativeLocation   0x120          // USceneComponent::RelativeLocation (or ComponentToWorld)

// Function pointer for ProcessEvent (if needed)
typedef void (*_ProcessEvent)(void* Object, void* Function, void* Params);
static _ProcessEvent ProcessEvent = nullptr;

// --- Manual World-to-Screen using CameraCache ---
struct FMinimalViewInfo {
    Vector3 Location;
    Vector3 Rotation;
    float FOV;
    // ... (we only need the view/projection matrices from the cache)
};

struct FCameraCacheEntry {
    float Timestamp;
    FMinimalViewInfo POV;
};

// Helper to get view and projection matrices from camera manager
static bool GetViewProjectionMatrices(uintptr_t CameraManager, float* outViewMatrix, float* outProjMatrix) {
    if (!CameraManager) return false;
    uintptr_t cacheAddr = CameraManager + OFF_CameraCache;
    FCameraCacheEntry cache = ReadMemory<FCameraCacheEntry>(cacheAddr);
    if (cache.Timestamp == 0) return false;

    // The actual matrices are stored in the POV; we need to compute them from Location, Rotation, FOV.
    // For a full manual projection we'd need to build the view matrix from rotation and location,
    // and the projection matrix from FOV and screen dimensions.
    // This is a simplified version – you might need to adjust based on your game's layout.
    // Alternatively, you can read the matrices directly if they are stored nearby.
    // For brevity, we'll assume the matrices are at POV+some offset.
    // Many UE4 builds store the view matrix at POV+0x30 and projection at POV+0x70.
    // We'll use those offsets (they are common, but verify with your dump).
    const int VIEW_MAT_OFFSET = 0x30;
    const int PROJ_MAT_OFFSET = 0x70;
    uintptr_t povAddr = cacheAddr + offsetof(FCameraCacheEntry, POV);
    memcpy(outViewMatrix, (void*)(povAddr + VIEW_MAT_OFFSET), 16 * sizeof(float));
    memcpy(outProjMatrix, (void*)(povAddr + PROJ_MAT_OFFSET), 16 * sizeof(float));
    return true;
}

// Manual W2S using view and projection matrices
static bool ProjectWorldToScreen(Vector3 worldPos, Vector2& screenPos, float* viewMatrix, float* projMatrix, int screenWidth, int screenHeight) {
    // Transform world to view space
    float x = viewMatrix[0] * worldPos.X + viewMatrix[1] * worldPos.Y + viewMatrix[2] * worldPos.Z + viewMatrix[3];
    float y = viewMatrix[4] * worldPos.X + viewMatrix[5] * worldPos.Y + viewMatrix[6] * worldPos.Z + viewMatrix[7];
    float z = viewMatrix[8] * worldPos.X + viewMatrix[9] * worldPos.Y + viewMatrix[10] * worldPos.Z + viewMatrix[11];
    float w = viewMatrix[12] * worldPos.X + viewMatrix[13] * worldPos.Y + viewMatrix[14] * worldPos.Z + viewMatrix[15];

    if (w < 0.001f) return false; // behind camera

    // Project to clip space
    float clipX = projMatrix[0] * x + projMatrix[1] * y + projMatrix[2] * z + projMatrix[3] * w;
    float clipY = projMatrix[4] * x + projMatrix[5] * y + projMatrix[6] * z + projMatrix[7] * w;
    float clipW = projMatrix[12] * x + projMatrix[13] * y + projMatrix[14] * z + projMatrix[15] * w;

    if (clipW < 0.001f) return false;

    // NDC
    float ndcX = clipX / clipW;
    float ndcY = clipY / clipW;

    // Screen coordinates
    screenPos.X = (ndcX * 0.5f + 0.5f) * screenWidth;
    screenPos.Y = (-ndcY * 0.5f + 0.5f) * screenHeight;  // flip Y
    return true;
}

// --- Global variables ---
static uintptr_t g_BaseAddress = 0;
static uintptr_t g_World = 0;
static uintptr_t g_Controller = 0;
static uintptr_t g_CameraManager = 0;

// Bools for menu switches
static bool MenDeal = true;
static bool show_ESPBox = true;
static bool show_ESPLine = true;
static bool show_ESPDistance = true;
static bool show_Diagnostics = true;

// Diagnostic structure
struct EngineDiagnostics {
    uintptr_t detectedGWorld;
    uintptr_t detectedGameInstance;
    uintptr_t detectedLocalPlayer;
    uintptr_t detectedController;
    uintptr_t detectedLevel;
    uintptr_t detectedActorArray;
    int detectedActorCount;
    int renderedActors;
    bool w2sWorking;
};
static EngineDiagnostics g_Diag = {0};

// Safe Memory Reader
template <typename T>
static inline T ReadMemory(uintptr_t address, T defaultValue = T()) {
    if (!address || address < 0x10000000 || address > 0x3000000000) return defaultValue;
    T buffer;
    vm_size_t size = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, sizeof(T), (vm_address_t)&buffer, &size);
    if (kr == KERN_SUCCESS && size == sizeof(T)) return buffer;
    return defaultValue;
}

// ---- ImGuiDrawView implementation ----
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
- (void)updateIOWithTouchEvent:(UIEvent *)event {
    UITouch *anyTouch = event.allTouches.anyObject;
    CGPoint touchLocation = [anyTouch locationInView:self.view];
    ImGuiIO &io = ImGui::GetIO();
    io.MousePos = ImVec2(touchLocation.x, touchLocation.y);
    BOOL hasActiveTouch = NO;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) {
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

- (void)drawInMTKView:(MTKView*)view {
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize.x = view.bounds.size.width;
    io.DisplaySize.y = view.bounds.size.height;
    CGFloat framebufferScale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
    io.DisplayFramebufferScale = ImVec2(framebufferScale, framebufferScale);
    io.DeltaTime = 1 / float(view.preferredFramesPerSecond ?: 120);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    [self.view setUserInteractionEnabled:(MenDeal ? YES : NO)];

    MTLRenderPassDescriptor* renderPassDescriptor = view.currentRenderPassDescriptor;
    if (renderPassDescriptor != nil) {
        id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [renderEncoder pushDebugGroup:@"ImGui Jane"];

        ImGui_ImplMetal_NewFrame(renderPassDescriptor);
        ImGui::NewFrame();

        ImFont* font = ImGui::GetFont();
        font->Scale = 15.f / font->FontSize;

        CGFloat x = (([UIApplication sharedApplication].windows[0].rootViewController.view.frame.size.width) - 360) / 2;
        CGFloat y = (([UIApplication sharedApplication].windows[0].rootViewController.view.frame.size.height) - 300) / 2;
        ImGui::SetNextWindowPos(ImVec2(x, y), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(360, 270), ImGuiCond_FirstUseEver);

        // ------------------ ImGui Mod Menu ------------------
        if (MenDeal) {
            ImGui::Begin("URP Overlay", &MenDeal);
            ImGui::Text("Overlay Framework Active");
            ImGui::Separator();
            ImGui::Checkbox("Player 2D Box", &show_ESPBox);
            ImGui::Checkbox("Player Snaplines", &show_ESPLine);
            ImGui::Checkbox("Player Distance", &show_ESPDistance);
            ImGui::Checkbox("Show Offset Inspector", &show_Diagnostics);
            ImGui::Separator();
            ImGui::Text("FPS: %.1f", ImGui::GetIO().Framerate);
            ImGui::End();
        }

        // ------------------ Diagnostics & Engine Scanning (URP version) ------------------
        memset(&g_Diag, 0, sizeof(EngineDiagnostics));

        if (g_BaseAddress) {
            // 1. Get GWorld via GEngine->Viewport->World
            uintptr_t GEngine = ReadMemory<uintptr_t>(g_BaseAddress + OFF_GEngine);
            if (GEngine > 0x10000000) {
                uintptr_t Viewport = ReadMemory<uintptr_t>(GEngine + OFF_ViewPort);
                if (Viewport > 0x10000000) {
                    uintptr_t World = ReadMemory<uintptr_t>(Viewport + OFF_World);
                    if (World > 0x10000000) {
                        g_World = World;
                        g_Diag.detectedGWorld = World;
                    }
                }
            }

            if (g_World) {
                // 2. Scan for GameInstance (try common offsets)
                uintptr_t giOffsets[] = {0x24, 0x88, 0x90, 0x38, 0x140};
                for (int gi = 0; gi < 5; gi++) {
                    uintptr_t giCandidate = ReadMemory<uintptr_t>(g_World + giOffsets[gi]);
                    if (giCandidate > 0x10000000) {
                        g_Diag.detectedGameInstance = giCandidate;
                        // 3. Get LocalPlayer (first element of LocalPlayers array)
                        uintptr_t lpArray = ReadMemory<uintptr_t>(giCandidate + 0x38); // common offset for LocalPlayers
                        uintptr_t lpCandidate = ReadMemory<uintptr_t>(lpArray);
                        if (lpCandidate > 0x10000000) {
                            g_Diag.detectedLocalPlayer = lpCandidate;
                            // 4. Get PlayerController
                            uintptr_t pcCandidate = ReadMemory<uintptr_t>(lpCandidate + OFF_PlayerController);
                            if (pcCandidate > 0x10000000) {
                                g_Controller = pcCandidate;
                                g_Diag.detectedController = pcCandidate;
                                // 5. Get CameraManager
                                uintptr_t cam = ReadMemory<uintptr_t>(pcCandidate + OFF_PlayerCameraManager);
                                if (cam > 0x10000000) {
                                    g_CameraManager = cam;
                                }
                            }
                        }
                        break;
                    }
                }

                // 6. Get Level and ActorArray using OFF_Actors (0xA0)
                uintptr_t lvlOffsets[] = {0x30, 0x20, 0x90, 0x98, 0x138};
                for (int li = 0; li < 5; li++) {
                    uintptr_t lvlCandidate = ReadMemory<uintptr_t>(g_World + lvlOffsets[li]);
                    if (lvlCandidate > 0x10000000) {
                        uintptr_t arr = ReadMemory<uintptr_t>(lvlCandidate + OFF_Actors);
                        int cnt = ReadMemory<int>(lvlCandidate + OFF_Actors + 0x8);
                        if (arr > 0x10000000 && cnt > 0 && cnt < 2048) {
                            g_Diag.detectedLevel = lvlCandidate;
                            g_Diag.detectedActorArray = arr;
                            g_Diag.detectedActorCount = cnt;
                            break;
                        }
                    }
                }
            }
        }

        // ------------------ ESP Drawing ------------------
        ImDrawList* drawList = ImGui::GetForegroundDrawList();
        float viewWidth = view.bounds.size.width;
        float viewHeight = view.bounds.size.height;

        // Try to get view/proj matrices for manual W2S
        float viewMat[16] = {0}, projMat[16] = {0};
        bool w2sReady = false;
        if (g_CameraManager) {
            w2sReady = GetViewProjectionMatrices(g_CameraManager, viewMat, projMat);
        }
        g_Diag.w2sWorking = w2sReady;

        if (g_Diag.detectedActorCount > 0 && g_Diag.detectedActorArray && g_Controller && w2sReady) {
            for (int i = 0; i < g_Diag.detectedActorCount; i++) {
                uintptr_t actor = ReadMemory<uintptr_t>(g_Diag.detectedActorArray + (i * sizeof(uintptr_t)));
                if (!actor) continue;

                // Try to get RootComponent
                uintptr_t rootOffsets[] = {0x140, 0x130, 0x138, 0x148, 0x180};
                uintptr_t rootComp = 0;
                for (int r = 0; r < 5; r++) {
                    rootComp = ReadMemory<uintptr_t>(actor + rootOffsets[r]);
                    if (rootComp > 0x10000000) break;
                }
                if (!rootComp) continue;

                // Read position (RelativeLocation)
                Vector3 actorPos = ReadMemory<Vector3>(rootComp + OFF_RelativeLocation);
                if (actorPos.X == 0 && actorPos.Y == 0 && actorPos.Z == 0) continue;

                // Estimate head and feet
                Vector3 headPos = actorPos; headPos.Z += 80.0f;
                Vector3 feetPos = actorPos; feetPos.Z -= 80.0f;

                Vector2 screenHead, screenFeet, screenPos;
                if (ProjectWorldToScreen(headPos, screenHead, viewMat, projMat, viewWidth, viewHeight) &&
                    ProjectWorldToScreen(feetPos, screenFeet, viewMat, projMat, viewWidth, viewHeight) &&
                    ProjectWorldToScreen(actorPos, screenPos, viewMat, projMat, viewWidth, viewHeight)) {

                    g_Diag.renderedActors++;

                    float boxHeight = fabsf(screenFeet.Y - screenHead.Y);
                    float boxWidth = boxHeight / 2.0f;
                    float boxLeft = screenHead.X - (boxWidth / 2.0f);
                    float boxRight = screenHead.X + (boxWidth / 2.0f);

                    if (show_ESPLine) {
                        drawList->AddLine(
                            ImVec2(viewWidth / 2.0f, 60.0f),
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

                    if (show_ESPDistance) {
                        float distance = sqrtf(actorPos.X*actorPos.X + actorPos.Y*actorPos.Y + actorPos.Z*actorPos.Z) / 100.0f;
                        char distText[32];
                        snprintf(distText, sizeof(distText), "%.1fm", distance);
                        drawList->AddText(ImVec2(screenHead.X - 10, screenHead.Y - 20), IM_COL32(255, 255, 255, 255), distText);
                    }
                }
            }
        }

        // ------------------ On-Screen Diagnostics Inspector ------------------
        if (show_Diagnostics) {
            char debugText[512];
            snprintf(debugText, sizeof(debugText),
                     "[Engine Inspector (URP)]\n"
                     "BaseAddr: 0x%lx\n"
                     "W2S: %s\n"
                     "GWorld: 0x%lx\n"
                     "GameInstance: 0x%lx\n"
                     "LocalPlayer: 0x%lx\n"
                     "Controller: 0x%lx\n"
                     "CameraManager: 0x%lx\n"
                     "Level: 0x%lx\n"
                     "ActorArray: 0x%lx\n"
                     "ActorCount: %d\n"
                     "Rendered ESP: %d",
                     g_BaseAddress,
                     g_Diag.w2sWorking ? "OK" : "FAIL",
                     g_Diag.detectedGWorld,
                     g_Diag.detectedGameInstance,
                     g_Diag.detectedLocalPlayer,
                     g_Diag.detectedController,
                     g_CameraManager,
                     g_Diag.detectedLevel,
                     g_Diag.detectedActorArray,
                     g_Diag.detectedActorCount,
                     g_Diag.renderedActors);

            drawList->AddRectFilled(ImVec2(20, 40), ImVec2(340, 240), IM_COL32(10, 15, 25, 210), 6.0f);
            drawList->AddRect(ImVec2(20, 40), ImVec2(340, 240), IM_COL32(0, 255, 200, 180), 6.0f);
            drawList->AddText(ImVec2(28, 46), IM_COL32(255, 255, 255, 255), debugText);
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

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {}

@end

// =========================================================
// GLOBAL CONSTRUCTORS
// =========================================================

__attribute__((constructor))
static void initializeURPOffsets() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_BaseAddress = (uintptr_t)_dyld_get_image_header(0);
        // ProcessEvent can be set here if needed:
        // ProcessEvent = (_ProcessEvent)(g_BaseAddress + OFF_ProcessEvent_Main);
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
