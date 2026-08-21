import 'package:flutter/material.dart';

/// A small, fixed palette cycled by account id — same approach already used
/// for swipe-action colors elsewhere in this codebase (see
/// FolderViewScreen's `_colorFor`), rather than pulling in a new dependency
/// for something this simple. Deterministic per id so the same account
/// always gets the same dot color across app restarts and across the two
/// screens (unified inbox, message tile) that use it.
const _palette = [
  Colors.blue,
  Colors.teal,
  Colors.deepOrange,
  Colors.purple,
  Colors.green,
  Colors.pink,
  Colors.indigo,
  Colors.brown,
];

Color accountColorFor(int accountId) => _palette[accountId.abs() % _palette.length];
