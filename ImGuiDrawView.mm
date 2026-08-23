#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>

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

// Define the exact Engine function pointer signature for World-to-Screen conversion
typedef bool (*_ProjectWorldLocationToScreen)(void* PlayerController, Vector3 WorldLocation, Vector2& ScreenLocation, bool bPlayerViewportRelative);
static _ProjectWorldLocationToScreen ProjectWorldLocationToScreen = nullptr;

// Bools for menu switches
static bool MenDeal = true;
static bool show_ESPBox = false;
static bool show_ESPLine = false;

@interface ImGuiDrawView () <MTKViewDelegate>
@property (nonatomic, strong) id <MTLDevice> device;
@property (nonatomic, strong) id <MTLCommandQueue> commandQueue;
@end

@implementation ImGuiDrawView

// Hooking function pointers
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
        ImGui::SetNextWindowSize(ImVec2(400, 300), ImGuiCond_FirstUseEver); 
        
        if (MenDeal == true) 
        {     
            ImGui::Begin("PUBG GL 4.5 ESP Layout", &MenDeal);
                ImGui::Text("Status: Overlay Active");
                ImGui::Separator();
                
                ImGui::Checkbox("Player 2D Box", &show_ESPBox);
                ImGui::Checkbox("Player Snaplines", &show_ESPLine);
                
                ImGui::Separator();
                ImGui::Text("FPS: %.1f", ImGui::GetIO().Framerate);
            ImGui::End();   
        }
        
        // ------------------ ESP Drawing Section ------------------
        ImDrawList* drawList = ImGui::GetForegroundDrawList();

        if ((show_ESPBox || show_ESPLine) && ProjectWorldLocationToScreen != nullptr) {
            uintptr_t baseAddr = (uintptr_t)_dyld_get_image_header(0);
            
            // 1. Get GWorld address
            uintptr_t gWorldAddress = *(uintptr_t*)(baseAddr + OFF_UWorld); 
            if (gWorldAddress) {
                // 2. Read LocalPlayer -> PlayerController pointers
                uintptr_t gameInstance = *(uintptr_t*)(gWorldAddress + 0x24);
                if (gameInstance) {
                    uintptr_t localPlayerArray = *(uintptr_t*)(gameInstance + 0x38);
                    if (localPlayerArray) {
                        uintptr_t localPlayer = *(uintptr_t*)(localPlayerArray + 0x0);
                        if (localPlayer) {
                            void* playerController = (void*)*(uintptr_t*)(localPlayer + 0x30);
                            
                            if (playerController) {
                                Vector3 enemyWorldPos = {5000.0f, -2500.0f, 120.0f};
                                Vector2 enemyScreenPos;
                                
                                // Execute native engine W2S translation
                                if (ProjectWorldLocationToScreen(playerController, enemyWorldPos, enemyScreenPos, false)) {
                                    if (show_ESPBox) {
                                        drawList->AddRect(
                                            ImVec2(enemyScreenPos.X - 30, enemyScreenPos.Y - 60), 
                                            ImVec2(enemyScreenPos.X + 30, enemyScreenPos.Y + 60), 
                                            IM_COL32(255, 0, 0, 255), 0.0f, 0, 1.8f
                                        );
                                    }
                                    
                                    if (show_ESPLine) {
                                        drawList->AddLine(
                                            ImVec2(view.bounds.size.width / 2.0f, 60.0f), 
                                            ImVec2(enemyScreenPos.X, enemyScreenPos.Y), 
                                            IM_COL32(255, 255, 0, 255), 1.2f
                                        );
                                    }
                                }
                            }
                        }
                    }
                }
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
// GLOBAL CONSTRUCTORS (Executes on dylib load)
// =========================================================

// 1. Initialize PUBG Offsets & W2S function pointer
__attribute__((constructor))
static void initializePUBGOffsets() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        uintptr_t baseAddress = (uintptr_t)_dyld_get_image_header(0);
        ProjectWorldLocationToScreen = (_ProjectWorldLocationToScreen)(baseAddress + OFF_W2S_Function);
    });
}

// 2. Force Load Menu Window for Non-Jailbreak / ESign / TrollStore
__attribute__((constructor))
static void forceLoadMenuInEsign() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
