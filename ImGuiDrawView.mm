#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <Security/Security.h>
#import <stddef.h>
#import <string.h>
#import <vector>
#import <cmath>

// Imgui library
#import "Esp/CaptainHook.h"
#import "Esp/ImGuiDrawView.h"
#import "IMGUI/imgui.h"
#import "IMGUI/imgui_impl_metal.h"
#import "IMGUI/Honkai.h"
#import "Vector.h" // Added for Vector3 support

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

// =========================================================
// NEW VERIFIED PUBG 4.5 NARUTO UPDATE OFFSETS
// =========================================================
namespace UEPointers {
    constexpr uintptr_t Names        = 0x5014128;
    constexpr uintptr_t GWorld       = 0x95F23B0;
    constexpr uintptr_t ViewMatrix   = 0x97DEF38;
}

namespace UOffsets {
    constexpr uintptr_t World_PersistentLevel    = 0x30;
    constexpr uintptr_t Level_Actors             = 0xA0;
    constexpr uintptr_t Level_ActorCount         = 0xA8;
    constexpr uintptr_t World_OwningGameInstance = 0x28;
    constexpr uintptr_t GameInstance_LocalPlayers = 0x38;
    constexpr uintptr_t Player_Controller        = 0x30;
    constexpr uintptr_t Controller_AcknowledgedPawn = 0x2A0;
    constexpr uintptr_t Actor_RootComponent      = 0x150;
    constexpr uintptr_t RootComp_Location        = 0x1A0;
}

// =========================================================
// FOUNDATIONAL UTILITY FUNCTIONS
// =========================================================
template <typename T>
T ReadMemory(uintptr_t address) {
    if (address < 0x100000000 || address > 0x3000000000) return T();
    return *(T*)address;
}

uintptr_t GetGameBase() {
    return (uintptr_t)_dyld_get_image_header(0);
}

// =========================================================
// ESP RENDERER FUNCTION
// =========================================================
void RenderPubgLineESP() {
    ImDrawList* drawList = ImGui::GetForegroundDrawList();
    if (!drawList) return;
    
    float ScreenWidth = ImGui::GetIO().DisplaySize.x;
    float ScreenHeight = ImGui::GetIO().DisplaySize.y;
    
    uintptr_t base = GetGameBase();
    if (!base) return;
    
    uintptr_t GWorld = ReadMemory<uintptr_t>(base + UEPointers::GWorld);
    if (!GWorld) return;
    
    uintptr_t PersistentLevel = ReadMemory<uintptr_t>(GWorld + UOffsets::World_PersistentLevel);
    if (!PersistentLevel) return;
    
    uintptr_t ActorArray = ReadMemory<uintptr_t>(PersistentLevel + UOffsets::Level_Actors);
    int ActorCount = ReadMemory<int>(PersistentLevel + UOffsets::Level_ActorCount);
    if (!ActorArray || ActorCount <= 0) return;
    
    uintptr_t GameInstance = ReadMemory<uintptr_t>(GWorld + UOffsets::World_OwningGameInstance);
    if (!GameInstance) return;
    
    uintptr_t LocalPlayerArray = ReadMemory<uintptr_t>(GameInstance + UOffsets::GameInstance_LocalPlayers);
    if (!LocalPlayerArray) return;
    
    uintptr_t LocalPlayer = ReadMemory<uintptr_t>(LocalPlayerArray + 0x0);
    if (!LocalPlayer) return;
    
    uintptr_t PlayerController = ReadMemory<uintptr_t>(LocalPlayer + UOffsets::Player_Controller);
    if (!PlayerController) return;
    
    uintptr_t LocalPawn = ReadMemory<uintptr_t>(PlayerController + UOffsets::Controller_AcknowledgedPawn);
    if (!LocalPawn) return;
    
    uintptr_t LocalRoot = ReadMemory<uintptr_t>(LocalPawn + UOffsets::Actor_RootComponent);
    if (!LocalRoot) return;
    
    Vector3 LocalPos = ReadMemory<Vector3>(LocalRoot + UOffsets::RootComp_Location);
    
    FMatrix ActiveMatrix = ReadMemory<FMatrix>(base + UEPointers::ViewMatrix);
    
    for (int i = 0; i < ActorCount; i++) {
        uintptr_t EnemyActor = ReadMemory<uintptr_t>(ActorArray + (i * 8));
        if (!EnemyActor || EnemyActor == LocalPawn) continue;
        
        uintptr_t EnemyRoot = ReadMemory<uintptr_t>(EnemyActor + UOffsets::Actor_RootComponent);
        if (!EnemyRoot) continue;
        
        Vector3 EnemyPos = ReadMemory<Vector3>(EnemyRoot + UOffsets::RootComp_Location);
        
        float CurrentDistance = LocalPos.Distance(EnemyPos);
        
        // Constraint check: Show red line only if distance is up to 50 meters
        if (CurrentDistance > 0.1f && CurrentDistance <= 50.0f) {
            Vector2 ScreenCoordinates;
            if (CustomWorldToScreen(EnemyPos, ActiveMatrix, ScreenWidth, ScreenHeight, ScreenCoordinates)) {
                drawList->AddLine(
                    ImVec2(ScreenWidth / 2.0f, ScreenHeight),
                    ImVec2(ScreenCoordinates.X, ScreenCoordinates.Y),
                    IM_COL32(255, 0, 0, 255),
                    1.5f
                );
            }
        }
    }
}

// =========================================================
// ORIGINAL CODE CONTINUES BELOW
// =========================================================

// --- Vector structures ---
struct Vector3_Old { float X, Y, Z; };
struct Vector2_Old { float X, Y; };
struct FMatrix16 {
    float M[16];
};

// --- Global Addresses & State ---
static uintptr_t g_BaseAddress = 0;
static uintptr_t g_GEngine = 0;
static uintptr_t g_GWorld = 0;
static uintptr_t g_GNames = 0;
static uintptr_t g_GUObjectArray = 0;
static uintptr_t g_Controller = 0;
static uintptr_t g_CameraManager = 0;
static uintptr_t g_ActorArray = 0;
static int g_ActorCount = 0;
static int g_ViewMatOff = 0x30;
static int g_ProjMatOff = 0x70;
static Vector3_Old g_LocalPlayerPos = {0, 0, 0};
static uintptr_t g_LocalPawn = 0;
static bool g_Initialized = false;

// --- Safe Memory Reader ---
template <typename T>
static inline T ReadMemory_Old(uintptr_t address, T defaultValue = T()) {
    if (!address || address < 0x10000000 || address > 0x3000000000ULL) return defaultValue;
    T buffer;
    vm_size_t size = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, sizeof(T), (vm_address_t)&buffer, &size);
    if (kr == KERN_SUCCESS && size == sizeof(T)) return buffer;
    return defaultValue;
}

// --- VTable validation with expanded window ---
static bool IsValidVTable(uintptr_t obj) {
    if (!obj || obj < 0x10000000 || obj > 0x3000000000ULL) return false;
    uintptr_t vtable = ReadMemory_Old<uintptr_t>(obj);
    if (!vtable || vtable < g_BaseAddress || vtable > g_BaseAddress + 0x30000000) return false;
    return true;
}

// --- Actor Class Name Extraction ---
static uint32_t GetActorClassIndex(uintptr_t Actor) {
    uintptr_t classPtr = ReadMemory_Old<uintptr_t>(Actor + 0x8);
    if (!classPtr || classPtr < 0x10000000) return 0;
    uintptr_t namePtr = ReadMemory_Old<uintptr_t>(classPtr + 0x18);
    if (!namePtr || namePtr < 0x10000000) return 0;
    return ReadMemory_Old<uint32_t>(namePtr + 0x0);
}

// --- Get FName string from index ---
static std::string GetNameFromIndex(uint32_t nameIndex) {
    if (!g_GNames || nameIndex == 0) return "Unknown";
    
    uintptr_t namesData = ReadMemory_Old<uintptr_t>(g_GNames);
    if (!namesData) return "Unknown";
    
    uintptr_t entryPtr = ReadMemory_Old<uintptr_t>(namesData + (nameIndex * sizeof(uintptr_t)));
    if (!entryPtr) return "Unknown";
    
    int32_t len = ReadMemory_Old<int32_t>(entryPtr);
    if (len <= 0 || len > 128) return "Unknown";
    
    char name[128] = {0};
    for (int i = 0; i < len && i < 127; i++) {
        name[i] = ReadMemory_Old<char>(entryPtr + 4 + i);
    }
    name[len] = '\0';
    return std::string(name);
}

// --- Actor Class Filtering ---
static bool IsPlayerActor(uintptr_t Actor) {
    uint32_t classIndex = GetActorClassIndex(Actor);
    if (classIndex == 0) return false;
    
    std::string className = GetNameFromIndex(classIndex);
    
    static const char* playerClasses[] = {
        "Character",
        "PlayerCharacter",
        "BP_PlayerCharacter",
        "PlayerPawn",
        "HumanoidCharacter",
        "BP_Humanoid",
        "ThirdPersonCharacter",
        "Pawn"
    };
    
    for (const char* playerClass : playerClasses) {
        if (className.find(playerClass) != std::string::npos) {
            return true;
        }
    }
    
    static const char* nonPlayerClasses[] = {
        "Light",
        "Volume",
        "ActorComponent",
        "PrimitiveComponent",
        "PhysicsVolume",
        "Brush",
        "StaticMeshActor",
        "TriggerBase",
        "BlockingVolume",
        "SkeletalMeshActor",
        "CameraActor",
        "PlayerStart",
        "NavigationData",
        "GameState",
        "GameMode",
        "PlayerState",
        "Controller"
    };
    
    for (const char* nonPlayerClass : nonPlayerClasses) {
        if (className.find(nonPlayerClass) != std::string::npos) {
            return false;
        }
    }
    
    uintptr_t movement = ReadMemory_Old<uintptr_t>(Actor + 0x2F8);
    if (movement && movement > 0x10000000) {
        uintptr_t movementVtable = ReadMemory_Old<uintptr_t>(movement);
        if (movementVtable && movementVtable > g_BaseAddress) {
            return true;
        }
    }
    
    uintptr_t mesh = ReadMemory_Old<uintptr_t>(Actor + 0x4D8);
    uintptr_t rootComp = ReadMemory_Old<uintptr_t>(Actor + 0x208);
    if (mesh && mesh > 0x10000000 && rootComp && rootComp > 0x10000000) {
        return true;
    }
    
    return false;
}

// --- Matrix Detection Structures ---
struct FMinimalViewInfo {
    Vector3_Old Location;
    Vector3_Old Rotation;
    float FOV;
};

struct FCameraCacheEntry {
    float Timestamp;
    FMinimalViewInfo POV;
};

// --- Safe matrix detection using FMatrix16 ---
static bool DetectMatrixOffsets(uintptr_t CameraManager, int& outViewOff, int& outProjOff) {
    if (!CameraManager) return false;
    uintptr_t cacheAddr = CameraManager + 0x4B0;
    FCameraCacheEntry cache = ReadMemory_Old<FCameraCacheEntry>(cacheAddr);
    if (cache.Timestamp == 0) return false;
    uintptr_t povAddr = cacheAddr + offsetof(FCameraCacheEntry, POV);
    
    int candidates[] = {0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0};
    for (int vOff : candidates) {
        for (int pOff : candidates) {
            if (vOff == pOff) continue;
            
            FMatrix16 viewMat = ReadMemory_Old<FMatrix16>(povAddr + vOff);
            FMatrix16 projMat = ReadMemory_Old<FMatrix16>(povAddr + pOff);
            
            float sumV = 0; 
            for (int i = 0; i < 16; i++) sumV += fabsf(viewMat.M[i]);
            if (sumV < 0.1f) continue;
            
            float sumP = 0; 
            for (int i = 0; i < 16; i++) sumP += fabsf(projMat.M[i]);
            if (sumP < 0.1f) continue;
            
            outViewOff = vOff;
            outProjOff = pOff;
            return true;
        }
    }
    return false;
}

// --- Dynamic Multi-Offset Scanning Initialization ---
static void InitializePointers() {
    if (!g_BaseAddress) return;
    
    g_Initialized = false;

    // 1. GEngine
    g_GEngine = ReadMemory_Old<uintptr_t>(g_BaseAddress + 0xaa10ca0);
    if (!g_GEngine) return;

    // 2. GNames
    g_GNames = ReadMemory_Old<uintptr_t>(g_BaseAddress + 0xff36cb0);

    // 3. GameViewport
    uintptr_t gameViewport = ReadMemory_Old<uintptr_t>(g_GEngine + 0x810);
    if (!gameViewport || gameViewport < 0x10000000) return;

    // 4. UWorld
    g_GWorld = ReadMemory_Old<uintptr_t>(gameViewport + 0x80);
    if (!g_GWorld || g_GWorld < 0x10000000) return;

    // 5. PersistentLevel -> Actors with dynamic scanning
    uintptr_t persistentLevel = ReadMemory_Old<uintptr_t>(g_GWorld + 0x30);
    if (persistentLevel && persistentLevel > 0x10000000) {
        uintptr_t actorOffsets[] = {0x98, 0xA0, 0xA8, 0xB0, 0xB8, 0xC0};
        for (uintptr_t offset : actorOffsets) {
            g_ActorArray = ReadMemory_Old<uintptr_t>(persistentLevel + offset);
            g_ActorCount = ReadMemory_Old<int>(persistentLevel + offset + 0x8);
            if (g_ActorArray && g_ActorArray > 0x10000000 && g_ActorCount > 0) {
                break;
            }
        }
        
        if (!g_ActorArray || g_ActorCount <= 0) {
            uintptr_t clusterOffsets[] = {0xE0, 0xF8, 0x100, 0xA8};
            for (uintptr_t offset : clusterOffsets) {
                uintptr_t actorCluster = ReadMemory_Old<uintptr_t>(persistentLevel + offset);
                if (actorCluster && actorCluster > 0x10000000) {
                    g_ActorArray = ReadMemory_Old<uintptr_t>(actorCluster + 0x28);
                    g_ActorCount = ReadMemory_Old<int>(actorCluster + 0x28 + 0x8);
                    if (g_ActorArray && g_ActorArray > 0x10000000 && g_ActorCount > 0) {
                        break;
                    }
                }
            }
        }
    }

    // 6. GameInstance with dynamic scanning
    uintptr_t gameInstance = 0;
    uintptr_t instanceOffsets[] = {0x470, 0x1A8, 0x1B0, 0x1B8};
    for (uintptr_t offset : instanceOffsets) {
        gameInstance = ReadMemory_Old<uintptr_t>(g_GWorld + offset);
        if (gameInstance && gameInstance > 0x10000000) {
            break;
        }
    }
    
    if (gameInstance && gameInstance > 0x10000000) {
        uintptr_t localPlayersArray = ReadMemory_Old<uintptr_t>(gameInstance + 0x48);
        if (localPlayersArray && localPlayersArray > 0x10000000) {
            uintptr_t lp = ReadMemory_Old<uintptr_t>(localPlayersArray);
            if (lp && lp > 0x10000000) {
                uintptr_t controllerOffsets[] = {0x30, 0x38, 0x40};
                for (uintptr_t offset : controllerOffsets) {
                    g_Controller = ReadMemory_Old<uintptr_t>(lp + offset);
                    if (g_Controller && g_Controller > 0x10000000) {
                        break;
                    }
                }
                
                if (g_Controller && g_Controller > 0x10000000) {
                    g_CameraManager = ReadMemory_Old<uintptr_t>(g_Controller + 0x4D0);
                    
                    g_LocalPawn = ReadMemory_Old<uintptr_t>(g_Controller + 0x4B8);
                    if (g_LocalPawn && g_LocalPawn > 0x10000000) {
                        uintptr_t rootComp = ReadMemory_Old<uintptr_t>(g_LocalPawn + 0x208);
                        if (rootComp && rootComp > 0x10000000) {
                            g_LocalPlayerPos = ReadMemory_Old<Vector3_Old>(rootComp + 0x120);
                        }
                    }
                }
            }
        }
    }

    // 7. Camera Matrix Setup
    if (g_CameraManager && g_CameraManager > 0x10000000) {
        int vOff, pOff;
        if (DetectMatrixOffsets(g_CameraManager, vOff, pOff)) {
            g_ViewMatOff = vOff;
            g_ProjMatOff = pOff;
        }
    }
    
    if (g_GWorld && g_ActorArray && g_ActorCount > 0 && g_Controller && g_CameraManager) {
        g_Initialized = true;
    }
}

// --- Safe W2S Functions ---
static bool GetViewProjectionMatrices(uintptr_t CameraManager, float* outViewMatrix, float* outProjMatrix) {
    if (!CameraManager) return false;
    uintptr_t cacheAddr = CameraManager + 0x4B0;
    FCameraCacheEntry cache = ReadMemory_Old<FCameraCacheEntry>(cacheAddr);
    if (cache.Timestamp == 0) return false;
    uintptr_t povAddr = cacheAddr + offsetof(FCameraCacheEntry, POV);
    
    FMatrix16 viewMat = ReadMemory_Old<FMatrix16>(povAddr + g_ViewMatOff);
    FMatrix16 projMat = ReadMemory_Old<FMatrix16>(povAddr + g_ProjMatOff);
    
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            outViewMatrix[i * 4 + j] = viewMat.M[j * 4 + i];
            outProjMatrix[i * 4 + j] = projMat.M[j * 4 + i];
        }
    }
    return true;
}

static bool ProjectWorldToScreen(Vector3_Old worldPos, Vector2_Old& screenPos, float* viewMatrix, float* projMatrix, int screenWidth, int screenHeight) {
    float x = viewMatrix[0] * worldPos.X + viewMatrix[4] * worldPos.Y + viewMatrix[8] * worldPos.Z + viewMatrix[12];
    float y = viewMatrix[1] * worldPos.X + viewMatrix[5] * worldPos.Y + viewMatrix[9] * worldPos.Z + viewMatrix[13];
    float z = viewMatrix[2] * worldPos.X + viewMatrix[6] * worldPos.Y + viewMatrix[10] * worldPos.Z + viewMatrix[14];
    float w = viewMatrix[3] * worldPos.X + viewMatrix[7] * worldPos.Y + viewMatrix[11] * worldPos.Z + viewMatrix[15];
    
    if (w < 0.001f) return false;

    float clipX = projMatrix[0] * x + projMatrix[4] * y + projMatrix[8] * z + projMatrix[12] * w;
    float clipY = projMatrix[1] * x + projMatrix[5] * y + projMatrix[9] * z + projMatrix[13] * w;
    float clipW = projMatrix[3] * x + projMatrix[7] * y + projMatrix[11] * z + projMatrix[15] * w;
    
    if (clipW < 0.001f) return false;

    float ndcX = clipX / clipW;
    float ndcY = clipY / clipW;
    screenPos.X = (ndcX * 0.5f + 0.5f) * screenWidth;
    screenPos.Y = (1.0f - (ndcY * 0.5f + 0.5f)) * screenHeight;
    return true;
}

// --- UI Globals ---
static bool MenDeal = true;
static bool show_ESPBox = true;
static bool show_ESPLine = true;
static bool show_ESPDistance = true;
static bool show_Diagnostics = true;
static CGRect g_ImGuiWindowRect = CGRectZero;

// --- Custom MTKView ---
@interface CustomMTKView : MTKView
@end

@implementation CustomMTKView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!MenDeal) return NO;
    if (CGRectContainsPoint(g_ImGuiWindowRect, point)) return YES;
    return NO;
}
@end

// --- ImGuiDrawView Implementation ---
@interface ImGuiDrawView () <MTKViewDelegate>
@property (nonatomic, strong) id <MTLDevice> device;
@property (nonatomic, strong) id <MTLCommandQueue> commandQueue;
@end

@implementation ImGuiDrawView

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];
    if (!self.device) abort();

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); (void)io;
    ImGui::StyleColorsClassic();
    io.Fonts->AddFontFromMemoryCompressedTTF((void*)Honkai_compressed_data, Honkai_compressed_size, 45.0f, NULL, io.Fonts->GetGlyphRangesDefault());
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

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        InitializePointers();
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

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateTouch:touches isDown:YES]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateTouch:touches isDown:YES]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateTouch:touches isDown:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateTouch:touches isDown:NO]; }

#pragma mark - Render Loop

- (void)drawInMTKView:(MTKView*)view {
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize.x = view.bounds.size.width;
    io.DisplaySize.y = view.bounds.size.height;
    CGFloat framebufferScale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
    io.DisplayFramebufferScale = ImVec2(framebufferScale, framebufferScale);
    io.DeltaTime = 1 / float(view.preferredFramesPerSecond ?: 120);

    if (!g_Initialized || !g_GWorld || !g_ActorArray || g_ActorCount <= 0) {
        InitializePointers();
    }

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

        // --- Menu Window ---
        if (MenDeal) {
            ImGui::Begin("URP Overlay", &MenDeal);
            ImVec2 winPos = ImGui::GetWindowPos();
            ImVec2 winSize = ImGui::GetWindowSize();
            g_ImGuiWindowRect = CGRectMake(winPos.x, winPos.y, winSize.x, winSize.y);

            ImGui::Text("Overlay Framework Active");
            ImGui::Separator();
            ImGui::Checkbox("Player 2D Box", &show_ESPBox);
            ImGui::Checkbox("Player Snaplines", &show_ESPLine);
            ImGui::Checkbox("Player Distance", &show_ESPDistance);
            ImGui::Checkbox("Show Diagnostics", &show_Diagnostics);
            ImGui::Separator();
            ImGui::Text("FPS: %.1f", ImGui::GetIO().Framerate);
            ImGui::Text("Actors: %d", g_ActorCount);
            ImGui::Text("Initialized: %s", g_Initialized ? "YES" : "NO");
            ImGui::End();
        } else {
            g_ImGuiWindowRect = CGRectZero;
        }

        // --- Pubg Line ESP ---
        RenderPubgLineESP();

        // --- ESP Drawing ---
        ImDrawList* drawList = ImGui::GetForegroundDrawList();
        float viewWidth = view.bounds.size.width;
        float viewHeight = view.bounds.size.height;

        float viewMat[16] = {0}, projMat[16] = {0};
        bool w2sReady = false;
        if (g_CameraManager) {
            w2sReady = GetViewProjectionMatrices(g_CameraManager, viewMat, projMat);
        }

        if (g_Initialized && g_ActorArray && g_ActorCount > 0 && g_Controller && w2sReady) {
            int playerCount = 0;
            for (int i = 0; i < g_ActorCount; i++) {
                uintptr_t actor = ReadMemory_Old<uintptr_t>(g_ActorArray + (i * sizeof(uintptr_t)));
                if (!actor || !IsValidVTable(actor)) continue;

                if (!IsPlayerActor(actor)) continue;
                if (actor == g_LocalPawn) continue;

                uintptr_t actorController = ReadMemory_Old<uintptr_t>(actor + 0x4B8);
                if (actorController == g_Controller) continue;

                uintptr_t rootComp = ReadMemory_Old<uintptr_t>(actor + 0x208);
                if (!rootComp || !IsValidVTable(rootComp)) continue;

                Vector3_Old actorPos = ReadMemory_Old<Vector3_Old>(rootComp + 0x120);
                if (actorPos.X == 0 && actorPos.Y == 0 && actorPos.Z == 0) continue;

                float dx = actorPos.X - g_LocalPlayerPos.X;
                float dy = actorPos.Y - g_LocalPlayerPos.Y;
                float dz = actorPos.Z - g_LocalPlayerPos.Z;
                float relativeDistance = sqrtf(dx*dx + dy*dy + dz*dz) / 100.0f;

                if (relativeDistance > 200.0f || relativeDistance < 0.5f) continue;

                uintptr_t mesh = ReadMemory_Old<uintptr_t>(actor + 0x4D8);
                Vector3_Old headPos = actorPos;
                Vector3_Old feetPos = actorPos;
                
                if (mesh && mesh > 0x10000000) {
                    uintptr_t boneArray = ReadMemory_Old<uintptr_t>(mesh + 0x4A0);
                    if (boneArray && boneArray > 0x10000000) {
                        uintptr_t headBone = ReadMemory_Old<uintptr_t>(boneArray + 7 * 0x30);
                        if (headBone && headBone > 0x10000000) {
                            Vector3_Old bonePos = ReadMemory_Old<Vector3_Old>(headBone + 0x20);
                            headPos.X = actorPos.X + bonePos.X;
                            headPos.Y = actorPos.Y + bonePos.Y;
                            headPos.Z = actorPos.Z + bonePos.Z;
                        }
                    }
                }
                
                if (headPos.X == actorPos.X && headPos.Y == actorPos.Y && headPos.Z == actorPos.Z) {
                    headPos.Z += 80.0f;
                    feetPos.Z -= 80.0f;
                } else {
                    feetPos.Z = headPos.Z - 160.0f;
                }

                Vector2_Old screenHead, screenFeet, screenPos;

                if (ProjectWorldToScreen(headPos, screenHead, viewMat, projMat, viewWidth, viewHeight) &&
                    ProjectWorldToScreen(feetPos, screenFeet, viewMat, projMat, viewWidth, viewHeight) &&
                    ProjectWorldToScreen(actorPos, screenPos, viewMat, projMat, viewWidth, viewHeight)) {

                    if (screenHead.Y < 0 || screenHead.Y > viewHeight || 
                        screenHead.X < 0 || screenHead.X > viewWidth) continue;

                    float boxHeight = fabsf(screenFeet.Y - screenHead.Y);
                    if (boxHeight < 5.0f) continue;
                    
                    float boxWidth = boxHeight / 2.5f;
                    float boxLeft = screenHead.X - (boxWidth / 2.0f);

                    ImU32 color = IM_COL32(255, 40, 40, 255);
                    if (relativeDistance < 30.0f) color = IM_COL32(255, 0, 0, 255);
                    else if (relativeDistance < 60.0f) color = IM_COL32(255, 165, 0, 255);
                    else if (relativeDistance < 100.0f) color = IM_COL32(255, 255, 0, 255);
                    else color = IM_COL32(0, 255, 0, 255);

                    if (show_ESPLine) {
                        drawList->AddLine(ImVec2(viewWidth / 2, viewHeight), 
                                         ImVec2(screenHead.X, screenHead.Y), 
                                         color, 1.5f);
                    }
                    if (show_ESPBox) {
                        drawList->AddRect(ImVec2(boxLeft, screenHead.Y), 
                                         ImVec2(boxLeft + boxWidth, screenFeet.Y), 
                                         color, 0.0f, 0, 1.6f);
                    }
                    if (show_ESPDistance) {
                        char txt[32];
                        snprintf(txt, sizeof(txt), "%.1fm", relativeDistance);
                        txt[sizeof(txt) - 1] = '\0';
                        drawList->AddText(ImVec2(screenHead.X - 10, screenHead.Y - 20), 
                                         IM_COL32(255, 255, 255, 255), txt);
                    }
                    playerCount++;
                }
            }
            
            if (playerCount > 0) {
                char countText[64];
                snprintf(countText, sizeof(countText), "Players: %d", playerCount);
                drawList->AddText(ImVec2(20, 20), IM_COL32(0, 255, 0, 255), countText);
            }
        }

        // --- Diagnostics Window ---
        if (show_Diagnostics) {
            ImGui::Begin("Diagnostics", &show_Diagnostics);
            ImGui::Text("Base: 0x%lx", g_BaseAddress);
            ImGui::Text("GWorld: 0x%lx", g_GWorld);
            ImGui::Text("Actors: %d", g_ActorCount);
            ImGui::Text("Controller: 0x%lx", g_Controller);
            ImGui::Text("CameraManager: 0x%lx", g_CameraManager);
            ImGui::End();
        }

        // --- Render ImGui Frame ---
        ImGui::Render();
        ImDrawData* draw_data = ImGui::GetDrawData();
        ImGui_ImplMetal_RenderDrawData(draw_data, commandBuffer, renderEncoder);

        [renderEncoder popDebugGroup];
        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:view.currentDrawable];
    }

    [commandBuffer commit];
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
    // Handling resize event
}

@end
