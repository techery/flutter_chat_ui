import 'dart:async';

import 'package:diffutil_dart/diffutil.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import '../models/bubble_rtl_alignment.dart';
import 'state/inherited_chat_theme.dart';
import 'state/inherited_user.dart';
import 'typing_indicator.dart';

enum ChatListMode { conversation, assistant }

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
    required this.scrollController,
    this.scrollPhysics,
    this.typingIndicatorOptions,
    required this.useTopSafeAreaInset,
    this.mode = ChatListMode.conversation,
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

  /// Scroll controller for the main [CustomScrollView]. Also used to auto scroll
  /// to specific messages.
  final ScrollController scrollController;

  /// Determines the physics of the scroll view.
  final ScrollPhysics? scrollPhysics;

  /// Used to build typing indicator according to options.
  /// See [TypingIndicatorOptions].
  final TypingIndicatorOptions? typingIndicatorOptions;

  /// Whether to use top safe area inset for the list.
  final bool useTopSafeAreaInset;

  final ChatListMode mode;

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
  bool _didLoadView = false;
  final GlobalKey<SliverAnimatedListState> _listKey =
      GlobalKey<SliverAnimatedListState>();

  final GlobalKey _centerKey = GlobalKey();
  late List<Object> _oldData = List.from(widget.items);

  @override
  void initState() {
    super.initState();
    didUpdateWidget(widget);
  }

  void _calculateDiffs(List<Object> oldList, List<Object> newItems) async {
    final diffResult = calculateListDiff<Object>(
      oldList,
      newItems,
      equalityChecker: (item1, item2) {
        if (item1 is Map<String, Object> && item2 is Map<String, Object>) {
          final message1 = item1['message']! as types.Message;
          final message2 = item2['message']! as types.Message;

          return message1.id == message2.id;
        } else {
          return item1 == item2;
        }
      },
    );

    for (final update in diffResult.getUpdates(batch: false)) {
      update.when(
        insert: (pos, count) {
          _listKey.currentState?.insertItem(pos);
        },
        remove: (pos, count) {
          final item = oldList[pos];
          _listKey.currentState?.removeItem(
            pos,
            (_, animation) => _removedMessageBuilder(item, animation),
          );
        },
        change: (pos, payload) {},
        move: (from, to) {},
      );
    }

    _scrollToBottomIfNeeded(oldList);

    _oldData = List.from(newItems);
  }

  Widget _newMessageBuilder(
    BuildContext context,
    int index,
    Animation<double> animation,
  ) {
    try {
      final item = _oldData[index];
      var child = widget.itemBuilder(item, index);
      if (widget.mode == ChatListMode.assistant) {
        if (index == _oldData.length - 2) {
          if (item is Map<String, Object>) {
            final message = item['message']! as types.Message;
            final user = InheritedUser.of(context).user;

            if (message.author.id != user.id) {
              final sc = _listKey.currentContext?.findRenderObject();
              final minHeight = sc is RenderSliverList
                  ? sc.constraints.viewportMainAxisExtent / 3
                  : 0.0;
              child = ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: minHeight,
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: child,
                ),
              );
            }
          }
        }
        return KeyedSubtree(
          key: _valueKeyForItem(item),
          child: child,
        );
      }

      return SizeTransition(
        key: _valueKeyForItem(item),
        axisAlignment: -1,
        sizeFactor: animation.drive(CurveTween(curve: Curves.easeOutQuad)),
        child: child,
      );
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
  void _scrollToBottomIfNeeded(List<Object> oldList) async {
    try {
      if (widget.mode != ChatListMode.conversation) {
        return;
      }

      // Take index 1 because there is always a spacer on index 0.
      final oldItem = oldList[1];
      final item = widget.items[1];

      if (oldItem is! Map<String, Object> || item is! Map<String, Object>) {
        return;
      }

      final oldMessage = oldItem['message']! as types.Message;
      final message = item['message']! as types.Message;

      // Compare items to fire only on newly added messages.
      if (oldMessage.id == message.id) {
        return;
      }

      if (message.author.id != InheritedUser.of(context).user.id) {
        return;
      }

      await Future.delayed(const Duration(milliseconds: 100));
      if (!widget.scrollController.hasClients) {
        return;
      }

      await widget.scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInQuad,
      );
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

    _calculateDiffs(oldWidget.items, widget.items);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];
    final addWidget = switch (widget.mode) {
      ChatListMode.conversation => (Widget widget) => widgets.add(widget),
      ChatListMode.assistant => (Widget widget) => widgets.insert(0, widget)
    };
    if (widget.bottomWidget != null) {
      addWidget(SliverToBoxAdapter(child: widget.bottomWidget));
    }
    addWidget(
      SliverPadding(
        padding: const EdgeInsets.only(bottom: 4),
        sliver: SliverToBoxAdapter(
          child: (widget.typingIndicatorOptions!.typingUsers.isNotEmpty &&
                  !_indicatorOnScrollStatus)
              ? (widget.typingIndicatorOptions?.customTypingIndicatorBuilder !=
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
              : const SizedBox.shrink(),
        ),
      ),
    );
    addWidget(
      SliverPadding(
        key: _centerKey,
        padding: InheritedChatTheme.of(context).theme.chatContentMargin,
        sliver: SliverOpacity(
          opacity: _didLoadView ? 1 : 0,
          sliver: SliverAnimatedList(
            findChildIndexCallback: (Key key) {
              if (key is ValueKey<Object>) {
                final newIndex = widget.items.indexWhere(
                  (v) => _valueKeyForItem(v) == key,
                );
                if (newIndex != -1) {
                  return newIndex;
                }
              }
              return null;
            },
            initialItemCount: widget.items.length,
            key: _listKey,
            itemBuilder: (context, index, animation) =>
                _newMessageBuilder(context, index, animation),
          ),
        ),
      ),
    );
    addWidget(
      SliverPadding(
        padding: EdgeInsets.only(
          top: 16 +
              (widget.useTopSafeAreaInset
                  ? MediaQuery.of(context).padding.top
                  : 0),
        ),
        sliver: SliverToBoxAdapter(
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
                            InheritedChatTheme.of(context).theme.primaryColor,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Widget child = CustomScrollView(
      controller: widget.scrollController,
      keyboardDismissBehavior: widget.keyboardDismissBehavior,
      physics: widget.scrollPhysics,
      center: _centerKey,
      reverse: switch (widget.mode) {
        ChatListMode.conversation => true,
        ChatListMode.assistant => false
      },
      slivers: widgets,
    );
    child = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        final metrics = n.metrics;
        if (!_didLoadView && metrics.extentAfter == metrics.maxScrollExtent) {
          WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
            widget.scrollController.jumpTo(
              widget.scrollController.position.maxScrollExtent,
            );
            Future.delayed(const Duration(milliseconds: 100), () {
              setState(() {
                _didLoadView = true;
              });
            });
          });
        }
        return true;
      },
      child: child,
    );
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.pixels > 10.0 && !_indicatorOnScrollStatus) {
          setState(() {
            _indicatorOnScrollStatus = !_indicatorOnScrollStatus;
          });
        } else if (notification.metrics.pixels == 0.0 &&
            _indicatorOnScrollStatus) {
          setState(() {
            _indicatorOnScrollStatus = !_indicatorOnScrollStatus;
          });
        }

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
      child: child,
    );
  }
}
