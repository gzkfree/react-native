/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RCTScrollViewComponentView.h"

#import <React/RCTAssert.h>
#import <React/RCTBridge+Private.h>
#import <React/RCTScrollEvent.h>

#import <react/components/scrollview/ScrollViewComponentDescriptor.h>
#import <react/components/scrollview/ScrollViewEventEmitter.h>
#import <react/components/scrollview/ScrollViewProps.h>
#import <react/components/scrollview/ScrollViewState.h>
#import <react/graphics/Geometry.h>

#import "RCTConversions.h"
#import "RCTEnhancedScrollView.h"

using namespace facebook::react;

static void RCTSendPaperScrollEvent_DEPRECATED(UIScrollView *scrollView, NSInteger tag)
{
  static uint16_t coalescingKey = 0;
  RCTScrollEvent *scrollEvent = [[RCTScrollEvent alloc] initWithEventName:@"onScroll"
                                                                 reactTag:[NSNumber numberWithInt:tag]
                                                  scrollViewContentOffset:scrollView.contentOffset
                                                   scrollViewContentInset:scrollView.contentInset
                                                    scrollViewContentSize:scrollView.contentSize
                                                          scrollViewFrame:scrollView.frame
                                                      scrollViewZoomScale:scrollView.zoomScale
                                                                 userData:nil
                                                            coalescingKey:coalescingKey];
  [[RCTBridge currentBridge].eventDispatcher sendEvent:scrollEvent];
}

@interface RCTScrollViewComponentView () <UIScrollViewDelegate>

@end

@implementation RCTScrollViewComponentView {
  ScrollViewShadowNode::ConcreteState::Shared _state;
  CGSize _contentSize;
  NSTimeInterval _lastScrollEventDispatchTime;
  NSTimeInterval _scrollEventThrottle;
}

+ (RCTScrollViewComponentView *_Nullable)findScrollViewComponentViewForView:(UIView *)view
{
  do {
    view = view.superview;
  } while (view != nil && ![view isKindOfClass:[RCTScrollViewComponentView class]]);
  return (RCTScrollViewComponentView *)view;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const ScrollViewProps>();
    _props = defaultProps;

    _scrollView = [[RCTEnhancedScrollView alloc] initWithFrame:self.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.delaysContentTouches = NO;
    [self addSubview:_scrollView];

    _containerView = [[UIView alloc] initWithFrame:CGRectZero];
    [_scrollView addSubview:_containerView];

    __weak __typeof(self) weakSelf = self;
    _scrollViewDelegateSplitter = [[RCTGenericDelegateSplitter alloc] initWithDelegateUpdateBlock:^(id delegate) {
      weakSelf.scrollView.delegate = delegate;
    }];

    [_scrollViewDelegateSplitter addDelegate:self];

    _scrollEventThrottle = INFINITY;
  }

  return self;
}

- (void)dealloc
{
  // This is not strictly necessary but that prevents a crash caused by a bug in UIKit.
  _scrollView.delegate = nil;
}

#pragma mark - RCTComponentViewProtocol

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<ScrollViewComponentDescriptor>();
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &oldScrollViewProps = *std::static_pointer_cast<const ScrollViewProps>(_props);
  const auto &newScrollViewProps = *std::static_pointer_cast<const ScrollViewProps>(props);

#define REMAP_PROP(reactName, localName, target)                      \
  if (oldScrollViewProps.reactName != newScrollViewProps.reactName) { \
    target.localName = newScrollViewProps.reactName;                  \
  }

#define REMAP_VIEW_PROP(reactName, localName) REMAP_PROP(reactName, localName, self)
#define MAP_VIEW_PROP(name) REMAP_VIEW_PROP(name, name)
#define REMAP_SCROLL_VIEW_PROP(reactName, localName) \
  REMAP_PROP(reactName, localName, ((RCTEnhancedScrollView *)_scrollView))
#define MAP_SCROLL_VIEW_PROP(name) REMAP_SCROLL_VIEW_PROP(name, name)

  // FIXME: Commented props are not supported yet.
  MAP_SCROLL_VIEW_PROP(alwaysBounceHorizontal);
  MAP_SCROLL_VIEW_PROP(alwaysBounceVertical);
  MAP_SCROLL_VIEW_PROP(bounces);
  MAP_SCROLL_VIEW_PROP(bouncesZoom);
  MAP_SCROLL_VIEW_PROP(canCancelContentTouches);
  MAP_SCROLL_VIEW_PROP(centerContent);
  // MAP_SCROLL_VIEW_PROP(automaticallyAdjustContentInsets);
  MAP_SCROLL_VIEW_PROP(decelerationRate);
  MAP_SCROLL_VIEW_PROP(directionalLockEnabled);
  // MAP_SCROLL_VIEW_PROP(indicatorStyle);
  // MAP_SCROLL_VIEW_PROP(keyboardDismissMode);
  MAP_SCROLL_VIEW_PROP(maximumZoomScale);
  MAP_SCROLL_VIEW_PROP(minimumZoomScale);
  MAP_SCROLL_VIEW_PROP(scrollEnabled);
  MAP_SCROLL_VIEW_PROP(pagingEnabled);
  MAP_SCROLL_VIEW_PROP(pinchGestureEnabled);
  MAP_SCROLL_VIEW_PROP(scrollsToTop);
  MAP_SCROLL_VIEW_PROP(showsHorizontalScrollIndicator);
  MAP_SCROLL_VIEW_PROP(showsVerticalScrollIndicator);

  if (oldScrollViewProps.scrollEventThrottle != newScrollViewProps.scrollEventThrottle) {
    // Zero means "send value only once per significant logical event".
    // Prop value is in milliseconds.
    // iOS implementation uses `NSTimeInterval` (in seconds).
    CGFloat throttleInSeconds = newScrollViewProps.scrollEventThrottle / 1000.0;
    CGFloat msPerFrame = 1.0 / 60.0;
    if (throttleInSeconds < 0) {
      _scrollEventThrottle = INFINITY;
    } else if (throttleInSeconds <= msPerFrame) {
      _scrollEventThrottle = 0;
    } else {
      _scrollEventThrottle = throttleInSeconds;
    }
  }

  MAP_SCROLL_VIEW_PROP(zoomScale);

  if (oldScrollViewProps.contentInset != newScrollViewProps.contentInset) {
    _scrollView.contentInset = RCTUIEdgeInsetsFromEdgeInsets(newScrollViewProps.contentInset);
  }

  // MAP_SCROLL_VIEW_PROP(scrollIndicatorInsets);
  // MAP_SCROLL_VIEW_PROP(snapToInterval);
  // MAP_SCROLL_VIEW_PROP(snapToAlignment);

  [super updateProps:props oldProps:oldProps];
}

- (void)updateState:(State::Shared const &)state oldState:(State::Shared const &)oldState
{
  assert(std::dynamic_pointer_cast<ScrollViewShadowNode::ConcreteState const>(state));
  _state = std::static_pointer_cast<ScrollViewShadowNode::ConcreteState const>(state);

  CGSize contentSize = RCTCGSizeFromSize(_state->getData().getContentSize());

  if (CGSizeEqualToSize(_contentSize, contentSize)) {
    return;
  }

  _contentSize = contentSize;
  _containerView.frame = CGRect{CGPointZero, contentSize};
  _scrollView.contentSize = contentSize;
}

- (void)mountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView index:(NSInteger)index
{
  [_containerView insertSubview:childComponentView atIndex:index];
}

- (void)unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView index:(NSInteger)index
{
  RCTAssert(childComponentView.superview == _containerView, @"Attempt to unmount improperly mounted component view.");
  [childComponentView removeFromSuperview];
}

- (ScrollViewMetrics)_scrollViewMetrics
{
  ScrollViewMetrics metrics;
  metrics.contentSize = RCTSizeFromCGSize(_scrollView.contentSize);
  metrics.contentOffset = RCTPointFromCGPoint(_scrollView.contentOffset);
  metrics.contentInset = RCTEdgeInsetsFromUIEdgeInsets(_scrollView.contentInset);
  metrics.containerSize = RCTSizeFromCGSize(_scrollView.bounds.size);
  metrics.zoomScale = _scrollView.zoomScale;
  return metrics;
}

- (void)_updateStateWithContentOffset
{
  auto contentOffset = RCTPointFromCGPoint(_scrollView.contentOffset);

  _state->updateState([contentOffset](ScrollViewShadowNode::ConcreteState::Data const &data) {
    auto newData = data;
    newData.contentOffset = contentOffset;
    return newData;
  });
}

- (void)prepareForRecycle
{
  _scrollView.contentOffset = CGPointZero;
  _state.reset();
  [super prepareForRecycle];
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
  if (!_eventEmitter) {
    return;
  }

  NSTimeInterval now = CACurrentMediaTime();
  if ((_lastScrollEventDispatchTime == 0) || (now - _lastScrollEventDispatchTime > _scrollEventThrottle)) {
    _lastScrollEventDispatchTime = now;
    std::static_pointer_cast<ScrollViewEventEmitter const>(_eventEmitter)->onScroll([self _scrollViewMetrics]);
    // Once Fabric implements proper NativeAnimationDriver, this should be removed.
    // This is just a workaround to allow animations based on onScroll event.
    RCTSendPaperScrollEvent_DEPRECATED(scrollView, self.tag);
  }
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView
{
  [self scrollViewDidScroll:scrollView];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
  [self _forceDispatchNextScrollEvent];

  if (!_eventEmitter) {
    return;
  }

  std::static_pointer_cast<ScrollViewEventEmitter const>(_eventEmitter)->onScrollBeginDrag([self _scrollViewMetrics]);
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset
{
  [self _forceDispatchNextScrollEvent];

  if (!_eventEmitter) {
    return;
  }

  std::static_pointer_cast<ScrollViewEventEmitter const>(_eventEmitter)->onScrollEndDrag([self _scrollViewMetrics]);
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)scrollView
{
  [self _forceDispatchNextScrollEvent];

  if (!_eventEmitter) {
    return;
  }

  std::static_pointer_cast<ScrollViewEventEmitter const>(_eventEmitter)
      ->onMomentumScrollBegin([self _scrollViewMetrics]);
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
  [self _forceDispatchNextScrollEvent];

  if (!_eventEmitter) {
    return;
  }

  std::static_pointer_cast<ScrollViewEventEmitter const>(_eventEmitter)->onMomentumScrollEnd([self _scrollViewMetrics]);
  [self _updateStateWithContentOffset];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView
{
  [self _forceDispatchNextScrollEvent];

  if (!_eventEmitter) {
    return;
  }

  std::static_pointer_cast<ScrollViewEventEmitter const>(_eventEmitter)->onMomentumScrollEnd([self _scrollViewMetrics]);
  [self _updateStateWithContentOffset];
}

- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(nullable UIView *)view
{
  [self _forceDispatchNextScrollEvent];

  if (!_eventEmitter) {
    return;
  }

  std::static_pointer_cast<ScrollViewEventEmitter const>(_eventEmitter)->onScrollBeginDrag([self _scrollViewMetrics]);
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(nullable UIView *)view atScale:(CGFloat)scale
{
  [self _forceDispatchNextScrollEvent];

  if (!_eventEmitter) {
    return;
  }

  std::static_pointer_cast<ScrollViewEventEmitter const>(_eventEmitter)->onScrollEndDrag([self _scrollViewMetrics]);
  [self _updateStateWithContentOffset];
}

#pragma mark - UIScrollViewDelegate

- (void)_forceDispatchNextScrollEvent
{
  _lastScrollEventDispatchTime = 0;
}

@end

@implementation RCTScrollViewComponentView (ScrollableProtocol)

- (CGSize)contentSize
{
  return _contentSize;
}

- (void)scrollToOffset:(CGPoint)offset
{
  [self _forceDispatchNextScrollEvent];
  [self scrollToOffset:offset animated:YES];
}

- (void)scrollToOffset:(CGPoint)offset animated:(BOOL)animated
{
  [self _forceDispatchNextScrollEvent];
  [self.scrollView setContentOffset:offset animated:animated];
}

- (void)scrollToEnd:(BOOL)animated
{
  // Not implemented.
}

- (void)zoomToRect:(CGRect)rect animated:(BOOL)animated
{
  // Not implemented.
}

- (void)addScrollListener:(NSObject<UIScrollViewDelegate> *)scrollListener
{
  [self.scrollViewDelegateSplitter addDelegate:scrollListener];
}

- (void)removeScrollListener:(NSObject<UIScrollViewDelegate> *)scrollListener
{
  [self.scrollViewDelegateSplitter removeDelegate:scrollListener];
}

@end
