import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/swipe_action.dart';
import '../providers/account_providers.dart';
import '../providers/swipe_action_providers.dart';
import '../providers/theme_providers.dart';
import 'account_form_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref, int accountId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this account?'),
        content: const Text('This deletes its cached mail and stored password from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(accountsProvider.notifier).remove(accountId);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    final themeMode = ref.watch(themeModeProvider);
    final swipeConfig = ref.watch(swipeActionConfigProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // Label above rather than beside the control: label + Spacer +
            // three icon/label segments needs ~496dp and overflows every
            // phone width.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Theme'),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    // Icons (both per-segment and the selected checkmark) cost
                    // roughly 40dp per segment, which is what pushed "System"
                    // off-screen.
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                      ButtonSegment(value: ThemeMode.system, label: Text('System')),
                    ],
                    selected: {themeMode},
                    // Fire-and-forget: setThemeMode reverts its own state if the
                    // write fails; surfacing that in the UI is out of scope here.
                    onSelectionChanged: (selection) =>
                        ref.read(themeModeProvider.notifier).setThemeMode(selection.first),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Swipe actions', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                _SwipeSlotRow(
                  label: 'Left, primary (full swipe)',
                  slotKey: 'swipe_left_primary_dropdown',
                  value: swipeConfig.leftPrimary,
                  onChanged: (action) =>
                      ref.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.leftPrimary, action),
                ),
                _SwipeSlotRow(
                  label: 'Left, secondary',
                  slotKey: 'swipe_left_secondary_dropdown',
                  value: swipeConfig.leftSecondary,
                  onChanged: (action) =>
                      ref.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.leftSecondary, action),
                ),
                _SwipeSlotRow(
                  label: 'Right, primary (full swipe)',
                  slotKey: 'swipe_right_primary_dropdown',
                  value: swipeConfig.rightPrimary,
                  onChanged: (action) =>
                      ref.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.rightPrimary, action),
                ),
                _SwipeSlotRow(
                  label: 'Right, secondary',
                  slotKey: 'swipe_right_secondary_dropdown',
                  value: swipeConfig.rightSecondary,
                  onChanged: (action) =>
                      ref.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.rightSecondary, action),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: accountsAsync.when(
              data: (accounts) => ListView.builder(
                itemCount: accounts.length,
                itemBuilder: (context, index) {
                  final account = accounts[index];
                  return ListTile(
                    title: Text(account.displayName),
                    subtitle: Text(account.email),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => AccountFormScreen(existing: account)),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _confirmRemove(context, ref, account.id!),
                        ),
                      ],
                    ),
                  );
                },
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('Failed to load accounts: $error')),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwipeSlotRow extends StatelessWidget {
  const _SwipeSlotRow({
    required this.label,
    required this.slotKey,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String slotKey;
  final SwipeAction value;
  final ValueChanged<SwipeAction> onChanged;

  @override
  Widget build(BuildContext context) {
    // Label above rather than beside the control: a Row puts the label in an
    // Expanded competing against a non-flexible DropdownButton, and the
    // button reserves width for its widest item ("Mark read/unread") before
    // the label gets any space at all. On a narrow phone that squeezes the
    // label to a few px wide, which wraps it character-by-character into
    // dozens of lines and blows out the row's height. See the Theme section
    // above for the same fix applied to the SegmentedButton overflow.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: DropdownButton<SwipeAction>(
              key: ValueKey(slotKey),
              isExpanded: true,
              isDense: true,
              value: value,
              items: [
                for (final action in SwipeAction.values)
                  DropdownMenuItem(value: action, child: Text(action.label)),
              ],
              onChanged: (action) {
                if (action != null) onChanged(action);
              },
            ),
          ),
        ],
      ),
    );
  }
}
