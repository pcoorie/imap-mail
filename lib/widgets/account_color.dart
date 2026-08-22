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

/// Same deterministic-palette approach as [accountColorFor], keyed by an
/// arbitrary string instead of an account id — used to give each message
/// sender (by email address) a stable avatar color. Shares [_palette] so a
/// sender's avatar and an account's dot draw from the same visual language.
///
/// Uses a hand-rolled hash rather than [String.hashCode]: this mapping is
/// meant to give a given sender the same color for as long as they email
/// you, across app upgrades — `hashCode`'s exact algorithm isn't a
/// documented cross-version guarantee, only that equal strings hash equally
/// within one run.
Color senderColorFor(String key) => _palette[_stableHash(key) % _palette.length];

int _stableHash(String input) {
  var hash = 0;
  for (final codeUnit in input.codeUnits) {
    hash = (hash * 31 + codeUnit) & 0x7fffffff;
  }
  return hash;
}
