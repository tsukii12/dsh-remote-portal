import 'package:intl/intl.dart';

/// Keep the count numeric until it is formatted for the displayed language.
String formatBotTextCount(int count, String locale) => NumberFormat.decimalPattern(locale).format(count);
