// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Local changes: rewritten for dsh_client / Riverpod state; keeps the
// floating-composer height sync and the "content scrolls under glass" layout.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dev/remote_benchmark.dart';
import '../../l10n/l10n.dart';
import '../../state/chat_request_text.dart';
import '../../state/agents_state.dart' show subagentParentProvider;
import '../../state/attachments.dart';
import '../../state/chat_error_text.dart';
import '../../state/chat_state.dart';
import '../../state/commands_state.dart';
import '../../state/compose_inbox.dart';
import '../../state/composer_insert.dart';
import '../../state/composer_quote.dart';
import '../../state/connection_state.dart';
import '../../state/draft_store.dart';
import '../../state/drawer_view_state.dart';
import '../../state/features_state.dart' show agentPresetsProvider, permissionStateProvider;
import '../../state/hosts_state.dart' show HostRef, activeHostProvider;
import '../../state/mention_state.dart';
import '../../state/models_state.dart';
import '../../state/new_chat_modes.dart';
import '../../state/session_search.dart' show folderLabel;
import '../../state/session_modes.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/usage_state.dart';
import '../../state/workspaces_state.dart' show selectedWorkspaceProvider, workspaceTitle;
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/fluid_bits.dart';
import '../common/ui_trace.dart';
import '../common/sheet_title_bar.dart';
import '../common/smooth_size.dart';
import '../common/status_dot.dart';
import '../features/session_export_page.dart';
import '../session/session_detail_page.dart';
import '../settings/settings_widgets.dart' show SettingsTile;
import '../shell/adaptive/adaptive_layout.dart' show WindowClass;
import '../shell/drawer/folder_sheets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../wallpaper/wallpaper_backdrop.dart';
import '../workspace/workspace_switcher.dart' show showWorkspaceSheet;
import '../workspace/workspaces_page.dart';
import 'chat_header.dart';
import 'chat_list.dart';
import 'composer.dart';
import 'composer_toast.dart';
import 'dock/chat_dock.dart';
import 'dock/dock_stack.dart';
import 'empty_state.dart';
import 'new_chat_options.dart';
import 'media/media_format.dart' show chatTitleShown;
import 'mention/mention_controller.dart';
import 'mention/mention_picker.dart';
import 'mention/mention_text_controller.dart';
import 'model_sheet.dart';
import 'slash_palette.dart';
import 'trajectory_sheet.dart';
import 'usage_sheet.dart';
import 'widgets/activity_strip.dart';
import 'widgets/attachments.dart';
import 'widgets/notice_row.dart';
import 'widgets/permission_pill.dart';
import 'widgets/plus_panel.dart';
import 'widgets/quote_chip.dart';
import 'widgets/read_only_bar.dart';
import 'widgets/unknown_results_banner.dart';

/// 聊天页:玻璃顶栏 + 消息列表 + 玻璃输入条。
///
/// 读 [currentSessionProvider];为 null 时是"新对话"空状态,第一次发送时
/// 才建会话(create → select → send)。
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, this.onOpenDrawer, this.backdrop = true});

  /// Opens the sessions drawer (the shell owns the drawer).
  final VoidCallback? onOpenDrawer;

  /// False when the shell already paints the page backdrop.
  final bool backdrop;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> with WidgetsBindingObserver {
  final _toTop = defaultTargetPlatform == TargetPlatform.iOS ? StatusBarTop() : null;

  void Function()? _endInteraction;
  bool _routeCurrent = true;
  ModalRoute<Object?>? _interactionRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardInset ??= View.of(context).viewInsets.bottom;
    _interactionRoute = ModalRoute.of<Object?>(context);
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (current == _routeCurrent) return;
    _routeCurrent = current;
    if (current) {
      _scheduleInteraction();
    } else {
      _endInteraction?.call();
      _endInteraction = null;
    }
  }

  void _scheduleInteraction() {
    _endInteraction?.call();
    _endInteraction = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_routeCurrent) return;
      _endInteraction?.call();
      final sessionId = ref.read(currentSessionProvider);
      if (sessionId == null) return;
      _endInteraction = ref.read(chatProvider(sessionId).notifier).beginInteraction(() {
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        return mounted &&
            (_interactionRoute?.isCurrent ?? true) &&
            ref.read(currentSessionProvider) == sessionId &&
            (lifecycle == null || lifecycle == AppLifecycleState.resumed);
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scheduleInteraction();
  }

  @override
  void didChangeMetrics() {
    final inset = View.of(context).viewInsets.bottom;
    final hidden = (_keyboardInset ?? 0) > 0 && inset == 0;
    _keyboardInset = inset;
    if (hidden && (_interactionRoute?.isCurrent ?? true)) _dismissSlashPalette();
  }

  final _input = MentionTextController();

  /// The `@` picker over [_input].
  late final _mentions = MentionPickerController(
    input: _input,
    source: () => ref.read(mentionSourceProvider),
    sessionId: () => ref.read(currentSessionProvider),
    localSessions: () => ref.read(sessionsProvider.future),
    recents: ref.read(mentionRecentsProvider),
  );

  final _focus = FocusNode();

  // Keep this slash draft closed until it leaves slash input or starts again at "/".
  String? _dismissedSlashText;
  double? _keyboardInset;
  final _composerGroup = Object();

  void _resetSlashDismissal() {
    final dismissed = _dismissedSlashText;
    if (dismissed == null) return;
    final text = _input.text;
    final newSlash = text.trim() == '/' && dismissed.trim() != '/';
    _dismissedSlashText = parseSlashInput(text) == null || newSlash ? null : text;
  }

  void _dismissSlashPalette() {
    if (_dismissedSlashText != null || parseSlashInput(_input.text) == null) return;
    setState(() => _dismissedSlashText = _input.text);
  }

  PaletteContent? _slashContent(List<SlashCommand> commands) => _dismissedSlashText != null
      ? null
      : PaletteContent.of(
          commands,
          _input.text,
          caret: _input.selection.isCollapsed ? _input.selection.extentOffset : -1,
        );

  KeyEventResult _composerKey(FocusNode node, KeyEvent event) {
    final mention = _mentions.handleKey(node, event);
    if (mention != KeyEventResult.ignored) return mention;
    final composing = _input.value.composing;
    if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && _slashContent(_commands) != null) {
      _dismissSlashPalette();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 底色遮罩的实心高度:页面布局排好输入条时写入(见 [_ChatLayout])。
  final _veilHeight = ValueNotifier<double>(0);

  /// How far the list has scrolled under the header (0..1), for its fade.
  final _scrolledUnder = ValueNotifier<double>(0);

  /// Picked in the ＋ menu, not sent yet.
  List<DraftAttachment> _drafts = const [];

  /// Only this creation may own the composer's busy state.
  Object? _creating;

  /// Only one apply of a session's owed new-chat setup at a time.
  Object? _applyingSetup;

  /// A page/client change retires an intent even when its draft key returns.
  Object _draftScope = Object();

  /// Only this wait may resume a send or clear the composer's busy state.
  Object? _syncWait;

  /// How the last turn ended, for the header's live region.
  String? _spoken;

  /// 每个对话一份草稿:换对话时输入条换成那个对话的字和附件。
  late final DraftStore _draftStore;

  /// The open conversation's id, or `new`.
  late String _draftKey;

  void _saveDraft() => _draftStore.save(_draftKey, _input.text, _drafts);

  /// Attachments first: setting the text saves both.
  void _showDraft(ChatDraft? draft) {
    _drafts = draft?.attachments ?? const [];
    final text = draft?.text ?? '';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _switchDraft(String? sessionId) {
    final key = sessionId ?? 'new';
    if (key == _draftKey) return;

    _draftScope = Object();
    _creating = null;
    _syncWait = null;
    _composerToastWait?.cancel();

    _mentions.dismiss();
    _dismissedSlashText = null;
    _saveDraft();
    _draftKey = key;
    _spoken = null;

    setState(() => _showDraft(ref.read(draftStoreProvider).drafts[key]));
  }

  /// 没有会话时的错误(建会话失败),会话内的错误走 ChatState.error。
  String? _localError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleInteraction();
    ref.listenManual(currentSessionProvider, (_, _) => _scheduleInteraction());

    // A download or deletion changes capabilities without replacing the host.

    _draftKey = ref.read(currentSessionProvider) ?? 'new';
    _draftStore = ref.read(draftStoreProvider.notifier);
    // Start reading what earlier sessions still owe before the first send.
    ref.read(owedSetupsProvider.notifier);
    _showDraft(ref.read(draftStoreProvider).drafts[_draftKey]);
    _input.addListener(_resetSlashDismissal);
    _input.addListener(_saveDraft);
    ref.listenManual(currentSessionProvider, (_, next) {
      // Another conversation: nothing of this one is read aloud any more.

      _switchDraft(next);
    });
    ref.listenManual(activeConnectionProvider.select((c) => c.value?.client), (_, _) {
      _draftScope = Object();
      if (_creating != null || _syncWait != null) {
        setState(() {
          _creating = null;
          _syncWait = null;
        });
      }
    });
    // Saved drafts arrive a moment after launch.
    ref.listenManual(draftStoreProvider.select((s) => s.loaded), (_, loaded) {
      if (loaded && _input.text.isEmpty) {
        setState(() => _showDraft(ref.read(draftStoreProvider).drafts[_draftKey]));
      }
    });
    // Opening the chat counts as "open" for the balance (throttled to 1/min).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Asked for from another page before this one was built.
      if (mounted && ref.read(composerInsertProvider) != null) {
        _takeComposerInsert();
      }
      if (mounted && ref.read(readyComposeProvider) != null) _takeCompose();
    });
  }

  /// Skills handed over from 技能: `/name` alone is then a message, never a
  /// command whose name merely starts the same way (a new chat has no skill
  /// list to tell them apart).
  final _handedSkills = <String>{};

  /// 技能 › 「在对话里用」/「新对话里用」: the word into that conversation's
  /// composer (null: a new one) at the caret, focused, confirmed above it.
  void _takeComposerInsert() {
    final insert = ref.read(composerInsertProvider.notifier).take();
    if (insert == null || !mounted) return;

    if (ref.read(currentSessionProvider) != insert.sessionId) {
      ref.read(currentSessionProvider.notifier).select(insert.sessionId);
    }
    _switchDraft(insert.sessionId);
    if (insert.skill case final name?) _handedSkills.add(name);
    _input.value = insertComposerToken(_input.value, insert.token);
    _focus.requestFocus();
    _composerToast(composerInsertedText);
  }

  /// A toast about the composer (a fork's 「返回原对话」, an inserted skill): above
  /// it, once the frame has laid out whatever just went into it (编辑后重发's text)
  /// and the capsule has finished growing to it.
  void _composerToast(String message, {String? actionLabel, VoidCallback? onAction}) {
    void show() {
      if (!mounted) return;
      showComposerToast(
        context,
        message,
        composerHeight: _veilHeight.value + _ChatLayout.overlap,
        actionLabel: actionLabel,
        onAction: onAction,
      );
    }

    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted) return;
        _composerToastWait?.cancel();
        // A composer that has just been focused is still opening.
        final opening = _composerOpens(context) && _focus.hasFocus;
        _composerToastWait = Timer(AppMotion.of(context, opening ? AppMotion.emphasized : AppMotion.quick), show);
      })
      ..ensureVisualUpdate();
  }

  Timer? _composerToastWait;

  /// A phone's composer opens into two rows while typing. A window too short for the
  /// extra row keeps it on one: the model is on the side panel's 信息 there.
  bool _composerOpens(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width < WindowClass.mediumMin && size.height >= WindowClass.compactHeight;
  }

  @override
  void dispose() {
    _toTop?.dispose();

    WidgetsBinding.instance.removeObserver(this);
    _endInteraction?.call();
    _endInteraction = null;
    _draftScope = Object();
    _creating = null;
    _syncWait = null;
    _composerToastWait?.cancel();
    _input.removeListener(_resetSlashDismissal);
    _input.removeListener(_saveDraft);
    _mentions.dispose();

    // The page is gone, and its dictation with it.

    _input.dispose();
    _focus.dispose();
    _scrolledUnder.dispose();
    _veilHeight.dispose();
    super.dispose();
  }

  /// The open session, or a new one (create → select → apply the model picked
  /// on the new-chat screen). Null when it could not be created.
  Future<String?> _ensureSession({required bool Function() isCurrent}) async {
    if (!isCurrent()) return null;
    final current = ref.read(currentSessionProvider);
    if (current != null) {
      // A session made on the new-chat screen may still owe its picks (a
      // failed apply, kept across screens and restarts): settle them first.
      // (The saved ones are read when this screen starts, long before a send.)
      final host = ref.read(activeHostProvider);
      final owed = ref.read(owedSetupsProvider.notifier).of(host, current);
      if (owed != null && !await _applyOwedSetup(host, current, owed, isCurrent)) return null;
      return current;
    }
    if (_creating != null) return null;
    final host = ref.read(activeHostProvider);
    final pendingFolder = ref.read(pendingSessionFolderProvider);
    final attempt = Object();
    bool ownsCreation() => identical(_creating, attempt) && isCurrent();
    setState(() {
      _creating = attempt;
      _localError = null;
    });
    try {
      final String sessionId;
      try {
        sessionId = await ref.read(sessionsProvider.notifier).create();
      } catch (e) {
        if (ownsCreation()) {
          setState(() => _localError = chatErrorText(e, action: appL10n.chatCreateFailed));
        }
        return null;
      }
      // A completed create may outlive its page, client or new-chat draft.
      // Check before any selection, migration, deletion or model side effect.
      if (!ownsCreation() || _draftKey != 'new' || ref.read(currentSessionProvider) != null) return null;
      if (ref.read(pendingSessionFolderProvider) != pendingFolder) return null;
      if (pendingFolder != null) {
        await ref
            .read(drawerViewProvider.notifier)
            .moveSessions(
              [sessionId],
              pendingFolder,
              isCurrent: () => ownsCreation() && ref.read(pendingSessionFolderProvider) == pendingFolder,
            );
        if (!ownsCreation() || ref.read(pendingSessionFolderProvider) != pendingFolder) return null;
      }
      final pendingModes = ref.read(pendingNewChatModesProvider);
      // What the chips show is what the session gets: a pick the Host no
      // longer offers falls back to the default, a hidden Host default to
      // the offered one.
      final setup = OwedSetup(
        preset: newChatPresetToApply(ref.read(agentPresetsProvider).value, pendingModes.preset),
        permission: newChatPermissionToApply(ref.read(permissionStateProvider(null)).value, pendingModes.permission),
        model: ref.read(pendingModelProvider),
      );
      _draftKey = sessionId;
      _saveDraft();
      if (!ownsCreation() || _draftKey != sessionId) return null;
      ref.read(currentSessionProvider.notifier).select(sessionId);
      if (!ownsCreation() || _draftKey != sessionId || ref.read(currentSessionProvider) != sessionId) return null;
      ref.read(composerQuoteProvider.notifier).move('new', sessionId);

      if (!ownsCreation() || _draftKey != sessionId) return null;
      _draftStore.clear('new');
      if (!setup.isEmpty) {
        if (!ownsCreation()) return null;
        // The picks move to the session: owed until the Host confirms each.
        ref.read(pendingNewChatModesProvider.notifier).clear();
        ref.read(pendingModelProvider.notifier).select(null);
        ref.read(owedSetupsProvider.notifier).put(host, sessionId, setup);
        if (!ownsCreation()) return null;
        if (!await _applyOwedSetup(host, sessionId, setup, ownsCreation)) return null;
      }
      if (!ownsCreation() || _draftKey != sessionId || ref.read(currentSessionProvider) != sessionId) return null;
      return sessionId;
    } finally {
      if (mounted && identical(_creating, attempt)) setState(() => _creating = null);
    }
  }

  /// Applies what [sessionId] still owes from the new-chat screen before its
  /// first prompt: the preset first (it may bring its own defaults), then the
  /// permission and model picks on top. Each pick stays owed (owedSetupsProvider,
  /// across screens and restarts) until the Host confirms it, and is retried
  /// on the next send: the message must not go out under a setup the person
  /// did not choose.
  Future<bool> _applyOwedSetup(HostRef host, String sessionId, OwedSetup owed, bool Function() isCurrent) async {
    if (_applyingSetup != null) return false;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return false;
    // What the Host confirms is recorded even if this screen goes meanwhile.
    final container = ProviderScope.containerOf(context, listen: false);
    final setups = ref.read(owedSetupsProvider.notifier);
    final attempt = Object();
    _applyingSetup = attempt;
    bool current() => identical(_applyingSetup, attempt) && mounted && isCurrent();
    try {
      if (owed.preset case final preset?) {
        await client.selectAgentPreset(sessionId, preset);
        setups.settled(host, sessionId, preset: preset);
        if (!current()) return false;
      }
      if (owed.permission case final permission?) {
        final CommandResult result;
        try {
          result = await client.setPermissionPreset(sessionId, permission);
        } finally {
          container.invalidate(permissionStateProvider(sessionId));
        }
        if (!result.success) throw DshRemoteException('permission', result.text ?? permission);
        setups.settled(host, sessionId, permission: permission);
        if (!current()) return false;
      }
      if (owed.model case final model?) {
        // setModel says itself what went wrong.
        if (!await ref.read(chatProvider(sessionId).notifier).setModel(model)) return false;
        setups.settled(host, sessionId, model: model);
        if (!current()) return false;
      }
      return true;
    } catch (e) {
      // The session exists by now, so the new-chat error slot is gone: say it
      // where the person is looking. The message stays in the composer.
      if (current()) _toast(chatErrorText(e, action: appL10n.viewNewChatModesFailed));
      return false;
    } finally {
      if (identical(_applyingSetup, attempt)) _applyingSetup = null;
    }
  }

  Future<void> _send({SendMode mode = SendMode.now}) async {
    // The `@` picker is open on a typed name: sending picks its marked row.
    if (_mentions.pickHighlighted()) return;
    final typed = _input.text.trim();
    final drafts = _drafts;
    if ((typed.isEmpty && drafts.isEmpty) || _creating != null || _syncWait != null) return;
    // Generation mode: an ordinary message whose first line is the
    // parameter header (media-generation §8, revision of 2026-10-28).

    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final generation = client.mux.generation;
    final scope = _draftScope;
    bool ownsDraft() => identical(_draftScope, scope) && _sameConnection(client, generation);
    // 引用追问: the passage above the composer goes in front, as a quote.
    final quote = ref.read(composerQuoteProvider)[_draftKey];
    final asked = quote == null ? typed : withQuote(quote, typed);
    // The header grammar refuses what it can't carry (§4.6.4): nothing goes.

    final text = asked;

    // With attachments or a quote the line is a message, even if it starts
    // with "/".
    if (drafts.isEmpty && quote == null) {
      final input = parseSlashInput(text);
      // A bare "/": the palette is open, the person picks a row.
      if (input != null && !input.hasArgs && input.token.isEmpty) return;
      final slash = _slashFor(text);
      if (slash != null) {
        final (command, line, picked) = slash;
        if (picked) {
          _pick(command, atCaret: false);
        } else {
          await _runSlash(command, line);
        }
        return;
      }
    }

    RemoteBenchmark.start('first_send_ack');
    try {
      final sessionId = await _ensureSession(isCurrent: ownsDraft);
      if (sessionId == null || !ownsDraft() || _draftKey != sessionId) return;
      final chat = ref.read(chatProvider(sessionId).notifier);
      if (!ref.read(chatProvider(sessionId)).controlReady) {
        if (mode == SendMode.interrupt) return;
        // session/create can finish before its first follow snapshot. Keep
        // the draft visible while waiting; a timeout must not eat the message.
        final wait = Object();
        bool current() => identical(_syncWait, wait) && _draftKey == sessionId && ownsDraft();
        setState(() => _syncWait = wait);
        try {
          final ready = await chat.waitForSync(isCurrent: current);
          if (!ready ||
              !current() ||
              _input.text.trim() != typed ||
              !identical(_drafts, drafts) ||
              ref.read(composerQuoteProvider)[sessionId] != quote) {
            return;
          }
        } finally {
          if (mounted && identical(_syncWait, wait)) setState(() => _syncWait = null);
        }
      }
      // Creation/model application can also await while the composer is edited,
      // even when the session's baseline is already available on return.
      if (!ownsDraft() ||
          _draftKey != sessionId ||
          _input.text.trim() != typed ||
          !identical(_drafts, drafts) ||
          ref.read(composerQuoteProvider)[sessionId] != quote) {
        return;
      }
      setState(() => _drafts = const []);
      // A new message: the reply being read aloud is old news.

      _input.clear();
      ref.read(composerQuoteProvider.notifier).clear(sessionId);

      // One open question and nothing else waiting: the text is its answer
      // (a steer would wait behind the question).
      final current = ref.read(chatProvider(sessionId));
      final bool ok;
      if (current.singleQuestion case final request?
          when drafts.isEmpty && quote == null && mode == SendMode.now && current.openApproval == null) {
        ok = await chat.answer(request, [QuestionAnswer(request.questions.single.id, custom: text)]);
      } else {
        ok = await chat.send(text, attachments: drafts, mode: mode);
        // A generation request, counted on top of its turn.
      }
      if (ok) RemoteBenchmark.finish('first_send_ack');
      if (!ok && _sameHost(client)) _giveBack(sessionId, typed, drafts, quote: quote);
    } finally {
      RemoteBenchmark.cancel('first_send_ack');
    }
  }

  // A failed send belongs to the Host that accepted it. The controller may
  // retire its continuation after reconnect; do not restore its draft into a
  // replacement Host merely because it uses the same session id.
  bool _sameConnection(DshClient client, MuxGeneration? generation) =>
      mounted &&
      identical(ref.read(activeConnectionProvider).value?.client, client) &&
      identical(client.mux.generation, generation);

  /// A send that did not go out (`send` is false only then) comes back on the Host that had
  /// it, over a reconnect too (#1416); never into a replacement Host.
  bool _sameHost(DshClient client) => mounted && identical(ref.read(activeConnectionProvider).value?.client, client);

  /// 没发出去:把字、附件和引用还给那个对话(用户还没开始打新的才还)。
  void _giveBack(String sessionId, String text, List<DraftAttachment> attachments, {String? quote}) {
    final quotes = ref.read(composerQuoteProvider.notifier);
    if (quote != null && ref.read(composerQuoteProvider)[sessionId] == null) {
      quotes.set(sessionId, quote);
    }
    if (_draftKey != sessionId) {
      // Moved on to another conversation: back into its own draft.
      if (ref.read(draftStoreProvider).drafts[sessionId] == null) {
        _draftStore.save(sessionId, text, attachments);
      }
      return;
    }
    if (_drafts.isEmpty) setState(() => _drafts = attachments);
    if (_input.text.isEmpty) {
      _input.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    _saveDraft();
  }

  /// 「重新回答」, second half: the fork is open; send the prompt there as
  /// it was. Not sent: it waits in that conversation's composer.
  Future<void> _resend(String sessionId, String text, List<DraftAttachment> images) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final ok = await ref.read(chatProvider(sessionId).notifier).send(text, attachments: images);
    if (ok || !_sameHost(client)) return;
    final (:quote, :body) = splitQuote(text);
    _giveBack(sessionId, quote == null ? text : body, images, quote: quote);
  }

  /// 「引用」 on a reply of [sessionId]: the passage above its composer.
  void _quote(String sessionId, String passage) {
    ref.read(composerQuoteProvider.notifier).set(sessionId, passage);
    _focus.requestFocus();
  }

  /// [message] into the composer, its leading quote back above it as the
  /// chip (「编辑后重发」 of a message that quoted something), a generation
  /// request's header back as the mode. [quoteChip] false
  /// keeps it all as text (shared text: the chip would cut a long quote);
  /// [restoreMode] false takes a leading header as text too (a description
  /// from a card); [focus] false leaves the keyboard down (dictation).
  void _compose(String message, {bool quoteChip = true, bool restoreMode = true, bool focus = true}) {
    var text = message;
    // A valid generation request, where this host can generate: its header
    // becomes the mode again, the description (as it was) the text. Anywhere
    // else the whole message stays as it was, header and all (§4.6.6).

    final (:quote, :body) = quoteChip ? splitQuote(text) : (quote: null, body: text);
    if (quote != null) {
      ref.read(composerQuoteProvider.notifier).set(_draftKey, quote);
    }
    final shown = quote == null ? text : body;
    _input.value = TextEditingValue(
      text: shown,
      selection: TextSelection.collapsed(offset: shown.length),
    );
    if (focus) _focus.requestFocus();
  }

  bool _takingCompose = false;

  /// The share sheet, a launcher shortcut, the tile, a file opened with the
  /// app (ui/shell/system_entry_host.dart): 新对话, its composer filled — the
  /// shared text under what was there, attachments after its own — and
  /// focused, or listening for 「语音输入」. Nothing is sent.
  void _takeCompose() {
    if (_takingCompose) return;
    _takingCompose = true;
    try {
      // The queue itself, not readyComposeProvider: this runs inside its
      // notification.
      while (mounted && ref.read(draftStoreProvider).loaded) {
        final request = ref.read(composeInboxProvider.notifier).take();
        if (request == null) break;
        if (ref.read(currentSessionProvider) != null) {
          ref.read(currentSessionProvider.notifier).select(null);
        }
        _switchDraft(null);
        final merged = mergeIntoDraft(
          text: _input.text,
          attachments: _drafts,
          request: request,
          filesAllowed: canStageFiles(ref.read(activeConnectionProvider).value, ref.read(activeHostProvider)),
        );
        setState(() => _drafts = merged.attachments);
        _compose(merged.text, quoteChip: false, focus: true);
        _saveDraft();

        if (merged.problem ?? request.note case final line?) {
          showComposerToast(context, line, composerHeight: _veilHeight.value + _ChatLayout.overlap);
        }
      }
    } finally {
      _takingCompose = false;
    }
  }

  /// Long-press on send while a turn runs: how this message should land.
  Future<void> _sendOptions() async {
    final sessionId = ref.read(currentSessionProvider);
    final running = sessionId != null && ref.read(chatProvider(sessionId)).running;
    if (!running) return _send();
    // The choice belongs to the draft and connection that opened this menu.
    // A surviving sheet must not send a newly selected conversation or draft.
    final scope = _draftScope;
    final client = ref.read(activeConnectionProvider).value?.client;
    final generation = client?.mux.generation;
    final readyNumber = client?.mux.lastReadyGenerationNumber;
    final text = _input.text;
    final drafts = _drafts;
    final quote = ref.read(composerQuoteProvider)[sessionId];
    final mode = await showAppSheet<SendMode>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(appL10n.chatSendMode),
            SheetGroup(
              margin: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
              children: [
                for (final (mode, icon, title, subtitle) in [
                  (SendMode.steer, AppIcons.steer, appL10n.chatSteer, appL10n.chatSteerHint),
                  (SendMode.interrupt, AppIcons.interrupt, appL10n.chatInterruptAndSend, appL10n.chatInterruptHint),
                  (SendMode.queue, AppIcons.queued, appL10n.chatQueue, appL10n.chatQueueHint),
                ])
                  SettingsTile(
                    tinted: false,
                    chevron: false,
                    icon: icon,
                    title: title,
                    subtitle: subtitle,
                    onTap: () => Navigator.pop(sheet, mode),
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
    if (mode == null ||
        !mounted ||
        !identical(_draftScope, scope) ||
        _draftKey != sessionId ||
        ref.read(currentSessionProvider) != sessionId ||
        client == null ||
        !_sameConnection(client, generation) ||
        client.mux.lastReadyGenerationNumber != readyNumber ||
        _input.text != text ||
        !identical(_drafts, drafts) ||
        ref.read(composerQuoteProvider)[sessionId] != quote) {
      return;
    }
    await _send(mode: mode);
  }

  /// 「立即发送」 / 「发送」 on a waiting message.
  Future<void> _sendNow(PendingPrompt prompt) async {
    final sessionId = ref.read(currentSessionProvider);
    if (sessionId == null) return;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final generation = client.mux.generation;
    final lost = await ref.read(chatProvider(sessionId).notifier).sendNow(prompt);
    if (_sameConnection(client, generation)) _giveBackLost(sessionId, lost);
  }

  /// A waiting message taken out to go again did not make it back: into the
  /// composer, like any send that failed.
  void _giveBackLost(String sessionId, List<PendingPrompt> lost) {
    final prompt = lost.firstOrNull;
    if (prompt == null) return;
    final (:quote, :body) = splitQuote(prompt.text);
    _giveBack(sessionId, quote == null ? prompt.text : body, prompt.attachments, quote: quote);
  }

  /// "撤回" on a queued message: out of the inbox and back into the composer
  /// (unless the person already started typing something new).
  Future<void> _withdraw(PendingPrompt prompt) async {
    final sessionId = ref.read(currentSessionProvider);
    if (sessionId == null) return;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final generation = client.mux.generation;
    final readyNumber = client.mux.lastReadyGenerationNumber;
    final ok = await ref.read(chatProvider(sessionId).notifier).withdrawQueued(prompt);
    if (!ok ||
        !mounted ||
        !_sameConnection(client, generation) ||
        client.mux.lastReadyGenerationNumber != readyNumber) {
      return;
    }
    if (_draftKey != sessionId) {
      // The queue removal succeeded, but its text still belongs to that chat.
      // Preserve an existing draft as a whole, including its quote.
      if (ref.read(draftStoreProvider).drafts[sessionId] == null) {
        _giveBackLost(sessionId, [prompt]);
      }
      return;
    }
    var restored = false;
    if (_input.text.trim().isEmpty && prompt.text.isNotEmpty) {
      final (:quote, :body) = splitQuote(prompt.text);
      if (quote != null && ref.read(composerQuoteProvider)[sessionId] == null) {
        ref.read(composerQuoteProvider.notifier).set(sessionId, quote);
      }
      _input.text = quote == null ? prompt.text : body;
      restored = true;
    }
    if (_drafts.isEmpty && prompt.attachments.isNotEmpty) {
      setState(() => _drafts = prompt.attachments);
      restored = true;
    }
    if (restored) _focus.requestFocus();
    showBriefNotice(context, restored ? appL10n.chatWithdrawnEditable : appL10n.chatWithdrawn);
  }

  // ---------------------------------------------------------------------------
  // 附件

  Future<void> _attach() async {
    final room = maxAttachments - _drafts.length;
    final client = ref.read(activeConnectionProvider).value?.client;
    // A draft or connection that changes away and back still retires this pick.
    final scope = _draftScope;
    final generation = client?.mux.generation;
    final readyNumber = client?.mux.lastReadyGenerationNumber;
    var hostRetired = false;
    bool ownsDraft() =>
        mounted &&
        !hostRetired &&
        identical(_draftScope, scope) &&
        identical(ref.read(activeConnectionProvider).value?.client, client) &&
        identical(client?.mux.generation, generation) &&
        client?.mux.lastReadyGenerationNumber == readyNumber;
    // A derived connection can coalesce A -> B -> A before its next read.
    // Observe the selected Host directly for this picker attempt only.
    final hostChanges = ref.listenManual(activeHostProvider, (previous, next) {
      if (previous != next) hostRetired = true;
    });
    try {
      final choice = await showPlusPanel(
        context,
        files: canStageFiles(ref.read(activeConnectionProvider).value, ref.read(activeHostProvider)),
        sessionId: ref.read(currentSessionProvider),
      );

      if (choice is! AttachChoice || !ownsDraft()) return;
      if (room <= 0) {
        _toast(appL10n.chatAttachmentLimit(maxAttachments));
        return;
      }
      final source = choice.source;
      final picker = ref.read(attachmentPickerProvider);
      final PickedAttachments picked;
      try {
        picked = switch (source) {
          AttachSource.gallery => PickedAttachments(await picker.pickImages(limit: room)),
          AttachSource.camera => PickedAttachments([?await picker.takePhoto()]),
          AttachSource.files => await picker.pickFiles(limit: room, heldBytes: totalAttachmentBytes(_drafts)),
        };
      } on PlatformException catch (e) {
        if (!ownsDraft()) return;
        _toast(
          e.code.contains('denied') || e.code.contains('permission')
              ? appL10n.chatAttachmentPermission
              : chatErrorText(e, action: appL10n.chatOpenAttachmentFailed),
        );
        return;
      } catch (e) {
        if (!ownsDraft()) return;
        _toast(chatErrorText(e, action: appL10n.chatReadFailed));
        return;
      }
      if (!ownsDraft()) return;
      _addDrafts(picked.attachments, problem: picked.problem);
    } finally {
      hostChanges.close();
    }
  }

  /// An image from the keyboard (screenshot, sticker): into the tray, not sent.
  void _pasteContent(KeyboardInsertedContent content) {
    final data = content.data;
    if (data == null || data.isEmpty) {
      _toast(appL10n.chatReadImageFailed);
      return;
    }
    final extension = switch (content.mimeType) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'png',
    };
    _addDrafts([DraftAttachment.sniff('${appL10n.fileImageName}.$extension', data)]);
  }

  void _addDrafts(List<DraftAttachment> picked, {String? problem}) {
    final room = maxAttachments - _drafts.length;
    var heldBytes = totalAttachmentBytes(_drafts);
    final ok = <DraftAttachment>[];
    for (final a in picked) {
      final p = attachmentProblem(a) ?? attachmentBudgetProblem(heldBytes, a);
      if (p != null) {
        problem ??= p;
      } else if (ok.length < room) {
        ok.add(a);
        heldBytes += a.size;
      } else {
        problem ??= appL10n.chatAttachmentLimit(maxAttachments);
      }
    }
    if (ok.isNotEmpty) {
      setState(() => _drafts = [..._drafts, ...ok]);
      _saveDraft();
    }
    if (problem != null) _toast(problem);
  }

  void _removeDraft(DraftAttachment a) {
    setState(
      () => _drafts = [
        for (final d in _drafts)
          if (d.id != a.id) d,
      ],
    );
    _saveDraft();
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // 生成模式 (docs/design/media-generation.md §4.2)

  Future<void> _pickNewChatFolder() async {
    final scope = _draftScope;
    final host = ref.read(activeHostProvider);
    bool current() =>
        mounted &&
        identical(scope, _draftScope) &&
        ref.read(activeHostProvider) == host &&
        ref.read(currentSessionProvider) == null;
    final view = ref.read(drawerViewProvider);
    final selected = ref.read(pendingSessionFolderProvider);
    final pick = await showMoveToFolderSheet(
      context,
      folders: view.folders,
      counts: {for (final f in view.folders) f.id: f.sessionIds.length},
      currentFolder: selected,
      anyFiled: selected != null,
      title: context.l10n.shellFolders,
      allowCreate: false,
    );
    if (pick == null || !current()) return;
    final String? folderId;
    switch (pick) {
      case PickFolder(:final folderId):
        if (ref.read(drawerViewProvider).byId(folderId) == null) return;
        ref.read(pendingSessionFolderProvider.notifier).select(folderId);
        return;
      case PickNoFolder():
        folderId = null;
      case PickNewFolder():
        return;
    }
    ref.read(pendingSessionFolderProvider.notifier).select(folderId);
  }

  // ---------------------------------------------------------------------------
  // 斜杠指令

  List<SlashCommand> get _commands => ref.read(slashCommandsProvider(ref.read(currentSessionProvider)));

  /// What sending [text] means as a command: an exact name runs as typed;
  /// a partial name picks the palette's first row (`picked`). Null = a
  /// normal message (not a command line, or an unknown name with input,
  /// such as a path).
  (SlashCommand, String, bool)? _slashFor(String text) {
    final input = parseSlashInput(text);
    if (input == null) return null;
    final commands = _commands;
    final exact = resolveSlashCommand(commands, input.token);
    // `/skill …` is a message: the Host loads the skill from its text.
    if (exact?.kind == SlashCommandKind.skill) return null;
    if (exact != null) {
      return (exact, '/${exact.name}${input.rest ?? ''}', false);
    }
    if (input.hasArgs) return null;
    if (_handedSkills.contains(input.token)) return null;
    final matches = filterSlashCommands(commands, input.token);
    if (matches.isEmpty) return null;
    return (matches.first, '/${matches.first.name}', true);
  }

  /// A row picked in the palette: app commands and commands without input run
  /// now; commands that take input go into the composer for the arguments.
  void _pick(SlashCommand command, {bool atCaret = true}) {
    _dismissSlashPalette();
    final value = _input.value;
    final caret = atCaret && value.selection.isValid ? value.selection.end : value.text.length;
    final (:leading, :suffix) = slashCompletionContext(_commands, value.text, caret);
    if (slashPickInsertsText(command, hasSuffix: suffix.isNotEmpty)) {
      final prefix = '${value.text.substring(0, leading)}/${command.name}';
      final separator = suffix.isEmpty || !RegExp(r'^\s').hasMatch(suffix) ? ' ' : '';
      final text = '$prefix$separator$suffix';
      _input.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: (prefix.length + 1).clamp(0, text.length)),
      );
      _focus.requestFocus();
      return;
    }
    _runSlash(command, '/${command.name}');
  }

  Future<void> _runSlash(SlashCommand command, String line) async {
    HapticFeedback.selectionClick();
    switch (command.kind) {
      case SlashCommandKind.app:
        _input.clear();
        switch (command.name) {
          case 'new':
            ref.read(currentSessionProvider.notifier).select(null);
          case 'model':
            await _showModelSheet();
          case 'export':
            final sessionId = ref.read(currentSessionProvider);
            if (sessionId == null) {
              _toast(appL10n.chatOpenChatFirst);
              return;
            }
            await Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => SessionExportPage(sessionId: sessionId)));
        }
      case SlashCommandKind.skill:
        _pick(command);
      case SlashCommandKind.host:
        final client = ref.read(activeConnectionProvider).value?.client;
        if (client == null) return;
        final generation = client.mux.generation;
        final scope = _draftScope;
        final text = _input.text;
        final drafts = _drafts;
        final quote = ref.read(composerQuoteProvider)[_draftKey];
        bool ownsDraft() => identical(_draftScope, scope) && _sameConnection(client, generation);
        final sessionId = await _ensureSession(isCurrent: ownsDraft);
        if (sessionId == null ||
            !ownsDraft() ||
            _draftKey != sessionId ||
            _input.text != text ||
            !identical(_drafts, drafts) ||
            ref.read(composerQuoteProvider)[sessionId] != quote) {
          return;
        }
        _input.clear();
        await ref.read(chatProvider(sessionId).notifier).runCommand(line);
    }
  }

  void _openUsage(String sessionId, ModelSelection? model) {
    showUsageSheet(context, sessionId: sessionId, model: model);
  }

  /// The stop key; what waits in the inbox goes right away (see
  /// [ChatController.cancel]).
  Future<void> _stop() async {
    final sessionId = ref.read(currentSessionProvider);
    if (sessionId == null) return;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final generation = client.mux.generation;
    final lost = await ref.read(chatProvider(sessionId).notifier).cancel();
    if (_sameConnection(client, generation)) _giveBackLost(sessionId, lost);
  }

  /// The engine could not be reached: try again.
  void _reconnect() {
    final host = ref.read(activeHostProvider);
    ref.read(remoteConnectionProvider(host).notifier).retry();
  }

  void _onSuggestion(ChatSuggestion suggestion) {
    _input.value = TextEditingValue(
      text: suggestion.prompt,
      selection: TextSelection.collapsed(offset: suggestion.prompt.length),
    );
    _focus.requestFocus();
  }

  Future<void> _showModelSheet() {
    final sessionId = ref.read(currentSessionProvider);
    final selection = sessionId == null ? ref.read(pendingModelProvider) : ref.read(chatProvider(sessionId)).model;
    return showModelSheet(
      context,
      current: selection ?? ref.read(currentModelCatalogProvider)?.defaultSelection,
      onSelected: _modelTarget(),
    );
  }

  /// 「换模型」 after the engine refused the model. DSH follows the official
  /// model listing, so the catalog read earlier may be stale: read it again.
  void _switchModel() {
    ref.invalidate(modelCatalogProvider);
    unawaited(_showModelSheet());
  }

  /// Where a model picked in a sheet opened now goes: the conversation open
  /// now (with none, the next new chat), on this host. The sheet can outlive
  /// that — the conversation deleted on the host while the catalog is read
  /// again, another conversation or host chosen — and a pick then goes to
  /// neither, rather than to whatever is open by then.
  ValueChanged<ModelSelection> _modelTarget() {
    final scope = ref.read(modelSelectionScopeProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final generation = client?.mux.generation;
    final sessionId = ref.read(currentSessionProvider);
    return (selection) {
      if (!mounted ||
          client == null ||
          !_sameConnection(client, generation) ||
          ref.read(activeConnectionProvider).isLoading ||
          ref.read(activeConnectionProvider).hasError ||
          !identical(ref.read(modelSelectionScopeProvider), scope) ||
          ref.read(currentSessionProvider) != sessionId) {
        return;
      }
      if (sessionId == null) {
        ref.read(pendingModelProvider.notifier).select(selection);
      } else {
        // A newer pick replaces a model still owed from the new-chat screen.
        ref.read(owedSetupsProvider.notifier).dropModel(ref.read(activeHostProvider), sessionId);
        ref.read(chatProvider(sessionId).notifier).setModel(selection);
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sessionId = ref.watch(currentSessionProvider);
    final connAsync = ref.watch(activeConnectionProvider);
    final conn = connAsync.value;
    final connected = conn != null;
    const starting = false;
    const tidying = false;
    const failureCard = false;
    const ChatIdleAction? idle = null;
    const idleBlank = false;

    // 只盯顶栏 / 输入条需要的几个字段:流式增量不重建整页。
    final chat = sessionId == null
        ? null
        : ref.watch(
            chatProvider(sessionId).select(
              (s) => (
                title: s.title,
                running: s.running,
                stopping: s.stopping,
                streamLost: s.streamLost,
                syncing: s.syncing,
                resyncing: s.resyncing,
                controlReady: s.controlReady,
                connection: s.connection,
                approval: s.openApproval,
                question: s.questions.firstOrNull,
                singleQuestion: s.singleQuestion != null,
                model: s.model,
                error: s.error,
                syncError: s.syncError,
                defaultModelSaveFailed: s.defaultModelSaveFailed,
                notice: s.notice,
                autoApprove: s.autoApprove,
              ),
            ),
          );
    final listedTitle = sessionId == null
        ? null
        : ref.watch(
            sessionsProvider.select((async) => async.value?.where((s) => s.sessionId == sessionId).firstOrNull?.title),
          );
    final pendingModel = ref.watch(pendingModelProvider);
    final newFolder = sessionId == null
        ? ref.watch(drawerViewProvider).byId(ref.watch(pendingSessionFolderProvider))
        : null;
    final hasFolders = sessionId == null && ref.watch(drawerViewProvider).folders.isNotEmpty;
    final commands = ref.watch(slashCommandsProvider(sessionId));
    final contextFraction = sessionId == null
        ? null
        : ref.watch(sessionUsageProvider(sessionId).select((u) => u.contextFraction));
    // 「帮我修复」: a fresh chat with the repair prompt in the composer,
    // not sent — the person reads it first.
    ref.listen(composerInsertProvider, (_, next) {
      if (next != null) _takeComposerInsert();
    });
    // Heard while providers refresh: switching the conversation right there
    // would rebuild the ones already refreshed this frame.
    ref.listen(readyComposeProvider, (_, next) {
      if (next != null) scheduleMicrotask(_takeCompose);
    });
    if (sessionId != null) {
      // A finished turn spent money: re-read the balance (throttled).
      ref.listen(chatProvider(sessionId).select((s) => s.running), (previous, running) {
        if (running) {
          _spoken = null;
        } else if (previous == true) {
          final turns = ref.read(chatProvider(sessionId)).turns;
          _spoken = switch (turns.lastOrNull?.endReason?.kind) {
            'aborted' => l10n.commonStopped,
            null || 'completed' || 'max-tokens' => l10n.chatTurnCompleted,
            _ => l10n.chatTurnError,
          };
        }
      });
    }

    final title = switch (chat?.title ?? listedTitle) {
      final t? when t.trim().isNotEmpty => chatTitleShown(t.trim()),
      _ => l10n.commonNewChat,
    };
    final approval = chat?.approval;
    final question = chat?.question;
    final status = _status(
      connecting: connAsync.isLoading && conn == null,
      starting: starting,
      connected: connected,
      idleLabel: null,
      streamLost: chat?.streamLost ?? false,
      syncing: chat?.syncing ?? false,
      label: conn?.label ?? l10n.commonThisPhone,
      connection: chat?.connection,
      running: chat?.running ?? false,
      stopping: chat?.stopping ?? false,
      waiting: approval != null
          ? l10n.commonWaitingApproval
          : question != null
          ? l10n.commonWaitingAnswer
          : null,
      // The live region reads out what is waiting, or how the turn ended.
      spoken: approval != null
          ? approvalText(approval)
          : question != null
          ? questionText(question)
          : _spoken,
    );
    final narrow = MediaQuery.sizeOf(context).width < WindowClass.mediumMin;
    // Where a new conversation starts (the drawer's workspace, else the one a
    // remote host falls back to, so the host's start directory is never silent).
    final newChat = sessionId == null;
    final workspace =
        ref.watch(selectedWorkspaceProvider) ?? (newChat ? ref.watch(recentWorkspaceForNewChatProvider) : null);
    final inHostDefault = newChat && workspace == null && ref.watch(newChatInHostDefaultProvider);
    // A one-shot subagent takes no messages: DSH Web shows it read-only.
    final readOnly =
        sessionId != null &&
        ref.watch(subagentParentProvider(sessionId).select((p) => p?.address.mode == SubagentMode.oneShot));
    // A subagent conversation: 「‹ 上级对话」 takes the menu key's place, so
    // the 新对话 key would have nothing to mirror.
    final isChild = sessionId != null && ref.watch(subagentParentProvider(sessionId).select((p) => p != null));
    // 生成模式: this conversation's, and what the host can do.

    // What the catalogue really offers here (§4.3): a picture can go in as a
    // reference, or as a video's first frame, only where a model takes one.

    // 引用追问: the passage waiting above this conversation's composer.
    final quote = ref.watch(composerQuoteProvider.select((quotes) => quotes[_draftKey]));
    // Mirror _send for ordinary text; attachments, quotes and generation
    // stay messages even while a question is waiting.
    final answerInComposer = (chat?.singleQuestion ?? false) && approval == null && _drafts.isEmpty && quote == null;
    final modelDefaultWarning = sessionId != null && chat?.error == null && (chat?.defaultModelSaveFailed ?? false);
    final error = sessionId == null
        ? _localError
        : chat?.error ?? (modelDefaultWarning ? l10n.engineModelDefaultSaveFailed : null);
    // An error wins the slot; a notice shows when there is none.
    final notice = error == null && sessionId != null ? chat?.notice : null;
    // A phone on its side with the keyboard up keeps a strip of chat: the
    // header and the dock step aside until the keyboard goes, so the latest
    // messages stay in sight above the composer.
    final typing =
        MediaQuery.sizeOf(context).height < WindowClass.compactHeight && MediaQuery.viewInsetsOf(context).bottom > 0;
    // 「自动允许中」/「完全权限」 ride on the bar right above the composer, not a
    // row of their own: beside the activity strip while a reply generates, at
    // the start of the capsule row otherwise. Their own row only where neither
    // shows (read only; a phone on its side typing folds both away).
    final running = chat?.running ?? false;
    final pillsBesideStrip = sessionId != null && running && !typing;

    final composerPills = _composerPills(sessionId, autoApprove: chat?.autoApprove ?? false, risk: !pillsBesideStrip);
    final headerHeight = typing ? MediaQuery.paddingOf(context).top + AppSpace.sm : ChatHeader.heightOf(context);

    Widget backdrop(Widget child) {
      final framed = widget.backdrop ? WallpaperBackdrop(child: child) : child;
      return _toTop == null ? framed : PrimaryScrollController(controller: _toTop, child: framed);
    }

    final screen = AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(Theme.of(context).brightness),
      child: backdrop(
        Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: true,
          // The pet stands over the page on the capsules above the
          // composer (they report themselves with PetPerch).
          body: CustomMultiChildLayout(
            delegate: _ChatLayout(_veilHeight),
            children: [
              LayoutId(
                id: _Slot.body,
                child: sessionId == null || idleBlank
                    ? Padding(
                        padding: EdgeInsets.only(top: headerHeight, bottom: _ChatLayout.overlap),
                        child: Align(
                          alignment: const Alignment(0, -0.25),
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ChatEmptyState(
                                  connected: connected,
                                  suggestions: ref.watch(settingsProvider.select((s) => s.chatSuggestions))
                                      ? defaultSuggestions
                                      : const [],
                                  connecting: connAsync.isLoading,
                                  starting: starting,
                                  tidying: tidying,
                                  idle: idle,
                                  onReconnect: connAsync.hasError && !connAsync.isLoading && !failureCard
                                      ? _reconnect
                                      : null,
                                  onSuggestion: _onSuggestion,
                                  options: NewChatOptions(
                                    folderLabel: !hasFolders
                                        ? null
                                        : newFolder == null
                                        ? context.l10n.shellFolders
                                        : context.l10n.shellFolderLabel(newFolder.name),
                                    onFolder: hasFolders ? _pickNewChatFolder : null,
                                  ),
                                  workspace: workspace != null
                                      ? workspaceTitle(workspace)
                                      : inHostDefault
                                      ? context.l10n.viewEmptyHostDefaultDirectory
                                      : null,
                                  onWorkspace: () => showWorkspaceSheet(
                                    context,
                                    onManage: () =>
                                        Navigator.of(context)
                                            .push(MaterialPageRoute<void>(builder: (_) => const WorkspacesPage())),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : _ChatTextScale(
                        child: FluidFadeIn(
                          key: ValueKey(sessionId),
                          child: ChatList(
                            key: ValueKey(sessionId),
                            sessionId: sessionId,
                            toTop: _toTop,
                            topInset: headerHeight,
                            bottomInset: _ChatLayout.overlap,
                            scrolledUnder: _scrolledUnder,
                            onWithdraw: _withdraw,
                            onSendNow: _sendNow,
                            onEditPrompt: _compose,
                            onResend: _resend,
                            onQuote: readOnly ? null : (passage) => _quote(sessionId, passage),
                            onToast: _composerToast,
                            onSwitchModel: readOnly ? null : _switchModel,
                          ),
                        ),
                      ),
              ),
              LayoutId(
                id: _Slot.veil,
                child: BackdropVeil(solidHeight: _veilHeight),
              ),
              LayoutId(
                id: _Slot.header,
                child: _HeaderAside(
                  aside: typing,
                  child: ChatHeader(
                    scrolledUnder: sessionId == null ? null : _scrolledUnder,
                    title: title,
                    status: status,
                    detail: !narrow || isChild
                        ? null
                        : folderLabel(
                            ref.watch(
                              sessionsProvider.select(
                                (s) => s.value?.where((session) => session.sessionId == sessionId).firstOrNull?.cwd,
                              ),
                            ),
                          ),
                    onOpenDrawer: widget.onOpenDrawer,
                    onNewChat: sessionId == null || isChild
                        ? null
                        : () {
                            HapticFeedback.selectionClick();
                            ref.read(currentSessionProvider.notifier).select(null);
                          },
                    onTitleTap: sessionId == null
                        ? null
                        : () => SessionDetailPage.open(context, sessionId, toggle: true),
                    trailing: narrow && (sessionId != null || !connected)
                        ? null
                        : ModelChip(
                            selection: sessionId == null ? pendingModel : chat?.model,
                            onSelected: _modelTarget(),
                            grouped: true,
                          ),
                  ),
                ),
              ),
              LayoutId(
                id: _Slot.palette,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: AppSpace.floatingWidth),
                    child: ListenableBuilder(
                      listenable: Listenable.merge([_input, _mentions]),
                      builder: (context, _) {
                        final live = connected && !readOnly;
                        final mention = live && _mentions.isOpen;
                        final content = live && !mention ? _slashContent(commands) : null;
                        return PopScope<Object?>(
                          canPop: content == null,
                          onPopInvokedWithResult: (didPop, _) {
                            if (!didPop) _dismissSlashPalette();
                          },
                          child: AnimatedSwitcher(
                            duration: AppMotion.of(context, AppMotion.quick),
                            switchInCurve: AppMotion.enter,
                            switchOutCurve: AppMotion.exit,
                            transitionBuilder: (child, animation) => FadeTransition(
                              opacity: animation,
                              child: ScaleTransition(
                                alignment: Alignment.bottomCenter,
                                scale: Tween(begin: 0.96, end: 1.0).animate(animation),
                                child: child,
                              ),
                            ),
                            child: mention
                                ? MentionPicker(key: const ValueKey('mention'), controller: _mentions)
                                : content == null
                                ? const SizedBox(key: ValueKey('none'), width: double.infinity)
                                : TextFieldTapRegion(
                                    key: ValueKey(content is PaletteHint),
                                    groupId: _composerGroup,
                                    onTapOutside: (_) => _dismissSlashPalette(),
                                    child: SlashPalette(content: content, onPick: _pick),
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              LayoutId(
                id: _Slot.composer,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: AppSpace.floatingWidth),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SmoothSize(
                              duration: AppMotion.of(context, AppMotion.standard),
                              curve: AppMotion.std,
                              alignment: Alignment.bottomCenter,
                              child: connected && sessionId != null && !(chat?.controlReady ?? true)
                                  ? Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: ErrorBanner(
                                        maxLines: null,
                                        info: !(chat?.streamLost ?? false),
                                        message: chat?.streamLost ?? false
                                            ? chat?.syncError ?? l10n.stateChatSyncInterrupted
                                            : l10n.stateChatSynchronizing,
                                        action: chat?.resyncing ?? false
                                            ? null
                                            : (
                                                label: l10n.stateChatSyncRetry,
                                                onPressed: () {
                                                  unawaited(ref.read(chatProvider(sessionId).notifier).resync());
                                                },
                                              ),
                                      ),
                                    )
                                  : error == null && notice == null
                                  ? const SizedBox(width: double.infinity)
                                  : notice != null
                                  ? Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: ErrorBanner(
                                        info: true,
                                        message: notice,
                                        onDismiss: () => ref.read(chatProvider(sessionId!).notifier).dismissNotice(),
                                      ),
                                    )
                                  : Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: ErrorBanner(
                                        message: error!,
                                        onDismiss: () {
                                          if (sessionId == null) {
                                            setState(() => _localError = null);
                                          } else if (modelDefaultWarning) {
                                            ref.read(chatProvider(sessionId).notifier).dismissDefaultModelSaveWarning();
                                          } else {
                                            ref.read(chatProvider(sessionId).notifier).dismissError();
                                          }
                                        },
                                      ),
                                    ),
                            ),
                            if (connected && sessionId != null)
                              UnknownResultsBanner(sessionId: sessionId, padding: const EdgeInsets.only(bottom: 8)),
                            SmoothSize(
                              duration: AppMotion.of(context, AppMotion.standard),
                              curve: AppMotion.std,
                              alignment: Alignment.bottomLeft,
                              child: switch (composerPills) {
                                final pill? => Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Align(alignment: Alignment.centerLeft, child: pill),
                                ),
                                null => const SizedBox(width: double.infinity),
                              },
                            ),
                            _DockAside(
                              aside: typing,
                              child: BackdropGroup(
                                child: DockStack(
                                  cards: [
                                    if (sessionId != null) ...[
                                      TodoDockSlot(sessionId: sessionId),
                                      GoalDockSlot(sessionId: sessionId),
                                      ActivityStripSlot(
                                        sessionId: sessionId,
                                        onTap: () => _openRunningTrajectory(sessionId),
                                        todoProgress: ref.watch(dockFoldedProvider),
                                      ),
                                    ],
                                  ],
                                  accessory: pillsBesideStrip
                                      ? _stripRisk(sessionId, autoApprove: chat?.autoApprove ?? false)
                                      : null,
                                ),
                              ),
                            ),
                            if (readOnly)
                              const ReadOnlyBar()
                            else
                              Composer(
                                hardwareEnterSends: ref.watch(settingsProvider.select((s) => s.hardwareEnterSends)),
                                controller: _input,
                                groupId: _composerGroup,
                                maxLines: Composer.linesFor(context),
                                focusNode: _focus,
                                connected: connected,
                                running: chat?.running ?? false,
                                stopping: chat?.stopping ?? false,
                                sessionReady: chat?.controlReady ?? true,
                                busy: _creating != null || _syncWait != null,
                                waiting: approval != null || question != null,
                                modeLabel: question == null
                                    ? null
                                    : answerInComposer
                                    ? l10n.chatAnswerMode
                                    : l10n.chatMessageMode,
                                waitHint: approval != null
                                    ? null
                                    : answerInComposer
                                    ? l10n.chatAnswerHint
                                    : question != null
                                    ? l10n.commonWaitingAnswer
                                    : null,
                                onSend: _send,
                                onSendOptions: chat?.controlReady ?? true ? _sendOptions : null,
                                onKeyEvent: _composerKey,
                                onContentInserted: connected ? _pasteContent : null,
                                onStop: _stop,
                                hasAttachments: _drafts.isNotEmpty,
                                leading: AttachButton(onPressed: connected ? _attach : null),
                                keyboardInset: MediaQuery.viewInsetsOf(context).bottom,
                                footer: _composerOpens(context) && !isChild
                                    ? ComposerModelPill(
                                        selection: sessionId == null ? pendingModel : chat?.model,
                                        onSelected: _modelTarget(),
                                      )
                                    : null,
                                tray: ComposerTrayStack.maybe(
                                  quote: switch (quote) {
                                    final quote? => QuoteChip(
                                      quote: quote,
                                      onRemove: () => ref.read(composerQuoteProvider.notifier).clear(_draftKey),
                                    ),
                                    null => null,
                                  },
                                  attachments: _drafts.isEmpty
                                      ? null
                                      : ComposerTray(items: _drafts, onRemove: _removeDraft),
                                ),
                                accessory: sessionId == null || contextFraction == null
                                    ? null
                                    : ContextRing(
                                        fraction: contextFraction,
                                        onTap: () => _openUsage(sessionId, chat?.model),
                                      ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return UiTrace(scope: 'chat', child: screen);
  }

  Widget? _composerPills(String? sessionId, {required bool autoApprove, bool risk = true}) {
    if (!risk || sessionId == null) return null;
    if (autoApprove) {
      return AutoApprovePill(onDisable: () => ref.read(chatProvider(sessionId).notifier).setAutoApprove(false));
    }
    final preset = ref.watch(sessionModesProvider(sessionId).select((m) => m.risky ? m.preset : null));
    return preset == null
        ? null
        : PermissionPill(preset: preset, onTap: () => unawaited(showPermissionSheet(context, sessionId)));
  }

  /// 「自动允许中」/「完全权限」 beside the activity strip while a reply generates.
  Widget? _stripRisk(String sessionId, {required bool autoApprove}) {
    if (autoApprove) {
      return StripRiskChip.autoApprove(
        context,
        onDisable: () => ref.read(chatProvider(sessionId).notifier).setAutoApprove(false),
      );
    }
    final risky = ref.watch(sessionModesProvider(sessionId).select((m) => m.risky ? m.preset : null));
    if (risky == null) return null;
    return StripRiskChip.permission(
      context,
      preset: risky,
      onTap: () => unawaited(showPermissionSheet(context, sessionId)),
    );
  }

  /// The activity strip: the running turn's trajectory.
  void _openRunningTrajectory(String sessionId) {
    final turn = ref.read(chatProvider(sessionId)).runningTurn?.turn;
    if (turn == null) return;
    showTrajectorySheet(context, sessionId: sessionId, turn: turn);
  }

  static HeaderStatus _status({
    required bool connecting,
    required bool starting,
    required bool connected,
    String? idleLabel,
    required bool streamLost,
    required bool syncing,
    required String label,
    required DshConnectionState? connection,
    required bool running,
    required bool stopping,
    required String? waiting,
    String? spoken,
  }) {
    if (!connected) {
      if (starting) return HeaderStatus(StatusTone.busy, appL10n.chatStarting);
      return connecting
          ? HeaderStatus(StatusTone.busy, appL10n.chatConnecting)
          : HeaderStatus(StatusTone.idle, idleLabel ?? appL10n.commonNotConnected);
    }
    if (streamLost) {
      return HeaderStatus(StatusTone.error, appL10n.chatDisconnected);
    }
    switch (connection) {
      case DshConnectionState.reconnecting || DshConnectionState.connecting:
        return HeaderStatus(StatusTone.warn, appL10n.chatReconnecting);
      case DshConnectionState.unauthorized || DshConnectionState.closed:
        return HeaderStatus(StatusTone.error, appL10n.chatDisconnected);
      default:
        break;
    }
    if (syncing) return HeaderStatus(StatusTone.busy, appL10n.stateChatSynchronizing);
    if (stopping) return HeaderStatus(StatusTone.busy, appL10n.commonStopping);
    if (waiting != null) {
      return HeaderStatus(StatusTone.warn, waiting, spoken: spoken);
    }
    if (running) {
      return HeaderStatus(StatusTone.busy, appL10n.chatGenerating, spoken: spoken);
    }
    return HeaderStatus(StatusTone.ok, label, spoken: spoken);
  }
}

/// The dock (todo / goal bars, the run strip) folding toward the composer
/// while a phone on its side types ([aside]).
///
/// Nothing but pass-through boxes at rest (no clip, no layer): the bars'
/// shadows and shared glass stay as they are, and the bars stay mounted, so
/// an open checklist is still open when the keyboard goes.
class _DockAside extends StatefulWidget {
  const _DockAside({required this.aside, required this.child});

  final bool aside;
  final Widget child;

  @override
  State<_DockAside> createState() => _DockAsideState();
}

class _DockAsideState extends State<_DockAside> with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(vsync: this, value: widget.aside ? 0 : 1);
  late final Animation<double> _height = CurvedAnimation(parent: _shown, curve: AppMotion.std);

  @override
  void didUpdateWidget(_DockAside oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.aside == oldWidget.aside) return;
    _shown.duration = AppMotion.of(context, AppMotion.standard);
    if (widget.aside) {
      _shown.reverse();
    } else {
      _shown.forward();
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _height,
    child: widget.child,
    builder: (context, child) {
      final t = _height.value;
      return IgnorePointer(
        ignoring: widget.aside,
        child: ExcludeSemantics(
          excluding: t == 0,
          child: TickerMode(
            enabled: t > 0,
            child: Align(
              alignment: Alignment.bottomCenter,
              heightFactor: t,
              // Gone before the space closes, so nothing shows over the
              // chat while it folds.
              child: Opacity(opacity: ((t - 0.4) / 0.6).clamp(0.0, 1.0), child: child),
            ),
          ),
        ),
      );
    },
  );
}

/// The header, stepping aside ([aside]) for the keyboard on a phone on its
/// side: it fades and lifts away, and a plain fade under the status bar
/// takes its place so the chat scrolling up there still reads cleanly.
class _HeaderAside extends StatelessWidget {
  const _HeaderAside({required this.aside, required this.child});

  final bool aside;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    return Stack(
      // The header's own fade runs past its bar.
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: aside ? 1 : 0,
              duration: duration,
              curve: AppMotion.std,
              child: TopFade(height: MediaQuery.paddingOf(context).top + 12),
            ),
          ),
        ),
        IgnorePointer(
          ignoring: aside,
          child: ExcludeSemantics(
            excluding: aside,
            child: AnimatedSlide(
              offset: aside ? const Offset(0, -0.2) : Offset.zero,
              duration: duration,
              curve: AppMotion.std,
              child: AnimatedOpacity(opacity: aside ? 0 : 1, duration: duration, curve: AppMotion.std, child: child),
            ),
          ),
        ),
      ],
    );
  }
}

enum _Slot { body, pluginOverlay, veil, header, palette, composer }

/// 整页布局:先排输入条区域,挂在它上沿的东西(列表的下沿、底色遮罩、
/// 斜杠面板)在同一次布局里跟上。
///
/// 不走「帧后报高度、下一帧再 setState」:那样胶囊升起 / 收回的每一帧列表
/// 都晚一拍,最后一条消息和胶囊之间时而压住、时而露出一道缝。
class _ChatLayout extends MultiChildLayoutDelegate {
  _ChatLayout(this.veilHeight);

  /// 列表视口伸到输入条上沿以下的距离:底色在那里已经是实心,看不见裁切。
  static const overlap = 6.0;

  /// 斜杠面板离屏幕两边、离输入条上沿的距离。
  static const _side = 12.0;
  static const _gap = 6.0;

  /// 写给底色遮罩:从输入条上沿往下 [overlap] 起实心,到页面底。遮罩在
  /// 布局之后才画,这一帧就按新高度画。
  final ValueNotifier<double> veilHeight;

  @override
  void performLayout(Size size) {
    final width = size.width;
    // Height unbounded, as under a bottom-anchored Positioned: the slots
    // shrink-wrap their content (their Centers would fill a bounded height).
    final along = BoxConstraints(minWidth: width, maxWidth: width);
    final composer = layoutChild(_Slot.composer, along);
    final top = size.height - composer.height;
    positionChild(_Slot.composer, Offset(0, top));
    veilHeight.value = math.max(0, composer.height - overlap);

    layoutChild(_Slot.body, BoxConstraints.tight(Size(width, math.max(0, top + overlap))));
    positionChild(_Slot.body, Offset.zero);
    layoutChild(_Slot.veil, BoxConstraints.tight(size));
    positionChild(_Slot.veil, Offset.zero);
    final header = layoutChild(_Slot.header, along);
    positionChild(_Slot.header, Offset.zero);
    // Web content cannot paint or receive touches on native navigation/input.
    layoutChild(_Slot.pluginOverlay, BoxConstraints.tight(Size(width, math.max(0, top - header.height))));
    positionChild(_Slot.pluginOverlay, Offset(0, header.height));

    final paletteWidth = math.max(0.0, width - 2 * _side);
    final palette = layoutChild(_Slot.palette, BoxConstraints(minWidth: paletteWidth, maxWidth: paletteWidth));
    positionChild(_Slot.palette, Offset(_side, top - _gap - palette.height));
    if (uiTraceEnabled) {
      uiTrace('chat', 'slots', {
        'width': size.width,
        'height': size.height,
        'composerHeight': composer.height,
        'composerTop': top,
        'bodyHeight': math.max(0, top + overlap),
        'paletteHeight': palette.height,
      });
    }
  }

  @override
  bool shouldRelayout(_ChatLayout oldDelegate) => oldDelegate.veilHeight != veilHeight;
}

/// Applies the 对话字号 setting to chat content only (header and composer
/// keep the system size), on top of the system font scale.
class _ChatTextScale extends ConsumerWidget {
  const _ChatTextScale({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final factor = ref.watch(settingsProvider.select((s) => s.chatTextScale));
    if (factor == 1.0) return child;
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: _ChatScaler(media.textScaler, factor)),
      child: child,
    );
  }
}

/// The chat size on top of the system's: Android 14 scales large text less
/// than small, and that curve is kept.
class _ChatScaler extends TextScaler {
  const _ChatScaler(this.base, this.factor);
  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(1);

  @override
  bool operator ==(Object other) => other is _ChatScaler && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}
