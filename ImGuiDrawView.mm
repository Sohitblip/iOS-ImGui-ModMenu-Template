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

// --- Relative RVA Offsets (Base 0x100000000 Subtracted) ---
namespace UEPointers {
    constexpr uintptr_t Names        = 0xff36cb0;
    constexpr uintptr_t UObjectArray = 0xa7f93e0;
    constexpr uintptr_t ObjObjects   = 0xa7f93f0;
    constexpr uintptr_t Engine       = 0xaa10ca0;
    constexpr uintptr_t ProcessEvent = 0x51afe1c;
}

// --- Verified Member Offsets from Dump ---
namespace UOffsets {
    constexpr uintptr_t Engine_GameViewport      = 0x810;
    constexpr uintptr_t Viewport_World           = 0x80;
    constexpr uintptr_t World_PersistentLevel    = 0x30;
    constexpr uintptr_t World_OwningGameInstance = 0x470;
    
    // Level -> Actors array
    constexpr uintptr_t Level_Actors             = 0x98;
    constexpr uintptr_t Level_ActorCluster       = 0xE0;
    constexpr uintptr_t Cluster_Actors           = 0x28;
    
    // LocalPlayers from Dump
    constexpr uintptr_t GameInstance_LocalPlayers = 0x48;
    constexpr uintptr_t Player_Controller        = 0x30;
    constexpr uintptr_t Controller_CameraManager = 0x4D0;
    constexpr uintptr_t Actor_RootComponent      = 0x208;
    constexpr uintptr_t RootComp_Location        = 0x120;
    constexpr uintptr_t Character_Mesh           = 0x4D8;
    constexpr uintptr_t Pawn_Controller          = 0x4B8;
    constexpr uintptr_t Actor_Class              = 0x8;
    constexpr uintptr_t Class_NameIndex          = 0x18;
    constexpr uintptr_t Name_ComparisonIndex     = 0x0;
}

// --- Vector structures ---
struct Vector3 { float X, Y, Z; };
struct Vector2 { float X, Y; };

// --- Matrix structure for safe reading ---
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
static Vector3 g_LocalPlayerPos = {0, 0, 0};
static uintptr_t g_LocalPawn = 0;
static bool g_Initialized = false;

// --- Safe Memory Reader ---
template <typename T>
static inline T ReadMemory(uintptr_t address, T defaultValue = T()) {
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
    uintptr_t vtable = ReadMemory<uintptr_t>(obj);
    if (!vtable || vtable < g_BaseAddress || vtable > g_BaseAddress + 0x30000000) return false;
    return true;
}

// --- Actor Class Name Extraction (for filtering) ---
static uint32_t GetActorClassIndex(uintptr_t Actor) {
    uintptr_t classPtr = ReadMemory<uintptr_t>(Actor + UOffsets::Actor_Class);
    if (!classPtr || classPtr < 0x10000000) return 0;
    uintptr_t namePtr = ReadMemory<uintptr_t>(classPtr + UOffsets::Class_NameIndex);
    if (!namePtr || namePtr < 0x10000000) return 0;
    return ReadMemory<uint32_t>(namePtr + UOffsets::Name_ComparisonIndex);
}

// --- Get FName string from index (simplified) ---
static std::string GetNameFromIndex(uint32_t nameIndex) {
    if (!g_GNames || nameIndex == 0) return "Unknown";
    
    uintptr_t namesData = ReadMemory<uintptr_t>(g_GNames);
    if (!namesData) return "Unknown";
    
    uintptr_t entryPtr = ReadMemory<uintptr_t>(namesData + (nameIndex * sizeof(uintptr_t)));
    if (!entryPtr) return "Unknown";
    
    int32_t len = ReadMemory<int32_t>(entryPtr);
    if (len <= 0 || len > 128) return "Unknown";
    
    char name[128] = {0};
    for (int i = 0; i < len && i < 127; i++) {
        name[i] = ReadMemory<char>(entryPtr + 4 + i);
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
    
    uintptr_t movement = ReadMemory<uintptr_t>(Actor + 0x2F8);
    if (movement && movement > 0x10000000) {
        uintptr_t movementVtable = ReadMemory<uintptr_t>(movement);
        if (movementVtable && movementVtable > g_BaseAddress) {
            return true;
        }
    }
    
    uintptr_t mesh = ReadMemory<uintptr_t>(Actor + UOffsets::Character_Mesh);
    uintptr_t rootComp = ReadMemory<uintptr_t>(Actor + UOffsets::Actor_RootComponent);
    if (mesh && mesh > 0x10000000 && rootComp && rootComp > 0x10000000) {
        return true;
    }
    
    return false;
}

// --- Matrix Detection Structures ---
struct FMinimalViewInfo {
    Vector3 Location;
    Vector3 Rotation;
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
    FCameraCacheEntry cache = ReadMemory<FCameraCacheEntry>(cacheAddr);
    if (cache.Timestamp == 0) return false;
    uintptr_t povAddr = cacheAddr + offsetof(FCameraCacheEntry, POV);
    
    int candidates[] = {0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0};
    for (int vOff : candidates) {
        for (int pOff : candidates) {
            if (vOff == pOff) continue;
            
            FMatrix16 viewMat = ReadMemory<FMatrix16>(povAddr + vOff);
            FMatrix16 projMat = ReadMemory<FMatrix16>(povAddr + pOff);
            
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
    g_GEngine = ReadMemory<uintptr_t>(g_BaseAddress + UEPointers::Engine);
    if (!g_GEngine) g_GEngine = ReadMemory<uintptr_t>(0x10aa10ca0);
    if (!g_GEngine || g_GEngine < 0x10000000) return;

    // 2. GNames
    g_GNames = ReadMemory<uintptr_t>(g_BaseAddress + UEPointers::Names);
    if (!g_GNames) g_GNames = ReadMemory<uintptr_t>(0x10ff36cb0);

    // 3. GameViewport
    uintptr_t gameViewport = ReadMemory<uintptr_t>(g_GEngine + UOffsets::Engine_GameViewport);
    if (!gameViewport || gameViewport < 0x10000000) return;

    // 4. UWorld
    g_GWorld = ReadMemory<uintptr_t>(gameViewport + UOffsets::Viewport_World);
    if (!g_GWorld || g_GWorld < 0x10000000) return;

    // 5. PersistentLevel -> Actors with dynamic scanning
    uintptr_t persistentLevel = ReadMemory<uintptr_t>(g_GWorld + UOffsets::World_PersistentLevel);
    if (persistentLevel && persistentLevel > 0x10000000) {
        // Scan multiple offsets for Level_Actors
        uintptr_t actorOffsets[] = {0x98, 0xA0, 0xA8, 0xB0, 0xB8, 0xC0};
        for (uintptr_t offset : actorOffsets) {
            g_ActorArray = ReadMemory<uintptr_t>(persistentLevel + offset);
            g_ActorCount = ReadMemory<int>(persistentLevel + offset + 0x8);
            if (g_ActorArray && g_ActorArray > 0x10000000 && g_ActorCount > 0) {
                break;
            }
        }
        
        // Fallback to ActorCluster with dynamic scanning
        if (!g_ActorArray || g_ActorCount <= 0) {
            uintptr_t clusterOffsets[] = {0xE0, 0xF8, 0x100, 0xA8};
            for (uintptr_t offset : clusterOffsets) {
                uintptr_t actorCluster = ReadMemory<uintptr_t>(persistentLevel + offset);
                if (actorCluster && actorCluster > 0x10000000) {
                    g_ActorArray = ReadMemory<uintptr_t>(actorCluster + UOffsets::Cluster_Actors);
                    g_ActorCount = ReadMemory<int>(actorCluster + UOffsets::Cluster_Actors + 0x8);
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
        gameInstance = ReadMemory<uintptr_t>(g_GWorld + offset);
        if (gameInstance && gameInstance > 0x10000000) {
            break;
        }
    }
    
    if (gameInstance && gameInstance > 0x10000000) {
        // Parse LocalPlayers TArray correctly
        uintptr_t localPlayersArray = ReadMemory<uintptr_t>(gameInstance + UOffsets::GameInstance_LocalPlayers);
        if (localPlayersArray && localPlayersArray > 0x10000000) {
            // Get first element of TArray (index 0)
            uintptr_t lp = ReadMemory<uintptr_t>(localPlayersArray);
            if (lp && lp > 0x10000000) {
                // Scan for PlayerController offset
                uintptr_t controllerOffsets[] = {0x30, 0x38, 0x40};
                for (uintptr_t offset : controllerOffsets) {
                    g_Controller = ReadMemory<uintptr_t>(lp + offset);
                    if (g_Controller && g_Controller > 0x10000000) {
                        break;
                    }
                }
                
                if (g_Controller && g_Controller > 0x10000000) {
                    g_CameraManager = ReadMemory<uintptr_t>(g_Controller + UOffsets::Controller_CameraManager);
                    
                    // Get local pawn and position
                    g_LocalPawn = ReadMemory<uintptr_t>(g_Controller + UOffsets::Pawn_Controller);
                    if (g_LocalPawn && g_LocalPawn > 0x10000000) {
                        uintptr_t rootComp = ReadMemory<uintptr_t>(g_LocalPawn + UOffsets::Actor_RootComponent);
                        if (rootComp && rootComp > 0x10000000) {
                            g_LocalPlayerPos = ReadMemory<Vector3>(rootComp + UOffsets::RootComp_Location);
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
    
    // Mark as initialized if we have the critical components
    if (g_GWorld && g_ActorArray && g_ActorCount > 0 && g_Controller && g_CameraManager) {
        g_Initialized = true;
    }
}

// --- Safe W2S Functions using FMatrix16 with proper row-major handling ---
static bool GetViewProjectionMatrices(uintptr_t CameraManager, float* outViewMatrix, float* outProjMatrix) {
    if (!CameraManager) return false;
    uintptr_t cacheAddr = CameraManager + 0x4B0;
    FCameraCacheEntry cache = ReadMemory<FCameraCacheEntry>(cacheAddr);
    if (cache.Timestamp == 0) return false;
    uintptr_t povAddr = cacheAddr + offsetof(FCameraCacheEntry, POV);
    
    FMatrix16 viewMat = ReadMemory<FMatrix16>(povAddr + g_ViewMatOff);
    FMatrix16 projMat = ReadMemory<FMatrix16>(povAddr + g_ProjMatOff);
    
    // Transpose for Metal compatibility
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            outViewMatrix[i * 4 + j] = viewMat.M[j * 4 + i];
            outProjMatrix[i * 4 + j] = projMat.M[j * 4 + i];
        }
    }
    return true;
}

static bool ProjectWorldToScreen(Vector3 worldPos, Vector2& screenPos, float* viewMatrix, float* projMatrix, int screenWidth, int screenHeight) {
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

    // Re-initialize if not initialized or lost
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
                uintptr_t actor = ReadMemory<uintptr_t>(g_ActorArray + (i * sizeof(uintptr_t)));
                if (!actor || !IsValidVTable(actor)) continue;

                if (!IsPlayerActor(actor)) continue;
                if (actor == g_LocalPawn) continue;

                uintptr_t actorController = ReadMemory<uintptr_t>(actor + UOffsets::Pawn_Controller);
                if (actorController == g_Controller) continue;

                uintptr_t rootComp = ReadMemory<uintptr_t>(actor + UOffsets::Actor_RootComponent);
                if (!rootComp || !IsValidVTable(rootComp)) continue;

                Vector3 actorPos = ReadMemory<Vector3>(rootComp + UOffsets::RootComp_Location);
                if (actorPos.X == 0 && actorPos.Y == 0 && actorPos.Z == 0) continue;

                // Calculate relative distance
                float dx = actorPos.X - g_LocalPlayerPos.X;
                float dy = actorPos.Y - g_LocalPlayerPos.Y;
                float dz = actorPos.Z - g_LocalPlayerPos.Z;
                float relativeDistance = sqrtf(dx*dx + dy*dy + dz*dz) / 100.0f;

                if (relativeDistance > 200.0f || relativeDistance < 0.5f) continue;

                uintptr_t mesh = ReadMemory<uintptr_t>(actor + UOffsets::Character_Mesh);
                Vector3 headPos = actorPos;
                Vector3 feetPos = actorPos;
                
                if (mesh && mesh > 0x10000000) {
                    uintptr_t boneArray = ReadMemory<uintptr_t>(mesh + 0x4A0);
                    if (boneArray && boneArray > 0x10000000) {
                        uintptr_t headBone = ReadMemory<uintptr_t>(boneArray + 7 * 0x30);
                        if (headBone && headBone > 0x10000000) {
                            Vector3 bonePos = ReadMemory<Vector3>(headBone + 0x20);
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

                Vector2 screenHead, screenFeet, screenPos;

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
            char debugText[512];
            snprintf(debugText, sizeof(debugText),
                     "[Engine Diagnostics]\n"
                     "Base: 0x%lx\n"
                     "GEngine: 0x%lx\n"
                     "GWorld: 0x%lx\n"
                     "GNames: 0x%lx\n"
                     "Controller: 0x%lx\n"
                     "CamMgr: 0x%lx\n"
                     "ActorArr: 0x%lx\n"
                     "ActorCount: %d\n"
                     "LocalPawn: 0x%lx\n"
                     "ViewMat: 0x%X | ProjMat: 0x%X\n"
                     "LocalPos: %.1f, %.1f, %.1f\n"
                     "Initialized: %s",
                     g_BaseAddress, g_GEngine, g_GWorld, g_GNames,
                     g_Controller, g_CameraManager, g_ActorArray, 
                     g_ActorCount, g_LocalPawn,
                     g_ViewMatOff, g_ProjMatOff,
                     g_LocalPlayerPos.X, g_LocalPlayerPos.Y, g_LocalPlayerPos.Z,
                     g_Initialized ? "YES" : "NO");
            debugText[sizeof(debugText) - 1] = '\0';

            drawList->AddRectFilled(ImVec2(20, 40), ImVec2(340, 280), IM_COL32(10, 15, 25, 210), 6.0f);
            drawList->AddRect(ImVec2(20, 40), ImVec2(340, 280), IM_COL32(0, 255, 200, 180), 6.0f);
            drawList->AddText(ImVec2(28, 46), IM_COL32(255, 255, 255, 255), debugText);
        }

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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        if (window
