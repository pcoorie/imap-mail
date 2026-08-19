import 'package:flutter/material.dart';

class SyncErrorBanner extends StatelessWidget {
  const SyncErrorBanner({super.key, required this.message, required this.onRetry, this.onEditAccount});

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onEditAccount;

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      content: Text("Can't sync: $message"),
      actions: [
        TextButton(onPressed: onRetry, child: const Text('Retry')),
        if (onEditAccount != null)
          TextButton(onPressed: onEditAccount, child: const Text('Edit account')),
      ],
    );
  }
}
