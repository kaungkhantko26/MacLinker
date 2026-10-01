// Declarations for CoreGraphics' private virtual-display classes (the interface used by DeskPad,
// BetterDisplay and similar apps). The classes live in CoreGraphics; only their declarations are here.
// Private API: it can change in any macOS release, so callers must handle failure.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) CGFloat refreshRate;
@property(readonly, nonatomic) NSUInteger width;
@property(readonly, nonatomic) NSUInteger height;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
- (instancetype)init;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int serialNum;
@property(retain, nonatomic) dispatch_queue_t queue;
@property(copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable, id _Nullable);
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings NS_SWIFT_NAME(applyVirtual(_:));
@end

NS_ASSUME_NONNULL_END
