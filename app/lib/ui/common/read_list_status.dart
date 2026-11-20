import '../../l10n/l10n.dart';
import '../../state/read_list_cache.dart';

/// A quiet label in an existing heading/subtitle; no progress animation and
/// no extra row that would push a retained list down during refresh.
String readListStatusText(ReadListStatus status) => switch (status) {
  ReadListStatus.current => '',
  ReadListStatus.updating => appL10n.readListUpdating,
  ReadListStatus.offline => appL10n.readListOffline,
  ReadListStatus.failed => appL10n.readListFailed,
};

String readListHeading(String heading, ReadListStatus status) =>
    status == ReadListStatus.current ? heading : '$heading · ${readListStatusText(status)}';
