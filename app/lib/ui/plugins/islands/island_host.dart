
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../plugins/seams/seat_models.dart';

final liveIslandBudgetProvider = Provider<IslandBudget>((ref) => const NoIslandBudget());
