//
//  PLCameraStreamingViewController.m
//  PLCameraStreamingKit
//
//  Created on 01/10/2015.
//  Copyright (c) Pili Engineering, Qiniu Inc. All rights reserved.
//

#import "PLViewController.h"
#import "Reachability.h"
#import <asl.h>
#import "PLMediaStreamingKit.h"

#include <sys/mman.h>
#include <sys/stat.h>
#import "FURenderer.h"
#import "authpack.h"

const char *stateNames[] = {
    "Unknow",
    "Connecting",
    "Connected",
    "Disconnecting",
    "Disconnected",
    "Error"
};

const char *networkStatus[] = {
    "Not Reachable",
    "Reachable via WiFi",
    "Reachable via CELL"
};

#define kReloadConfigurationEnable  0

// 假设在 videoFPS 低于预期 50% 的情况下就触发降低推流质量的操作，这里的 40% 是一个假定数值，你可以更改数值来尝试不同的策略
#define kMaxVideoFPSPercent 0.5

// 假设当 videoFPS 在 10s 内与设定的 fps 相差都小于 5% 时，就尝试调高编码质量
#define kMinVideoFPSPercent 0.05
#define kHigherQualityTimeInterval  10

#define kBrightnessAdjustRatio  1.03
#define kSaturationAdjustRatio  1.03

@interface PLViewController ()
<
PLCameraStreamingSessionDelegate,
PLStreamingSendingBufferDelegate
>

@property (nonatomic, strong) PLCameraStreamingSession  *session;
@property (nonatomic, strong) Reachability *internetReachability;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, strong) NSArray<PLVideoStreamingConfiguration *>   *videoStreamingConfigurations;
@property (nonatomic, strong) NSDate    *keyTime;
@property (nonatomic, strong) NSURL *streamURL;
@property (nonatomic, assign) BOOL audioEffectOn;

@end

@implementation PLViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 预先设定几组编码质量，之后可以切换
    CGSize videoSize = CGSizeMake(480 , 640);
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    if (orientation <= AVCaptureVideoOrientationLandscapeLeft) {
        if (orientation > AVCaptureVideoOrientationPortraitUpsideDown) {
            videoSize = CGSizeMake(640 , 480);
        }
    }
    self.videoStreamingConfigurations = @[
                                 [[PLVideoStreamingConfiguration alloc] initWithVideoSize:videoSize expectedSourceVideoFrameRate:30 videoMaxKeyframeInterval:45 averageVideoBitRate:400 * 1000 videoProfileLevel:AVVideoProfileLevelH264Baseline31],
                                 [[PLVideoStreamingConfiguration alloc] initWithVideoSize:CGSizeMake(800 , 480) expectedSourceVideoFrameRate:30 videoMaxKeyframeInterval:72 averageVideoBitRate:600 * 1000 videoProfileLevel:AVVideoProfileLevelH264Baseline31],
                                 [[PLVideoStreamingConfiguration alloc] initWithVideoSize:videoSize expectedSourceVideoFrameRate:30 videoMaxKeyframeInterval:90 averageVideoBitRate:800 * 1000 videoProfileLevel:AVVideoProfileLevelH264Baseline31],
                                 ];
    self.sessionQueue = dispatch_queue_create("pili.queue.streaming", DISPATCH_QUEUE_SERIAL);
    
    // 网络状态监控
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:kReachabilityChangedNotification object:nil];
    self.internetReachability = [Reachability reachabilityForInternetConnection];
    [self.internetReachability startNotifier];
    
    void (^permissionBlock)(void) = ^{
        dispatch_async(self.sessionQueue, ^{
            PLVideoCaptureConfiguration *videoCaptureConfiguration = [PLVideoCaptureConfiguration defaultConfiguration];
            videoCaptureConfiguration.sessionPreset = AVCaptureSessionPresetHigh;
            
            PLAudioCaptureConfiguration *audioCaptureConfiguration = [PLAudioCaptureConfiguration defaultConfiguration];
            // 视频编码配置
            PLVideoStreamingConfiguration *videoStreamingConfiguration = [self.videoStreamingConfigurations lastObject];
            // 音频编码配置
            PLAudioStreamingConfiguration *audioStreamingConfiguration = [PLAudioStreamingConfiguration defaultConfiguration];
            AVCaptureVideoOrientation orientation = (AVCaptureVideoOrientation)(([[UIDevice currentDevice] orientation] <= UIDeviceOrientationLandscapeRight && [[UIDevice currentDevice] orientation] != UIDeviceOrientationUnknown) ? [[UIDevice currentDevice] orientation]: UIDeviceOrientationPortrait);
            // 推流 session
            self.session = [[PLCameraStreamingSession alloc] initWithVideoCaptureConfiguration:videoCaptureConfiguration audioCaptureConfiguration:audioCaptureConfiguration videoStreamingConfiguration:videoStreamingConfiguration audioStreamingConfiguration:audioStreamingConfiguration stream:nil videoOrientation:orientation];
            self.session.delegate = self;
            self.session.bufferDelegate = self;
            //UIImage *waterMark = [UIImage imageNamed:@"qiniu.png"];
            //[self.session setWaterMarkWithImage:waterMark position:CGPointMake(100, 300)];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIView *previewView = self.session.previewView;
                previewView.autoresizingMask = UIViewAutoresizingFlexibleHeight| UIViewAutoresizingFlexibleWidth;
                [self.view insertSubview:previewView atIndex:0];
                self.zoomSlider.minimumValue = 0.0;
                self.zoomSlider.maximumValue = 1.0;
                self.zoomSlider.value = 1.0;                
                //NSString *log = [NSString stringWithFormat:@"Zoom Range: [1..%.0f]", self.session.videoActiveFormat.videoMaxZoomFactor];
                //self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
            });
        });
    };
    
    void (^noAccessBlock)(void) = ^{
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"No Access", nil)
                                                            message:NSLocalizedString(@"!", nil)
                                                           delegate:nil
                                                  cancelButtonTitle:NSLocalizedString(@"Cancel", nil)
                                                  otherButtonTitles:nil];
        [alertView show];
    };
    
    switch ([PLCameraStreamingSession cameraAuthorizationStatus]) {
        case PLAuthorizationStatusAuthorized:
            permissionBlock();
            break;
        case PLAuthorizationStatusNotDetermined: {
            [PLCameraStreamingSession requestCameraAccessWithCompletionHandler:^(BOOL granted) {
                granted ? permissionBlock() : noAccessBlock();
            }];
        }
            break;
        default:
            noAccessBlock();
            break;
    }
    
    self.itemHintText=[[UILabel alloc]initWithFrame:CGRectMake(100,self.view.frame.size.height/2, self.view.frame.size.width-200, 40)];
    [self.itemHintText setText:@"i am a label "];
    self.itemHintText.font=[UIFont systemFontOfSize:20];
    self.itemHintText.textAlignment=NSTextAlignmentCenter;
    [self.view addSubview:self.itemHintText];    
    [self.itemHintText setBackgroundColor: [UIColor clearColor]];
    self.itemHintText.textAlignment = 1;
    
    [self.torchButton setTitle: @"Next item" forState: UIControlStateNormal];
    [self.actionButton setTitle: @"Filter: nature" forState: UIControlStateNormal];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kReachabilityChangedNotification object:nil];
    
    dispatch_sync(self.sessionQueue, ^{
        [self.session destroy];
    });
    self.session = nil;
    self.sessionQueue = nil;
}

#pragma mark - Notification Handler

- (void)reachabilityChanged:(NSNotification *)notif{
    Reachability *curReach = [notif object];
    NSParameterAssert([curReach isKindOfClass:[Reachability class]]);
    NetworkStatus status = [curReach currentReachabilityStatus];
    
    if (NotReachable == status) {
        // 对断网情况做处理
        [self stopSession];
    }
    
    NSString *log = [NSString stringWithFormat:@"Networkt Status: %s", networkStatus[status]];
    NSLog(@"%@", log);
    self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
}

#pragma mark - <PLStreamingSendingBufferDelegate>

- (void)streamingSessionSendingBufferDidFull:(id)session {
    NSString *log = @"Buffer is full";
    NSLog(@"%@", log);
    self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
}

- (void)streamingSession:(id)session sendingBufferDidDropItems:(NSArray *)items {
    NSString *log = @"Frame dropped";
    NSLog(@"%@", log);
    self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
}

#pragma mark - <PLCameraStreamingSessionDelegate>

- (void)cameraStreamingSession:(PLCameraStreamingSession *)session streamStateDidChange:(PLStreamState)state {
    NSString *log = [NSString stringWithFormat:@"Stream State: %s", stateNames[state]];
    NSLog(@"%@", log);
    self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
    
    // 除 PLStreamStateError 外的其余状态会回调在这个方法
    // 这个回调会确保在主线程，所以可以直接对 UI 做操作
    if (PLStreamStateConnected == state) {
        [self.actionButton setTitle:NSLocalizedString(@"Stop", nil) forState:UIControlStateNormal];
    } else if (PLStreamStateDisconnected == state) {
        [self.actionButton setTitle:NSLocalizedString(@"Start", nil) forState:UIControlStateNormal];
    }
}

- (void)cameraStreamingSession:(PLCameraStreamingSession *)session didDisconnectWithError:(NSError *)error {
    NSString *log = [NSString stringWithFormat:@"Stream State: Error. %@", error];
    NSLog(@"%@", log);
    self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
    // PLStreamStateError 都会回调在这个方法
    // 尝试重连，注意这里需要你自己来处理重连尝试的次数以及重连的时间间隔
    [self.actionButton setTitle:NSLocalizedString(@"Reconnecting", nil) forState:UIControlStateNormal];
    [self startSession];
}

//------------faceunity-------------//
// Global variables for Faceunity
//  Global flags
static EAGLContext* g_gl_context = nil;   // GL context to draw item
static int g_faceplugin_inited = 0;
static int g_frame_id = 0;
static int g_need_reload_item = 1;
static int g_selected_item = 0;
static int g_selected_filter = 0;
static int g_is_tracking = -1;
static volatile int g_reset_camera = 0;
//  Predefined items and maintenance
static NSString* g_item_names[] = {@"tiara.bundle", @"item0208.bundle", @"YellowEar.bundle", @"PrincessCrown.bundle", @"Mood.bundle" , @"Deer.bundle" , @"BeagleDog.bundle", @"item0501.bundle", @"ColorCrown.bundle", @"item0210.bundle",  @"HappyRabbi.bundle", @"item0204.bundle", @"hartshorn.bundle"};
static char* g_filter_names[] = {"nature", "delta", "electric", "slowlived", "tokyo", "warm"};
static NSString* g_item_hints[] = {@"", @"", @"", @"", @"嘴角向上以及嘴角向下", @"", @"", @"", @"", @"", @"", @"做咀嚼动作", @""}; // @"张开嘴巴"
static const int g_item_num = sizeof(g_item_names) / sizeof(NSString*);
static const int g_filter_num = sizeof(g_filter_names) / sizeof(char*);
static void* g_mmap_pointers[g_item_num + 2] = {NULL};
static intptr_t g_mmap_sizes[g_item_num + 2] = {0};
static int g_items[3] = {0, 0, 0};
static float g_beauty_level = 1.0;
// Item loading assistant functions
static size_t osal_GetFileSize(int fd){
	struct stat sb;
	sb.st_size = 0;
	fstat(fd, &sb);
	return (size_t)sb.st_size;
}
static void* mmap_bundle(NSString* fn_bundle,intptr_t* psize){
    // Load item from predefined item bundle
    NSString *str = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:fn_bundle];
    const char *fn = [str UTF8String];
    int fd = open(fn,O_RDONLY);
    void* g_res_zip = NULL;
    size_t g_res_size = 0;
    if(fd == -1){
        NSLog(@"faceunity: failed to open bundle");
        g_res_size = 0;
    }else{
        g_res_size = osal_GetFileSize(fd);
        g_res_zip = mmap(NULL, g_res_size, PROT_READ, MAP_SHARED, fd, 0);
        NSLog(@"faceunity: %@ mapped %08x %ld\n", str, (unsigned int)g_res_zip, g_res_size);
    }
    *psize = g_res_size;
    return g_res_zip;
}

static void* mmap_sharing_file(NSString* fn_file,intptr_t* psize){
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *txtPath = [documentsDirectory stringByAppendingPathComponent:fn_file];
    NSLog(@"txtPaht = %@", txtPath);
    const char *fn = [txtPath UTF8String];
    int fd=open(fn,O_RDONLY);
    void* g_res_zip=NULL;
    size_t g_res_size=0;
    if(fd==-1){
        g_res_size=0;
    }else{
        g_res_size=osal_GetFileSize(fd);
        g_res_zip=mmap(NULL,g_res_size, PROT_READ, MAP_SHARED,fd,0);
        NSLog(@"faceunity: %@ mapped %08x %ld\n", txtPath, (unsigned int)g_res_zip,g_res_size);
    }
    *psize=g_res_size;
    return g_res_zip;
}


- (void)fuReloadItem{
    if(g_items[0]){
        NSLog(@"faceunity: destroy item");
        fuDestroyItem(g_items[0]);
    }
    // load selected
    intptr_t size = g_mmap_sizes[g_selected_item];
    void* data = g_mmap_pointers[g_selected_item];
    if(!data){
    	// mmap doesn't consume much hard resources, it should be safe to keep all the pointers around
        // read file sharing item for artist
        NSString *file_name = [NSString stringWithFormat:@"_item_%d.bundle", g_selected_item];
        data = mmap_sharing_file(file_name, &size);
        if (data == NULL){
            data = mmap_bundle(g_item_names[g_selected_item], &size);
        }
        //data = mmap_bundle(g_item_names[g_selected_item], &size);
    	g_mmap_pointers[g_selected_item] = data;
    	g_mmap_sizes[g_selected_item] = size;
    }
    // key item creation function call
    g_items[0] = fuCreateItemFromPackage(data, (int)size);
    NSLog(@"faceunity: load item #%d, handle=%d", g_selected_item, g_items[0]);
}

- (void)fuLoadBeautify{
    // load beautify item
    intptr_t size = g_mmap_sizes[g_item_num];
    void* data = g_mmap_pointers[g_item_num];
    if(!data){
        // mmap doesn't consume much hard resources, it should be safe to keep all the pointers around
        data = mmap_bundle(@"face_beautification.bundle", &size);
        g_mmap_pointers[g_item_num] = data;
        g_mmap_sizes[g_item_num] = size;
    }
    // key item creation function call
    g_items[1] = fuCreateItemFromPackage(data, (int)size);
    NSLog(@"faceunity: load beautify item, handle=%d", g_items[1]);
}

- (void)fuLoadHeart{
    // load beautify item
    intptr_t size = g_mmap_sizes[g_item_num + 1];
    void* data = g_mmap_pointers[g_item_num + 1];
    if(!data){
        // mmap doesn't consume much hard resources, it should be safe to keep all the pointers around
        data = mmap_bundle(@"heart.bundle", &size);
        g_mmap_pointers[g_item_num + 1] = data;
        g_mmap_sizes[g_item_num + 1] = size;
    }
    // key item creation function call
    g_items[2] = fuCreateItemFromPackage(data, (int)size);
    NSLog(@"faceunity: load heart item, handle=%d", g_items[2]);
}

// Item draw interface with Qiniu pipeline
- (CVPixelBufferRef)cameraStreamingSession:(PLCameraStreamingSession *)session cameraSourceDidGetPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    // Initialize environment for faceunity
    //  Init GL context
    if(!g_gl_context){
        g_gl_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    }
    if(!g_gl_context || ![EAGLContext setCurrentContext:g_gl_context]){
        NSLog(@"faceunity: failed to create / set a GLES2 context");
        return pixelBuffer;
    }
    //  Init face recgonition and tracking
    if(!g_faceplugin_inited){
        g_faceplugin_inited = 1;
        intptr_t size = 0;
    	void* v3data = mmap_bundle(@"v3.bundle", &size);

        [[FURenderer shareRenderer] setupWithData:v3data ardata:NULL authPackage:g_auth_package authSize:sizeof(g_auth_package)];
    }
    //  Reset if camera change
    if (g_reset_camera){
        fuOnCameraChange();
        g_reset_camera = 0;
    }
    //  Load item if needed
    if (g_need_reload_item){
        [self fuReloadItem];
        g_need_reload_item = 0;
    }
    //  Load beautify item
    
    if (g_items[1] == 0){
        [self fuLoadBeautify];
    }
    
    if (g_items[2] == 0){
        [self fuLoadHeart];
    }
    
    //  Update face tracking status
    int tracking = fuIsTracking();
    if (tracking != g_is_tracking){
        g_is_tracking = tracking;
        if (tracking == 0){            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.itemHintText setText:@"没有检测到面部"];
            });
        }else{
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.itemHintText setText: g_item_hints[g_selected_item]];
            });
        }
    }
    //  Set item parameters
    //设置美颜效果（滤镜、磨皮、美白、瘦脸、大眼....）
    fuItemSetParamd(g_items[1], "cheek_thinning", 1); //瘦脸
    fuItemSetParamd(g_items[1], "eye_enlarging", 2); //大眼
    fuItemSetParamd(g_items[1], "color_level", 0.5); //美白
    fuItemSetParams(g_items[1], "filter_name", g_filter_names[g_selected_filter]); //滤镜
    fuItemSetParamd(g_items[1], "blur_level", g_beauty_level * 6); //磨皮
    
    ////////////////////////////
    
    pixelBuffer = [[FURenderer shareRenderer] renderPixelBuffer:pixelBuffer withFrameId:g_frame_id items:g_items itemCount:3];
    
    g_frame_id++;
    
    return pixelBuffer;
}
//------------faceunity-------------//

- (void)cameraStreamingSession:(PLCameraStreamingSession *)session streamStatusDidUpdate:(PLStreamStatus *)status {
    NSString *log = [NSString stringWithFormat:@"%@", status];
    NSLog(@"%@", log);
    self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
    
#if kReloadConfigurationEnable
    NSDate *now = [NSDate date];
    if (!self.keyTime) {
        self.keyTime = now;
    }
    
    double expectedVideoFPS = (double)self.session.videoConfiguration.videoFrameRate;
    double realtimeVideoFPS = status.videoFPS;
    if (realtimeVideoFPS < expectedVideoFPS * (1 - kMaxVideoFPSPercent)) {
        // 当得到的 status 中 video fps 比设定的 fps 的 50% 还小时，触发降低推流质量的操作
        self.keyTime = now;
        
        [self lowerQuality];
    } else if (realtimeVideoFPS >= expectedVideoFPS * (1 - kMinVideoFPSPercent)) {
        if (-[self.keyTime timeIntervalSinceNow] > kHigherQualityTimeInterval) {
            self.keyTime = now;
            
            [self higherQuality];
        }
    }
#endif  // #if kReloadConfigurationEnable
}

#pragma mark -

- (void)higherQuality {
    NSUInteger idx = [self.videoStreamingConfigurations indexOfObject:self.session.videoStreamingConfiguration];
    NSAssert(idx != NSNotFound, @"Oops");
    
    if (idx >= self.videoStreamingConfigurations.count - 1) {
        return;
    }
    PLVideoStreamingConfiguration *newStreamingConfiguration = self.videoStreamingConfigurations[idx + 1];
    [self.session reloadVideoStreamingConfiguration:newStreamingConfiguration videoCaptureConfiguration:nil];
}

- (void)lowerQuality {
    NSUInteger idx = [self.videoStreamingConfigurations indexOfObject:self.session.videoStreamingConfiguration];
    NSAssert(idx != NSNotFound, @"Oops");
    
    if (0 == idx) {
        return;
    }
    PLVideoStreamingConfiguration *newStreamingConfiguration = self.videoStreamingConfigurations[idx - 1];
    [self.session reloadVideoStreamingConfiguration:newStreamingConfiguration videoCaptureConfiguration:nil];
}

#pragma mark - Operation

- (void)stopSession {
    dispatch_async(self.sessionQueue, ^{
        self.keyTime = nil;
        [self.session stop];
    });
}

- (void)startSession {

    self.keyTime = nil;
    self.actionButton.enabled = NO;
    dispatch_async(self.sessionQueue, ^{
        // 在开始直播之前请确保已经从业务服务器获取到了 streamURL，streamURL 的格式为 "rtmp://"
        self.streamURL = [NSURL URLWithString:@"rtmp://pili-publish.faceunity.com/faceunity-test/demoTest?e=1473064281&token=WogO-mC_epxSxhzSZ8SSZqTgg6APdIgzZyGrJYXS:cFwtRTiYAfC6bmnXEhe76Jf7pwE="];
        [self.session startWithPushURL:self.streamURL feedback:^(PLStreamStartStateFeedback feedback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.actionButton.enabled = YES;
            });
        }];
    });
}

#pragma mark - Action

- (IBAction)zoomSliderValueDidChange:(id)sender {
    //self.session.videoZoomFactor = self.zoomSlider.value;
    NSLog(@"slider change %f",self.zoomSlider.value);
    g_beauty_level = self.zoomSlider.value;
}

- (IBAction)actionButtonPressed:(id)sender {
    /*
    // start streaming is commented out
    if (PLStreamStateConnected == self.session.streamState) {
        [self stopSession];
    } else {
        [self startSession];
    }
    */
    g_selected_filter++;
    if (g_selected_filter >= g_filter_num) g_selected_filter = 0;
    NSString* btnName = [NSString stringWithFormat:@"Filter: %s", g_filter_names[g_selected_filter]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.actionButton setTitle: btnName forState: UIControlStateNormal];
    });
}

- (IBAction)toggleCameraButtonPressed:(id)sender {
    dispatch_async(self.sessionQueue, ^{
        [self.session toggleCamera];
        g_reset_camera = 1;
    });
}

- (IBAction)torchButtonPressed:(id)sender {
    dispatch_async(self.sessionQueue, ^{
        g_selected_item++;
        if (g_selected_item >= g_item_num) g_selected_item = 0;
        g_need_reload_item = 1;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.itemHintText.text = g_item_hints[g_selected_item];
        });
    });
}

- (IBAction)playbackButtonPressed:(id)sender
{
    self.session.playback = !self.session.playback;
}

- (IBAction)audioEffectButtonPressed:(id)sender
{
    NSArray<PLAudioEffectConfiguration *> *effects;
    
    if (self.audioEffectOn) {
        effects = @[];
    } else {
        PLAudioEffectConfiguration *configuration = [PLAudioEffectModeConfiguration reverbHeightLevelModeConfiguration];
        effects = @[configuration];
    }
    self.audioEffectOn = !self.audioEffectOn;
    self.session.audioEffectConfigurations = effects;
}


// item switch button
- (IBAction)nextItemButtonPressed:(id)sender {
    dispatch_async(self.sessionQueue, ^{
        g_selected_item++;
        if (g_selected_item >= g_item_num) g_selected_item = 0;
        g_need_reload_item = 1;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.itemHintText setText: g_item_hints[g_selected_item]];
        });
    });
}

@end
