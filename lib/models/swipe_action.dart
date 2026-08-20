import 'package:equatable/equatable.dart';

enum SwipeAction { archive, delete, flag, toggleRead, none }

extension SwipeActionLabel on SwipeAction {
  String get label => switch (this) {
        SwipeAction.archive => 'Archive',
        SwipeAction.delete => 'Delete',
        SwipeAction.flag => 'Flag/Unflag',
        SwipeAction.toggleRead => 'Mark read/unread',
        SwipeAction.none => 'None',
      };
}

enum SwipeSlot { leftPrimary, leftSecondary, rightPrimary, rightSecondary }

class SwipeActionConfig extends Equatable {
  const SwipeActionConfig({
    required this.leftPrimary,
    required this.leftSecondary,
    required this.rightPrimary,
    required this.rightSecondary,
  });

  final SwipeAction leftPrimary;
  final SwipeAction leftSecondary;
  final SwipeAction rightPrimary;
  final SwipeAction rightSecondary;

  static const defaults = SwipeActionConfig(
    leftPrimary: SwipeAction.archive,
    leftSecondary: SwipeAction.flag,
    rightPrimary: SwipeAction.delete,
    rightSecondary: SwipeAction.toggleRead,
  );

  SwipeActionConfig copyWith({
    SwipeAction? leftPrimary,
    SwipeAction? leftSecondary,
    SwipeAction? rightPrimary,
    SwipeAction? rightSecondary,
  }) {
    return SwipeActionConfig(
      leftPrimary: leftPrimary ?? this.leftPrimary,
      leftSecondary: leftSecondary ?? this.leftSecondary,
      rightPrimary: rightPrimary ?? this.rightPrimary,
      rightSecondary: rightSecondary ?? this.rightSecondary,
    );
  }

  SwipeActionConfig withSlot(SwipeSlot slot, SwipeAction action) {
    switch (slot) {
      case SwipeSlot.leftPrimary:
        return copyWith(leftPrimary: action);
      case SwipeSlot.leftSecondary:
        return copyWith(leftSecondary: action);
      case SwipeSlot.rightPrimary:
        return copyWith(rightPrimary: action);
      case SwipeSlot.rightSecondary:
        return copyWith(rightSecondary: action);
    }
  }

  SwipeAction forSlot(SwipeSlot slot) {
    switch (slot) {
      case SwipeSlot.leftPrimary:
        return leftPrimary;
      case SwipeSlot.leftSecondary:
        return leftSecondary;
      case SwipeSlot.rightPrimary:
        return rightPrimary;
      case SwipeSlot.rightSecondary:
        return rightSecondary;
    }
  }

  @override
  List<Object?> get props => [leftPrimary, leftSecondary, rightPrimary, rightSecondary];
}
