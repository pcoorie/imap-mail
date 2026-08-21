import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/app_icon_badge.dart';

final appIconBadgeProvider = Provider<AppIconBadge>((ref) => PlatformAppIconBadge());
