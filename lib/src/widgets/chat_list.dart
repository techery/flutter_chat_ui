import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:scrollable_positioned_list/src/positioned_list.dart';

import '../../flutter_chat_ui.dart';
import 'state/inherited_chat_theme.dart';
import 'state/inherited_user.dart';

/// Animated list that handles automatic animations and pagination.
class ChatList extends StatefulWidget {
  /// Creates a chat list widget.
  const ChatList({
    super.key,
    this.bottomWidget,
    required this.bubbleRtlAlignment,
    this.isLastPage,
    required this.itemBuilder,
    required this.items,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.onEndReached,
    this.onEndReachedThreshold,
    // required this.itemScrollController,
    // this.scrollOffsetController,
    required this.controller,
    this.positionedIndex = 0,
    this.positionedAlignment = 0,
    this.scrollPhysics,
    this.typingIndicatorOptions,
    required this.useTopSafeAreaInset,
  });

  /// A custom widget at the bottom of the list.
  final Widget? bottomWidget;

  /// Used to set alignment of typing indicator.
  /// See [BubbleRtlAlignment].
  final BubbleRtlAlignment bubbleRtlAlignment;

  /// Used for pagination (infinite scroll) together with [onEndReached].
  /// When true, indicates that there are no more pages to load and
  /// pagination will not be triggered.
  final bool? isLastPage;

  /// Item builder.
  final Widget Function(Object, int? index) itemBuilder;

  /// Items to build.
  final List<Object> items;

  /// Used for pagination (infinite scroll). Called when user scrolls
  /// to the very end of the list (minus [onEndReachedThreshold]).
  final Future<void> Function()? onEndReached;

  /// A representation of how a [ScrollView] should dismiss the on-screen keyboard.
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// Used for pagination (infinite scroll) together with [onEndReached]. Can be anything from 0 to 1, where 0 is immediate load of the next page as soon as scroll starts, and 1 is load of the next page only if scrolled to the very end of the list. Default value is 0.75, e.g. start loading next page when scrolled through about 3/4 of the available content.
  final double? onEndReachedThreshold;
  final int positionedIndex;
  final double positionedAlignment;

  /// Scroll controller for the main [CustomScrollView]. Also used to auto scroll
  /// to specific messages.

  final ScrollController controller;
  // final ItemScrollController itemScrollController;
  // final ScrollOffsetController? scrollOffsetController;

  /// Determines the physics of the scroll view.
  final ScrollPhysics? scrollPhysics;

  /// Used to build typing indicator according to options.
  /// See [TypingIndicatorOptions].
  final TypingIndicatorOptions? typingIndicatorOptions;

  /// Whether to use top safe area inset for the list.
  final bool useTopSafeAreaInset;

  @override
  State<ChatList> createState() => _ChatListState();
}

/// [ChatList] widget state.
class _ChatListState extends State<ChatList>
    with SingleTickerProviderStateMixin {
  late final Animation<double> _animation = CurvedAnimation(
    curve: Curves.easeOutQuad,
    parent: _controller,
  );
  late final AnimationController _controller = AnimationController(vsync: this);

  bool _indicatorOnScrollStatus = false;
  bool _isNextPageLoading = false;

  @override
  void initState() {
    super.initState();
    didUpdateWidget(widget);
  }

  Widget _newMessageBuilder(
    List<Object> items,
    int index,
    Animation<double>? animation,
    Widget Function(Object, int? index) itemBuilder,
  ) {
    try {
      final item = items[index];
      var child = itemBuilder(item, index);
      if (animation != null) {
        child = SizeTransition(
          key: _valueKeyForItem(item),
          axisAlignment: -1,
          sizeFactor: animation.drive(CurveTween(curve: Curves.easeOutQuad)),
          child: child,
        );
      }

      return child;
    } catch (e) {
      return const SizedBox();
    }
  }

  Widget _removedMessageBuilder(Object item, Animation<double> animation) =>
      SizeTransition(
        key: _valueKeyForItem(item),
        axisAlignment: -1,
        sizeFactor: animation.drive(CurveTween(curve: Curves.easeInQuad)),
        child: FadeTransition(
          opacity: animation.drive(CurveTween(curve: Curves.easeInQuad)),
          child: widget.itemBuilder(item, null),
        ),
      );

  // Hacky solution to reconsider.
  void _scrollToBottomIfNeeded(List<Object> oldList) {
    try {
      // Take index 1 because there is always a spacer on index 0.
      final oldItem = oldList[1];
      final item = widget.items[1];

      if (oldItem is Map<String, Object> && item is Map<String, Object>) {
        final oldMessage = oldItem['message']! as types.Message;
        final message = item['message']! as types.Message;

        // Compare items to fire only on newly added messages.
        if (oldMessage.id != message.id) {
          // Run only for sent message.
          if (message.author.id == InheritedUser.of(context).user.id) {
            // Delay to give some time for Flutter to calculate new
            // size after new message was added.
            Future.delayed(const Duration(milliseconds: 100), () {
              // if (widget.itemScrollController.isAttached) {
              //   widget.itemScrollController.scrollTo(
              //     index: 0,
              //     duration: const Duration(milliseconds: 200),
              //     curve: Curves.easeInQuad,
              //   );
              // }
              if (widget.controller.hasClients) {
                widget.controller.animateTo(
                  0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInQuad,
                );
              }
            });
          }
        }
      }
    } catch (e) {
      // Do nothing if there are no items.
    }
  }

  Key? _valueKeyForItem(Object item) =>
      _mapMessage(item, (message) => ValueKey(message.id));

  T? _mapMessage<T>(Object maybeMessage, T Function(types.Message) f) {
    if (maybeMessage is Map<String, Object>) {
      return f(maybeMessage['message'] as types.Message);
    }
    return null;
  }

  @override
  void didUpdateWidget(covariant ChatList oldWidget) {
    super.didUpdateWidget(oldWidget);

    _scrollToBottomIfNeeded(widget.items);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
            if (notification.metrics.pixels > 10.0 &&
                !_indicatorOnScrollStatus) {
              setState(() {
                _indicatorOnScrollStatus = !_indicatorOnScrollStatus;
              });
            } else if (notification.metrics.pixels == 0.0 &&
                _indicatorOnScrollStatus) {
              setState(() {
                _indicatorOnScrollStatus = !_indicatorOnScrollStatus;
              });
            }
          });

          if (widget.onEndReached == null || widget.isLastPage == true) {
            return false;
          }

          if (notification.metrics.pixels >=
              (notification.metrics.maxScrollExtent *
                  (widget.onEndReachedThreshold ?? 0.75))) {
            if (widget.items.isEmpty || _isNextPageLoading) return false;

            _controller.duration = Duration.zero;
            _controller.forward();

            setState(() {
              _isNextPageLoading = true;
            });

            widget.onEndReached!().whenComplete(() {
              if (mounted) {
                _controller.duration = const Duration(milliseconds: 300);
                _controller.reverse();

                setState(() {
                  _isNextPageLoading = false;
                });
              }
            });
          }

          return false;
        },
        child: Builder(
          builder: (context) {
            final typing = (widget
                        .typingIndicatorOptions!.typingUsers.isNotEmpty &&
                    !_indicatorOnScrollStatus)
                ? (widget.typingIndicatorOptions
                            ?.customTypingIndicatorBuilder !=
                        null
                    ? widget
                        .typingIndicatorOptions!.customTypingIndicatorBuilder!(
                        context: context,
                        bubbleAlignment: widget.bubbleRtlAlignment,
                        options: widget.typingIndicatorOptions!,
                        indicatorOnScrollStatus: _indicatorOnScrollStatus,
                      )
                    : widget.typingIndicatorOptions?.customTypingIndicator ??
                        TypingIndicator(
                          bubbleAlignment: widget.bubbleRtlAlignment,
                          options: widget.typingIndicatorOptions!,
                          showIndicator: (widget.typingIndicatorOptions!
                                  .typingUsers.isNotEmpty &&
                              !_indicatorOnScrollStatus),
                        ))
                : const SizedBox.shrink();
            final paginationIndicator = Padding(
              padding: EdgeInsets.only(
                top: 16 +
                    (widget.useTopSafeAreaInset
                        ? MediaQuery.of(context).padding.top
                        : 0),
              ),
              child: SizeTransition(
                axisAlignment: 1,
                sizeFactor: _animation,
                child: Center(
                  child: Container(
                    alignment: Alignment.center,
                    height: 32,
                    width: 32,
                    child: SizedBox(
                      height: 16,
                      width: 16,
                      child: _isNextPageLoading
                          ? CircularProgressIndicator(
                              backgroundColor: Colors.transparent,
                              strokeWidth: 1.5,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                InheritedChatTheme.of(context)
                                    .theme
                                    .primaryColor,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            );
            return Column(
              children: [
                paginationIndicator,
                Expanded(
                  child: PositionedList(
                    controller: widget.controller,
                    positionedIndex: widget.positionedIndex,
                    alignment: widget.positionedAlignment,
                    // TODO: let customize keyboardDismissBehaviour
                    // keyboardDismissBehavior: widget.keyboardDismissBehavior,
                    physics: widget.scrollPhysics,
                    reverse: true,
                    padding:
                        InheritedChatTheme.of(context).theme.chatContentMargin,
                    itemCount: widget.items.length,
                    itemBuilder: (context, index) => _newMessageBuilder(
                      widget.items,
                      index,
                      null,
                      widget.itemBuilder,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: typing,
                ),
                if (widget.bottomWidget != null) widget.bottomWidget!,
              ],
            );
          },
        ),
      );
}
