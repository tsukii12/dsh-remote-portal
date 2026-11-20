import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of L10n
/// returned by `L10n.of(context)`.
///
/// Applications need to include `L10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: L10n.localizationsDelegates,
///   supportedLocales: L10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the L10n.supportedLocales
/// property.
abstract class L10n {
  L10n(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static L10n of(BuildContext context) {
    return Localizations.of<L10n>(context, L10n)!;
  }

  static const LocalizationsDelegate<L10n> delegate = _L10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en'), Locale('zh')];

  /// No description provided for @activityThinkingUntangle.
  ///
  /// In zh, this message translates to:
  /// **'嗯…让我捋捋'**
  String get activityThinkingUntangle;

  /// No description provided for @activityThinkingWorkThrough.
  ///
  /// In zh, this message translates to:
  /// **'盘一下盘一下'**
  String get activityThinkingWorkThrough;

  /// No description provided for @activityThinkingGears.
  ///
  /// In zh, this message translates to:
  /// **'大脑转起来了'**
  String get activityThinkingGears;

  /// No description provided for @activityThinkingSecond.
  ///
  /// In zh, this message translates to:
  /// **'给我一秒'**
  String get activityThinkingSecond;

  /// No description provided for @activityThinkingSmoking.
  ///
  /// In zh, this message translates to:
  /// **'脑子在冒烟'**
  String get activityThinkingSmoking;

  /// No description provided for @activityThinkingOnIt.
  ///
  /// In zh, this message translates to:
  /// **'想呢想呢'**
  String get activityThinkingOnIt;

  /// No description provided for @activityThinkingNoRush.
  ///
  /// In zh, this message translates to:
  /// **'别催别催'**
  String get activityThinkingNoRush;

  /// No description provided for @activityThinkingPonder.
  ///
  /// In zh, this message translates to:
  /// **'让我琢磨下'**
  String get activityThinkingPonder;

  /// No description provided for @activityThinkingLogic.
  ///
  /// In zh, this message translates to:
  /// **'正在盘逻辑'**
  String get activityThinkingLogic;

  /// No description provided for @activityThinkingBrain.
  ///
  /// In zh, this message translates to:
  /// **'小脑瓜动一下'**
  String get activityThinkingBrain;

  /// No description provided for @activityThinkingSort.
  ///
  /// In zh, this message translates to:
  /// **'让我理理'**
  String get activityThinkingSort;

  /// No description provided for @activityThinkingMemory.
  ///
  /// In zh, this message translates to:
  /// **'翻翻脑子'**
  String get activityThinkingMemory;

  /// No description provided for @activityThinkingStorm.
  ///
  /// In zh, this message translates to:
  /// **'脑内风暴中'**
  String get activityThinkingStorm;

  /// No description provided for @activityThinkingSavor.
  ///
  /// In zh, this message translates to:
  /// **'嗯…让我品品'**
  String get activityThinkingSavor;

  /// No description provided for @activityThinkingMoment.
  ///
  /// In zh, this message translates to:
  /// **'稍等，在想'**
  String get activityThinkingMoment;

  /// No description provided for @activityThinkingHeadScratch.
  ///
  /// In zh, this message translates to:
  /// **'挠头…'**
  String get activityThinkingHeadScratch;

  /// No description provided for @activityThinkingPlayOut.
  ///
  /// In zh, this message translates to:
  /// **'让子弹飞一会'**
  String get activityThinkingPlayOut;

  /// No description provided for @activityThinkingLoading.
  ///
  /// In zh, this message translates to:
  /// **'思路加载中'**
  String get activityThinkingLoading;

  /// No description provided for @activityThinkingMulling.
  ///
  /// In zh, this message translates to:
  /// **'琢磨中'**
  String get activityThinkingMulling;

  /// No description provided for @activityThinkingBreakDown.
  ///
  /// In zh, this message translates to:
  /// **'嗯…让我拆一下'**
  String get activityThinkingBreakDown;

  /// No description provided for @activityThinkingTrain.
  ///
  /// In zh, this message translates to:
  /// **'脑内跑火车'**
  String get activityThinkingTrain;

  /// No description provided for @activityThinkingSomething.
  ///
  /// In zh, this message translates to:
  /// **'嗯…有点东西'**
  String get activityThinkingSomething;

  /// No description provided for @activityThinkingJog.
  ///
  /// In zh, this message translates to:
  /// **'小跑一下思路'**
  String get activityThinkingJog;

  /// No description provided for @activityThinkingPicture.
  ///
  /// In zh, this message translates to:
  /// **'等下，有画面了'**
  String get activityThinkingPicture;

  /// No description provided for @activityThinkingBubbles.
  ///
  /// In zh, this message translates to:
  /// **'思考泡泡'**
  String get activityThinkingBubbles;

  /// No description provided for @activityThinkingWaves.
  ///
  /// In zh, this message translates to:
  /// **'脑电波传输中'**
  String get activityThinkingWaves;

  /// No description provided for @activityThinkingCoffee.
  ///
  /// In zh, this message translates to:
  /// **'脑子在煮咖啡'**
  String get activityThinkingCoffee;

  /// No description provided for @activityThinkingDraft.
  ///
  /// In zh, this message translates to:
  /// **'我打个腹稿'**
  String get activityThinkingDraft;

  /// No description provided for @activityThinkingComing.
  ///
  /// In zh, this message translates to:
  /// **'嗯，来了来了'**
  String get activityThinkingComing;

  /// No description provided for @activityThinkingBubbling.
  ///
  /// In zh, this message translates to:
  /// **'脑子冒泡泡'**
  String get activityThinkingBubbling;

  /// No description provided for @activityThinkingTackle.
  ///
  /// In zh, this message translates to:
  /// **'嗯…盘它'**
  String get activityThinkingTackle;

  /// No description provided for @activityThinkingSpark.
  ///
  /// In zh, this message translates to:
  /// **'闪个思路'**
  String get activityThinkingSpark;

  /// No description provided for @activityThinkingLogicFirst.
  ///
  /// In zh, this message translates to:
  /// **'先捋一下逻辑'**
  String get activityThinkingLogicFirst;

  /// No description provided for @activityThinkingLocate.
  ///
  /// In zh, this message translates to:
  /// **'定位一下'**
  String get activityThinkingLocate;

  /// No description provided for @activityThinkingInvestigate.
  ///
  /// In zh, this message translates to:
  /// **'排查一下'**
  String get activityThinkingInvestigate;

  /// No description provided for @activityThinkingGif.
  ///
  /// In zh, this message translates to:
  /// **'思考.gif'**
  String get activityThinkingGif;

  /// No description provided for @activityThinkingLook.
  ///
  /// In zh, this message translates to:
  /// **'让我康康'**
  String get activityThinkingLook;

  /// No description provided for @activityThinkingInteresting.
  ///
  /// In zh, this message translates to:
  /// **'嗯…有点意思'**
  String get activityThinkingInteresting;

  /// No description provided for @activityThinkingHands.
  ///
  /// In zh, this message translates to:
  /// **'搓搓手想想'**
  String get activityThinkingHands;

  /// No description provided for @activityThinkingFiveMinutes.
  ///
  /// In zh, this message translates to:
  /// **'5 分钟，大工程'**
  String get activityThinkingFiveMinutes;

  /// No description provided for @activityThinkingSerious.
  ///
  /// In zh, this message translates to:
  /// **'这把我得认真'**
  String get activityThinkingSerious;

  /// No description provided for @activityThinkingTricky.
  ///
  /// In zh, this message translates to:
  /// **'确实有点绕'**
  String get activityThinkingTricky;

  /// No description provided for @activityThinkingAscend.
  ///
  /// In zh, this message translates to:
  /// **'我在修仙'**
  String get activityThinkingAscend;

  /// No description provided for @activityThinkingAlmostPromise.
  ///
  /// In zh, this message translates to:
  /// **'快好了，真的'**
  String get activityThinkingAlmostPromise;

  /// No description provided for @activityThinkingLongWay.
  ///
  /// In zh, this message translates to:
  /// **'盘了一大圈'**
  String get activityThinkingLongWay;

  /// No description provided for @activityThinkingWrapping.
  ///
  /// In zh, this message translates to:
  /// **'在收尾了'**
  String get activityThinkingWrapping;

  /// No description provided for @activityThinkingSong.
  ///
  /// In zh, this message translates to:
  /// **'给我一首歌的时间'**
  String get activityThinkingSong;

  /// No description provided for @activityThinkingBigMove.
  ///
  /// In zh, this message translates to:
  /// **'憋大招中'**
  String get activityThinkingBigMove;

  /// No description provided for @activityThinkingSimple.
  ///
  /// In zh, this message translates to:
  /// **'这个需求很简单（不是）'**
  String get activityThinkingSimple;

  /// No description provided for @activityThinkingOneMinute.
  ///
  /// In zh, this message translates to:
  /// **'1 分钟，还在想'**
  String get activityThinkingOneMinute;

  /// No description provided for @activityThinkingChallenge.
  ///
  /// In zh, this message translates to:
  /// **'这题有点东西'**
  String get activityThinkingChallenge;

  /// No description provided for @activityThinkingDig.
  ///
  /// In zh, this message translates to:
  /// **'让我再钻研下'**
  String get activityThinkingDig;

  /// No description provided for @activityThinkingNotSimple.
  ///
  /// In zh, this message translates to:
  /// **'问题不简单'**
  String get activityThinkingNotSimple;

  /// No description provided for @activityThinkingDeep.
  ///
  /// In zh, this message translates to:
  /// **'盘得有点深'**
  String get activityThinkingDeep;

  /// No description provided for @activityThinkingBurning.
  ///
  /// In zh, this message translates to:
  /// **'脑细胞在燃烧'**
  String get activityThinkingBurning;

  /// No description provided for @activityThinkingNearlyClear.
  ///
  /// In zh, this message translates to:
  /// **'快盘清了'**
  String get activityThinkingNearlyClear;

  /// No description provided for @activityThinkingTwisty.
  ///
  /// In zh, this message translates to:
  /// **'这个有点绕…'**
  String get activityThinkingTwisty;

  /// No description provided for @activityThinkingWorkout.
  ///
  /// In zh, this message translates to:
  /// **'烧脑中…'**
  String get activityThinkingWorkout;

  /// No description provided for @activityThinkingStay.
  ///
  /// In zh, this message translates to:
  /// **'别走，快了'**
  String get activityThinkingStay;

  /// No description provided for @activityThinkingCloser.
  ///
  /// In zh, this message translates to:
  /// **'嗯，让我细想想'**
  String get activityThinkingCloser;

  /// No description provided for @activityThinkingThirtySeconds.
  ///
  /// In zh, this message translates to:
  /// **'30 秒了，还在盘'**
  String get activityThinkingThirtySeconds;

  /// No description provided for @activityThinkingSoon.
  ///
  /// In zh, this message translates to:
  /// **'别急，快出结果了'**
  String get activityThinkingSoon;

  /// No description provided for @activityThinkingAnotherPass.
  ///
  /// In zh, this message translates to:
  /// **'让我再捋一捋'**
  String get activityThinkingAnotherPass;

  /// No description provided for @activityThinkingTrack.
  ///
  /// In zh, this message translates to:
  /// **'思路没断'**
  String get activityThinkingTrack;

  /// No description provided for @activityThinkingLead.
  ///
  /// In zh, this message translates to:
  /// **'有眉目了'**
  String get activityThinkingLead;

  /// No description provided for @activityThinkingCircles.
  ///
  /// In zh, this message translates to:
  /// **'转圈圈…'**
  String get activityThinkingCircles;

  /// No description provided for @activityThinkingAnyMoment.
  ///
  /// In zh, this message translates to:
  /// **'马上马上'**
  String get activityThinkingAnyMoment;

  /// No description provided for @activityThinkingStillLocate.
  ///
  /// In zh, this message translates to:
  /// **'还在定位'**
  String get activityThinkingStillLocate;

  /// No description provided for @activityWaitingCall.
  ///
  /// In zh, this message translates to:
  /// **'呼叫模型…'**
  String get activityWaitingCall;

  /// No description provided for @activityWaitingOnWay.
  ///
  /// In zh, this message translates to:
  /// **'模型在路上了'**
  String get activityWaitingOnWay;

  /// No description provided for @activityWaitingSpeak.
  ///
  /// In zh, this message translates to:
  /// **'等它开口…'**
  String get activityWaitingSpeak;

  /// No description provided for @activityWaitingWords.
  ///
  /// In zh, this message translates to:
  /// **'它在组织语言'**
  String get activityWaitingWords;

  /// No description provided for @activityWaitingAwake.
  ///
  /// In zh, this message translates to:
  /// **'模型醒了么'**
  String get activityWaitingAwake;

  /// No description provided for @activityWaitingStretch.
  ///
  /// In zh, this message translates to:
  /// **'等它伸懒腰'**
  String get activityWaitingStretch;

  /// No description provided for @activityWaitingYawn.
  ///
  /// In zh, this message translates to:
  /// **'它打了个哈欠'**
  String get activityWaitingYawn;

  /// No description provided for @activityWaitingComing.
  ///
  /// In zh, this message translates to:
  /// **'模型：来了来了'**
  String get activityWaitingComing;

  /// No description provided for @activityWaitingText.
  ///
  /// In zh, this message translates to:
  /// **'等它出字'**
  String get activityWaitingText;

  /// No description provided for @activityWaitingQueue.
  ///
  /// In zh, this message translates to:
  /// **'还在排队'**
  String get activityWaitingQueue;

  /// No description provided for @activityWaitingBrew.
  ///
  /// In zh, this message translates to:
  /// **'它在酝酿'**
  String get activityWaitingBrew;

  /// No description provided for @activityWaitingWater.
  ///
  /// In zh, this message translates to:
  /// **'模型在喝水'**
  String get activityWaitingWater;

  /// No description provided for @activityWaitingWarmup.
  ///
  /// In zh, this message translates to:
  /// **'等它热身'**
  String get activityWaitingWarmup;

  /// No description provided for @activityWaitingMeditate.
  ///
  /// In zh, this message translates to:
  /// **'模型在冥想'**
  String get activityWaitingMeditate;

  /// No description provided for @activityWaitingBlink.
  ///
  /// In zh, this message translates to:
  /// **'等它眨个眼'**
  String get activityWaitingBlink;

  /// No description provided for @activityWaitingMoment.
  ///
  /// In zh, this message translates to:
  /// **'它说稍等'**
  String get activityWaitingMoment;

  /// No description provided for @activityWritingWords.
  ///
  /// In zh, this message translates to:
  /// **'组织语言中'**
  String get activityWritingWords;

  /// No description provided for @activityWritingTyping.
  ///
  /// In zh, this message translates to:
  /// **'码字中'**
  String get activityWritingTyping;

  /// No description provided for @activityWritingInspired.
  ///
  /// In zh, this message translates to:
  /// **'下笔如有神'**
  String get activityWritingInspired;

  /// No description provided for @activityWritingOnIt.
  ///
  /// In zh, this message translates to:
  /// **'在写了在写了'**
  String get activityWritingOnIt;

  /// No description provided for @activityWritingCareful.
  ///
  /// In zh, this message translates to:
  /// **'字斟句酌'**
  String get activityWritingCareful;

  /// No description provided for @activityWritingFlow.
  ///
  /// In zh, this message translates to:
  /// **'一气呵成'**
  String get activityWritingFlow;

  /// No description provided for @activityWritingPlain.
  ///
  /// In zh, this message translates to:
  /// **'整理成人话'**
  String get activityWritingPlain;

  /// No description provided for @activityWritingIdeas.
  ///
  /// In zh, this message translates to:
  /// **'把想法写下来'**
  String get activityWritingIdeas;

  /// No description provided for @activityWritingKeys.
  ///
  /// In zh, this message translates to:
  /// **'敲字中'**
  String get activityWritingKeys;

  /// No description provided for @activityWritingAlmost.
  ///
  /// In zh, this message translates to:
  /// **'马上写完'**
  String get activityWritingAlmost;

  /// No description provided for @activityWritingTell.
  ///
  /// In zh, this message translates to:
  /// **'娓娓道来'**
  String get activityWritingTell;

  /// No description provided for @activityWritingFast.
  ///
  /// In zh, this message translates to:
  /// **'奋笔疾书'**
  String get activityWritingFast;

  /// No description provided for @activityWritingBreeze.
  ///
  /// In zh, this message translates to:
  /// **'笔下生风'**
  String get activityWritingBreeze;

  /// No description provided for @activityWritingFormat.
  ///
  /// In zh, this message translates to:
  /// **'排个版'**
  String get activityWritingFormat;

  /// No description provided for @activityNightAscend.
  ///
  /// In zh, this message translates to:
  /// **'修仙中…'**
  String get activityNightAscend;

  /// No description provided for @activityNightHello.
  ///
  /// In zh, this message translates to:
  /// **'深夜冒泡'**
  String get activityNightHello;

  /// No description provided for @activityNightOwl.
  ///
  /// In zh, this message translates to:
  /// **'你也是夜猫子呀'**
  String get activityNightOwl;

  /// No description provided for @activityNightMoon.
  ///
  /// In zh, this message translates to:
  /// **'月亮不睡我不睡'**
  String get activityNightMoon;

  /// No description provided for @activityNightSlow.
  ///
  /// In zh, this message translates to:
  /// **'夜里脑子慢，谅解'**
  String get activityNightSlow;

  /// No description provided for @activityNightChampion.
  ///
  /// In zh, this message translates to:
  /// **'熬夜冠军上线'**
  String get activityNightChampion;

  /// No description provided for @activityNightSleepy.
  ///
  /// In zh, this message translates to:
  /// **'困了，但能行'**
  String get activityNightSleepy;

  /// No description provided for @activityNightMidnight.
  ///
  /// In zh, this message translates to:
  /// **'过了零点照样肝'**
  String get activityNightMidnight;

  /// No description provided for @activityNightOpen.
  ///
  /// In zh, this message translates to:
  /// **'深夜档营业'**
  String get activityNightOpen;

  /// No description provided for @activityNightStars.
  ///
  /// In zh, this message translates to:
  /// **'星星都睡了'**
  String get activityNightStars;

  /// No description provided for @activityNightDawn.
  ///
  /// In zh, this message translates to:
  /// **'凌晨还在盘'**
  String get activityNightDawn;

  /// No description provided for @activityWeekendChill.
  ///
  /// In zh, this message translates to:
  /// **'周末摸鱼中'**
  String get activityWeekendChill;

  /// No description provided for @activityWeekendHere.
  ///
  /// In zh, this message translates to:
  /// **'周末也在！'**
  String get activityWeekendHere;

  /// No description provided for @activityWeekendCompany.
  ///
  /// In zh, this message translates to:
  /// **'放假也陪你'**
  String get activityWeekendCompany;

  /// No description provided for @activityWeekendOnline.
  ///
  /// In zh, this message translates to:
  /// **'周末不关机'**
  String get activityWeekendOnline;

  /// No description provided for @activityWeekendSneak.
  ///
  /// In zh, this message translates to:
  /// **'周末偷着盘'**
  String get activityWeekendSneak;

  /// No description provided for @activityWeekendWorking.
  ///
  /// In zh, this message translates to:
  /// **'周末也在卷？'**
  String get activityWeekendWorking;

  /// No description provided for @activityWeekendMode.
  ///
  /// In zh, this message translates to:
  /// **'周末模式 ON'**
  String get activityWeekendMode;

  /// No description provided for @activityWeekendBugs.
  ///
  /// In zh, this message translates to:
  /// **'周末在修 bug'**
  String get activityWeekendBugs;

  /// No description provided for @activityWeekendSkin.
  ///
  /// In zh, this message translates to:
  /// **'周末限定皮肤'**
  String get activityWeekendSkin;

  /// No description provided for @activityNewYearCheers.
  ///
  /// In zh, this message translates to:
  /// **'新年快乐！'**
  String get activityNewYearCheers;

  /// No description provided for @activityNewYearDay.
  ///
  /// In zh, this message translates to:
  /// **'元旦快乐'**
  String get activityNewYearDay;

  /// No description provided for @activityNewYearBugs.
  ///
  /// In zh, this message translates to:
  /// **'新的一年，新的 bug'**
  String get activityNewYearBugs;

  /// No description provided for @activityNewYearFirstLine.
  ///
  /// In zh, this message translates to:
  /// **'新年第一行代码'**
  String get activityNewYearFirstLine;

  /// No description provided for @activityNewYearWork.
  ///
  /// In zh, this message translates to:
  /// **'开工大吉'**
  String get activityNewYearWork;

  /// No description provided for @activityValentineCode.
  ///
  /// In zh, this message translates to:
  /// **'情人节也在敲代码'**
  String get activityValentineCode;

  /// No description provided for @activityValentineLove.
  ///
  /// In zh, this message translates to:
  /// **'代码才是真爱'**
  String get activityValentineLove;

  /// No description provided for @activityValentineDate.
  ///
  /// In zh, this message translates to:
  /// **'今天不约会？'**
  String get activityValentineDate;

  /// No description provided for @activityValentineKeyboard.
  ///
  /// In zh, this message translates to:
  /// **'键盘就是玫瑰'**
  String get activityValentineKeyboard;

  /// No description provided for @activityPiDay.
  ///
  /// In zh, this message translates to:
  /// **'π 节快乐'**
  String get activityPiDay;

  /// No description provided for @activityPiCircle.
  ///
  /// In zh, this message translates to:
  /// **'今天的圆格外圆'**
  String get activityPiCircle;

  /// No description provided for @activityAprilFools.
  ///
  /// In zh, this message translates to:
  /// **'愚人节快乐'**
  String get activityAprilFools;

  /// No description provided for @activityAprilBug.
  ///
  /// In zh, this message translates to:
  /// **'这个 bug 是假的吧'**
  String get activityAprilBug;

  /// No description provided for @activityAprilErrors.
  ///
  /// In zh, this message translates to:
  /// **'小心假报错'**
  String get activityAprilErrors;

  /// No description provided for @activityAprilKidding.
  ///
  /// In zh, this message translates to:
  /// **'骗你的，没报错'**
  String get activityAprilKidding;

  /// No description provided for @activityLaborWorking.
  ///
  /// In zh, this message translates to:
  /// **'劳动节还在卷'**
  String get activityLaborWorking;

  /// No description provided for @activityLaborPride.
  ///
  /// In zh, this message translates to:
  /// **'劳动最光荣'**
  String get activityLaborPride;

  /// No description provided for @activityLaborSpirit.
  ///
  /// In zh, this message translates to:
  /// **'打工人打工魂'**
  String get activityLaborSpirit;

  /// No description provided for @activityChildrenDay.
  ///
  /// In zh, this message translates to:
  /// **'儿童节快乐'**
  String get activityChildrenDay;

  /// No description provided for @activityChildrenHeart.
  ///
  /// In zh, this message translates to:
  /// **'谁还不是个宝宝'**
  String get activityChildrenHeart;

  /// No description provided for @activityChildrenCode.
  ///
  /// In zh, this message translates to:
  /// **'今天代码要写得可爱'**
  String get activityChildrenCode;

  /// No description provided for @activityProgrammerCheers.
  ///
  /// In zh, this message translates to:
  /// **'1024 程序员节快乐'**
  String get activityProgrammerCheers;

  /// No description provided for @activityProgrammerDay.
  ///
  /// In zh, this message translates to:
  /// **'今天是程序员节'**
  String get activityProgrammerDay;

  /// No description provided for @activityProgrammer1024.
  ///
  /// In zh, this message translates to:
  /// **'1024，节日快乐'**
  String get activityProgrammer1024;

  /// No description provided for @activityProgrammerCode.
  ///
  /// In zh, this message translates to:
  /// **'程序员节也在写代码'**
  String get activityProgrammerCode;

  /// No description provided for @activityHalloween.
  ///
  /// In zh, this message translates to:
  /// **'万圣节快乐'**
  String get activityHalloween;

  /// No description provided for @activityHalloweenTreat.
  ///
  /// In zh, this message translates to:
  /// **'不给糖就捣蛋'**
  String get activityHalloweenTreat;

  /// No description provided for @activityHalloweenCode.
  ///
  /// In zh, this message translates to:
  /// **'代码也会吓人'**
  String get activityHalloweenCode;

  /// No description provided for @activityChristmasEve.
  ///
  /// In zh, this message translates to:
  /// **'平安夜快乐'**
  String get activityChristmasEve;

  /// No description provided for @activityChristmasEveThinking.
  ///
  /// In zh, this message translates to:
  /// **'平安夜也在盘'**
  String get activityChristmasEveThinking;

  /// No description provided for @activityChristmasEveGift.
  ///
  /// In zh, this message translates to:
  /// **'今晚写代码有礼物'**
  String get activityChristmasEveGift;

  /// No description provided for @activityChristmas.
  ///
  /// In zh, this message translates to:
  /// **'圣诞快乐'**
  String get activityChristmas;

  /// No description provided for @activityChristmasCompany.
  ///
  /// In zh, this message translates to:
  /// **'圣诞也陪你'**
  String get activityChristmasCompany;

  /// No description provided for @activityChristmasEgg.
  ///
  /// In zh, this message translates to:
  /// **'圣诞限定彩蛋'**
  String get activityChristmasEgg;

  /// No description provided for @activityChristmasReindeer.
  ///
  /// In zh, this message translates to:
  /// **'麋鹿送代码来了'**
  String get activityChristmasReindeer;

  /// No description provided for @activityYearEndEve.
  ///
  /// In zh, this message translates to:
  /// **'跨年夜'**
  String get activityYearEndEve;

  /// No description provided for @activityYearEndLast.
  ///
  /// In zh, this message translates to:
  /// **'今年最后一盘'**
  String get activityYearEndLast;

  /// No description provided for @activityYearEndReady.
  ///
  /// In zh, this message translates to:
  /// **'准备跨年'**
  String get activityYearEndReady;

  /// No description provided for @activityYearEndSeeYou.
  ///
  /// In zh, this message translates to:
  /// **'明年见！'**
  String get activityYearEndSeeYou;

  /// No description provided for @activityZodiacRat.
  ///
  /// In zh, this message translates to:
  /// **'鼠'**
  String get activityZodiacRat;

  /// No description provided for @activityZodiacOx.
  ///
  /// In zh, this message translates to:
  /// **'牛'**
  String get activityZodiacOx;

  /// No description provided for @activityZodiacTiger.
  ///
  /// In zh, this message translates to:
  /// **'虎'**
  String get activityZodiacTiger;

  /// No description provided for @activityZodiacRabbit.
  ///
  /// In zh, this message translates to:
  /// **'兔'**
  String get activityZodiacRabbit;

  /// No description provided for @activityZodiacDragon.
  ///
  /// In zh, this message translates to:
  /// **'龙'**
  String get activityZodiacDragon;

  /// No description provided for @activityZodiacSnake.
  ///
  /// In zh, this message translates to:
  /// **'蛇'**
  String get activityZodiacSnake;

  /// No description provided for @activityZodiacHorse.
  ///
  /// In zh, this message translates to:
  /// **'马'**
  String get activityZodiacHorse;

  /// No description provided for @activityZodiacGoat.
  ///
  /// In zh, this message translates to:
  /// **'羊'**
  String get activityZodiacGoat;

  /// No description provided for @activityZodiacMonkey.
  ///
  /// In zh, this message translates to:
  /// **'猴'**
  String get activityZodiacMonkey;

  /// No description provided for @activityZodiacRooster.
  ///
  /// In zh, this message translates to:
  /// **'鸡'**
  String get activityZodiacRooster;

  /// No description provided for @activityZodiacDog.
  ///
  /// In zh, this message translates to:
  /// **'狗'**
  String get activityZodiacDog;

  /// No description provided for @activityZodiacPig.
  ///
  /// In zh, this message translates to:
  /// **'猪'**
  String get activityZodiacPig;

  /// No description provided for @activityLunarCheers.
  ///
  /// In zh, this message translates to:
  /// **'春节快乐！'**
  String get activityLunarCheers;

  /// No description provided for @activityLunarCode.
  ///
  /// In zh, this message translates to:
  /// **'过年还在写代码'**
  String get activityLunarCode;

  /// No description provided for @activityLunarEnvelope.
  ///
  /// In zh, this message translates to:
  /// **'红包拿来'**
  String get activityLunarEnvelope;

  /// No description provided for @activityLunarSpring.
  ///
  /// In zh, this message translates to:
  /// **'新春快乐'**
  String get activityLunarSpring;

  /// No description provided for @activityLunarGreeting.
  ///
  /// In zh, this message translates to:
  /// **'过年好'**
  String get activityLunarGreeting;

  /// No description provided for @activityLunarCodeGreeting.
  ///
  /// In zh, this message translates to:
  /// **'代码也拜个年'**
  String get activityLunarCodeGreeting;

  /// No description provided for @activityRareSsr.
  ///
  /// In zh, this message translates to:
  /// **'SSR！稀有彩蛋'**
  String get activityRareSsr;

  /// No description provided for @activityRareUr.
  ///
  /// In zh, this message translates to:
  /// **'UR 掉落'**
  String get activityRareUr;

  /// No description provided for @activityRareLegend.
  ///
  /// In zh, this message translates to:
  /// **'金色传说！'**
  String get activityRareLegend;

  /// No description provided for @activityRareOrange.
  ///
  /// In zh, this message translates to:
  /// **'出橙了'**
  String get activityRareOrange;

  /// No description provided for @activityRareEgg.
  ///
  /// In zh, this message translates to:
  /// **'彩蛋砸脸'**
  String get activityRareEgg;

  /// No description provided for @activityRareChosen.
  ///
  /// In zh, this message translates to:
  /// **'天选时刻'**
  String get activityRareChosen;

  /// No description provided for @activityRareHidden.
  ///
  /// In zh, this message translates to:
  /// **'你发现了隐藏款'**
  String get activityRareHidden;

  /// No description provided for @activityRareChat.
  ///
  /// In zh, this message translates to:
  /// **'触发隐藏对话'**
  String get activityRareChat;

  /// No description provided for @activityRareMax.
  ///
  /// In zh, this message translates to:
  /// **'稀有度 MAX'**
  String get activityRareMax;

  /// No description provided for @activityRareLucky.
  ///
  /// In zh, this message translates to:
  /// **'欧皇降临'**
  String get activityRareLucky;

  /// No description provided for @activityRareCritical.
  ///
  /// In zh, this message translates to:
  /// **'暴击了'**
  String get activityRareCritical;

  /// No description provided for @activityRareNextLevel.
  ///
  /// In zh, this message translates to:
  /// **'这波在大气层'**
  String get activityRareNextLevel;

  /// No description provided for @activityFailCrash.
  ///
  /// In zh, this message translates to:
  /// **'翻车了'**
  String get activityFailCrash;

  /// No description provided for @activityFailOops.
  ///
  /// In zh, this message translates to:
  /// **'哎呀'**
  String get activityFailOops;

  /// No description provided for @activityFailRun.
  ///
  /// In zh, this message translates to:
  /// **'没跑通'**
  String get activityFailRun;

  /// No description provided for @activityFailTrip.
  ///
  /// In zh, this message translates to:
  /// **'摔了一跤'**
  String get activityFailTrip;

  /// No description provided for @activityFailWrong.
  ///
  /// In zh, this message translates to:
  /// **'这不对'**
  String get activityFailWrong;

  /// No description provided for @activityFailHiccup.
  ///
  /// In zh, this message translates to:
  /// **'出岔子了'**
  String get activityFailHiccup;

  /// No description provided for @activityFailBroken.
  ///
  /// In zh, this message translates to:
  /// **'不灵了'**
  String get activityFailBroken;

  /// No description provided for @activityFailLocal.
  ///
  /// In zh, this message translates to:
  /// **'我本地能跑啊'**
  String get activityFailLocal;

  /// No description provided for @activityFailYesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天还能跑'**
  String get activityFailYesterday;

  /// No description provided for @activityFailTough.
  ///
  /// In zh, this message translates to:
  /// **'难绷'**
  String get activityFailTough;

  /// No description provided for @activityFailCrack.
  ///
  /// In zh, this message translates to:
  /// **'裂开'**
  String get activityFailCrack;

  /// No description provided for @activityFailPressure.
  ///
  /// In zh, this message translates to:
  /// **'血压上来了'**
  String get activityFailPressure;

  /// No description provided for @activityFailCareless.
  ///
  /// In zh, this message translates to:
  /// **'这波大意了'**
  String get activityFailCareless;

  /// No description provided for @activityFailSlip.
  ///
  /// In zh, this message translates to:
  /// **'手滑'**
  String get activityFailSlip;

  /// No description provided for @activityFailTryAgain.
  ///
  /// In zh, this message translates to:
  /// **'换个姿势再来'**
  String get activityFailTryAgain;

  /// No description provided for @activityFailChance.
  ///
  /// In zh, this message translates to:
  /// **'再给我一次机会'**
  String get activityFailChance;

  /// No description provided for @activityTestGreen.
  ///
  /// In zh, this message translates to:
  /// **'测试全绿'**
  String get activityTestGreen;

  /// No description provided for @activityTestAllGreen.
  ///
  /// In zh, this message translates to:
  /// **'全绿，舒服'**
  String get activityTestAllGreen;

  /// No description provided for @activityTestFirstTry.
  ///
  /// In zh, this message translates to:
  /// **'一次过！'**
  String get activityTestFirstTry;

  /// No description provided for @activityTestNoErrors.
  ///
  /// In zh, this message translates to:
  /// **'没报错'**
  String get activityTestNoErrors;

  /// No description provided for @activityTestPassed.
  ///
  /// In zh, this message translates to:
  /// **'过了过了'**
  String get activityTestPassed;

  /// No description provided for @activityTestSolid.
  ///
  /// In zh, this message translates to:
  /// **'稳了'**
  String get activityTestSolid;

  /// No description provided for @activityTestRed.
  ///
  /// In zh, this message translates to:
  /// **'红了，看看哪挂了'**
  String get activityTestRed;

  /// No description provided for @activityTestInvestigate.
  ///
  /// In zh, this message translates to:
  /// **'测试挂了，排查一下'**
  String get activityTestInvestigate;

  /// No description provided for @activityTestStubborn.
  ///
  /// In zh, this message translates to:
  /// **'有个用例不服'**
  String get activityTestStubborn;

  /// No description provided for @activityTestFix.
  ///
  /// In zh, this message translates to:
  /// **'红灯，再改改'**
  String get activityTestFix;

  /// No description provided for @activityGitCommitSave.
  ///
  /// In zh, this message translates to:
  /// **'提交了，存个档'**
  String get activityGitCommitSave;

  /// No description provided for @activityGitSaved.
  ///
  /// In zh, this message translates to:
  /// **'存档成功'**
  String get activityGitSaved;

  /// No description provided for @activityGitCommitRelief.
  ///
  /// In zh, this message translates to:
  /// **'commit 一下，安心'**
  String get activityGitCommitRelief;

  /// No description provided for @activityGitPushed.
  ///
  /// In zh, this message translates to:
  /// **'推上去了'**
  String get activityGitPushed;

  /// No description provided for @activityGitPushDone.
  ///
  /// In zh, this message translates to:
  /// **'push 完成，起飞'**
  String get activityGitPushDone;

  /// No description provided for @activityGitCodeOut.
  ///
  /// In zh, this message translates to:
  /// **'代码出门了'**
  String get activityGitCodeOut;

  /// No description provided for @activityInstallDone.
  ///
  /// In zh, this message translates to:
  /// **'依赖装好了'**
  String get activityInstallDone;

  /// No description provided for @activityInstallInternet.
  ///
  /// In zh, this message translates to:
  /// **'下载了半个互联网'**
  String get activityInstallInternet;

  /// No description provided for @activityInstallPackages.
  ///
  /// In zh, this message translates to:
  /// **'包都到齐了'**
  String get activityInstallPackages;

  /// No description provided for @activityMilestoneFive.
  ///
  /// In zh, this message translates to:
  /// **'工具 x5，手感来了'**
  String get activityMilestoneFive;

  /// No description provided for @activityMilestoneTen.
  ///
  /// In zh, this message translates to:
  /// **'工具连击 x10'**
  String get activityMilestoneTen;

  /// No description provided for @activityMilestoneTwenty.
  ///
  /// In zh, this message translates to:
  /// **'工具 x20，停不下来'**
  String get activityMilestoneTwenty;

  /// No description provided for @activityMilestoneFifty.
  ///
  /// In zh, this message translates to:
  /// **'工具 x50，劳模本模'**
  String get activityMilestoneFifty;

  /// No description provided for @activityRetryWait.
  ///
  /// In zh, this message translates to:
  /// **'稍等，重试中'**
  String get activityRetryWait;

  /// No description provided for @activityRetryBackoff.
  ///
  /// In zh, this message translates to:
  /// **'刚被拒了，退避一下'**
  String get activityRetryBackoff;

  /// No description provided for @activityRetryKnock.
  ///
  /// In zh, this message translates to:
  /// **'再敲一次门'**
  String get activityRetryKnock;

  /// No description provided for @activityRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'被限流了，缓缓再试'**
  String get activityRateLimited;

  /// No description provided for @activityRate429.
  ///
  /// In zh, this message translates to:
  /// **'429 了，歇口气再来'**
  String get activityRate429;

  /// No description provided for @activityRateQueue.
  ///
  /// In zh, this message translates to:
  /// **'排队的人有点多'**
  String get activityRateQueue;

  /// No description provided for @activityCompactContext.
  ///
  /// In zh, this message translates to:
  /// **'收拾一下上下文…'**
  String get activityCompactContext;

  /// No description provided for @activityCompactBag.
  ///
  /// In zh, this message translates to:
  /// **'整理背包中…'**
  String get activityCompactBag;

  /// No description provided for @activityCompactSpace.
  ///
  /// In zh, this message translates to:
  /// **'腾地方中'**
  String get activityCompactSpace;

  /// No description provided for @activityCompactMemory.
  ///
  /// In zh, this message translates to:
  /// **'给记忆瘦个身'**
  String get activityCompactMemory;

  /// No description provided for @activityCompactChats.
  ///
  /// In zh, this message translates to:
  /// **'打包旧对话'**
  String get activityCompactChats;

  /// No description provided for @activityReminderWater.
  ///
  /// In zh, this message translates to:
  /// **'半小时了，喝口水？'**
  String get activityReminderWater;

  /// No description provided for @activityReminderTenMinutes.
  ///
  /// In zh, this message translates to:
  /// **'10 分钟了，这活不小'**
  String get activityReminderTenMinutes;

  /// No description provided for @activityDiffTitle.
  ///
  /// In zh, this message translates to:
  /// **'本轮改动'**
  String get activityDiffTitle;

  /// No description provided for @activityDiffCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制补丁'**
  String get activityDiffCopied;

  /// No description provided for @activityDiffNoWrap.
  ///
  /// In zh, this message translates to:
  /// **'不换行'**
  String get activityDiffNoWrap;

  /// No description provided for @activityDiffWrap.
  ///
  /// In zh, this message translates to:
  /// **'自动换行'**
  String get activityDiffWrap;

  /// No description provided for @activityDiffCopy.
  ///
  /// In zh, this message translates to:
  /// **'复制补丁'**
  String get activityDiffCopy;

  /// No description provided for @activityDiffEmpty.
  ///
  /// In zh, this message translates to:
  /// **'空文件，没有可显示的改动'**
  String get activityDiffEmpty;

  /// No description provided for @activityDiffNewFile.
  ///
  /// In zh, this message translates to:
  /// **'新建文件'**
  String get activityDiffNewFile;

  /// No description provided for @activityDiffUnknownLines.
  ///
  /// In zh, this message translates to:
  /// **'行号未知'**
  String get activityDiffUnknownLines;

  /// No description provided for @activityDiffCopyPath.
  ///
  /// In zh, this message translates to:
  /// **'复制路径'**
  String get activityDiffCopyPath;

  /// No description provided for @activityThinking.
  ///
  /// In zh, this message translates to:
  /// **'思考'**
  String get activityThinking;

  /// No description provided for @activityReplyInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'回复（已中断）'**
  String get activityReplyInterrupted;

  /// No description provided for @activityWaitingApproval.
  ///
  /// In zh, this message translates to:
  /// **'等待确认'**
  String get activityWaitingApproval;

  /// No description provided for @activityWaitingAnswer.
  ///
  /// In zh, this message translates to:
  /// **'等待回答'**
  String get activityWaitingAnswer;

  /// No description provided for @activityWriting.
  ///
  /// In zh, this message translates to:
  /// **'写回复中'**
  String get activityWriting;

  /// No description provided for @activityThinkingNow.
  ///
  /// In zh, this message translates to:
  /// **'思考中'**
  String get activityThinkingNow;

  /// No description provided for @activityRetrying.
  ///
  /// In zh, this message translates to:
  /// **'重试中'**
  String get activityRetrying;

  /// No description provided for @activityCompacting.
  ///
  /// In zh, this message translates to:
  /// **'压缩上下文'**
  String get activityCompacting;

  /// No description provided for @activityVerbRun.
  ///
  /// In zh, this message translates to:
  /// **'跑'**
  String get activityVerbRun;

  /// No description provided for @activityVerbWrite.
  ///
  /// In zh, this message translates to:
  /// **'写'**
  String get activityVerbWrite;

  /// No description provided for @activityVerbEdit.
  ///
  /// In zh, this message translates to:
  /// **'改'**
  String get activityVerbEdit;

  /// No description provided for @activityVerbImage.
  ///
  /// In zh, this message translates to:
  /// **'看图'**
  String get activityVerbImage;

  /// No description provided for @activityVerbRead.
  ///
  /// In zh, this message translates to:
  /// **'读'**
  String get activityVerbRead;

  /// No description provided for @activityVerbFind.
  ///
  /// In zh, this message translates to:
  /// **'找'**
  String get activityVerbFind;

  /// No description provided for @activityVerbSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜'**
  String get activityVerbSearch;

  /// No description provided for @activityVerbWebSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜网页'**
  String get activityVerbWebSearch;

  /// No description provided for @activityVerbWebView.
  ///
  /// In zh, this message translates to:
  /// **'看网页'**
  String get activityVerbWebView;

  /// No description provided for @activityVerbSubagent.
  ///
  /// In zh, this message translates to:
  /// **'派子代理'**
  String get activityVerbSubagent;

  /// No description provided for @activityVerbTodo.
  ///
  /// In zh, this message translates to:
  /// **'更新待办'**
  String get activityVerbTodo;

  /// No description provided for @activitySecretHide.
  ///
  /// In zh, this message translates to:
  /// **'隐藏密钥'**
  String get activitySecretHide;

  /// No description provided for @activitySecretShow.
  ///
  /// In zh, this message translates to:
  /// **'显示密钥'**
  String get activitySecretShow;

  /// No description provided for @activitySlashNoMatch.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配的指令，按普通消息发送'**
  String get activitySlashNoMatch;

  /// No description provided for @activitySlashCommands.
  ///
  /// In zh, this message translates to:
  /// **'指令'**
  String get activitySlashCommands;

  /// No description provided for @activitySlashEnterArgs.
  ///
  /// In zh, this message translates to:
  /// **'输入参数后发送'**
  String get activitySlashEnterArgs;

  /// No description provided for @activitySlashRunIntent.
  ///
  /// In zh, this message translates to:
  /// **'命令 · 执行'**
  String get activitySlashRunIntent;

  /// No description provided for @activitySlashInsertIntent.
  ///
  /// In zh, this message translates to:
  /// **'命令 · 填入'**
  String get activitySlashInsertIntent;

  /// No description provided for @activitySlashSkillIntent.
  ///
  /// In zh, this message translates to:
  /// **'技能 · 填入'**
  String get activitySlashSkillIntent;

  /// No description provided for @activityStepTitle.
  ///
  /// In zh, this message translates to:
  /// **'步骤详情'**
  String get activityStepTitle;

  /// No description provided for @activityStepMissing.
  ///
  /// In zh, this message translates to:
  /// **'这一步不在已加载的记录里'**
  String get activityStepMissing;

  /// No description provided for @activityStepQuestion.
  ///
  /// In zh, this message translates to:
  /// **'提问'**
  String get activityStepQuestion;

  /// No description provided for @activityStepSuccess.
  ///
  /// In zh, this message translates to:
  /// **'成功'**
  String get activityStepSuccess;

  /// No description provided for @activityStepNeedsPermission.
  ///
  /// In zh, this message translates to:
  /// **'需要授权'**
  String get activityStepNeedsPermission;

  /// No description provided for @activityTools.
  ///
  /// In zh, this message translates to:
  /// **'工具'**
  String get activityTools;

  /// No description provided for @activityStepDispatched.
  ///
  /// In zh, this message translates to:
  /// **'发出'**
  String get activityStepDispatched;

  /// No description provided for @activityStepExecution.
  ///
  /// In zh, this message translates to:
  /// **'执行'**
  String get activityStepExecution;

  /// No description provided for @activityStepLocation.
  ///
  /// In zh, this message translates to:
  /// **'所在'**
  String get activityStepLocation;

  /// No description provided for @activityStepArguments.
  ///
  /// In zh, this message translates to:
  /// **'参数'**
  String get activityStepArguments;

  /// No description provided for @activityStepChanges.
  ///
  /// In zh, this message translates to:
  /// **'改动'**
  String get activityStepChanges;

  /// No description provided for @activityStepFullScreen.
  ///
  /// In zh, this message translates to:
  /// **'全屏查看'**
  String get activityStepFullScreen;

  /// No description provided for @activityStepReadContent.
  ///
  /// In zh, this message translates to:
  /// **'读到的内容'**
  String get activityStepReadContent;

  /// No description provided for @activityStepWrittenContent.
  ///
  /// In zh, this message translates to:
  /// **'写入的内容'**
  String get activityStepWrittenContent;

  /// No description provided for @activityStepError.
  ///
  /// In zh, this message translates to:
  /// **'错误'**
  String get activityStepError;

  /// No description provided for @activityOutput.
  ///
  /// In zh, this message translates to:
  /// **'输出'**
  String get activityOutput;

  /// No description provided for @activityStepResult.
  ///
  /// In zh, this message translates to:
  /// **'结果'**
  String get activityStepResult;

  /// No description provided for @activityStepDeclined.
  ///
  /// In zh, this message translates to:
  /// **'你拒绝了这次调用'**
  String get activityStepDeclined;

  /// No description provided for @activityStepNoOutput.
  ///
  /// In zh, this message translates to:
  /// **'没有输出'**
  String get activityStepNoOutput;

  /// No description provided for @activityStepStart.
  ///
  /// In zh, this message translates to:
  /// **'开始'**
  String get activityStepStart;

  /// No description provided for @activityDuration.
  ///
  /// In zh, this message translates to:
  /// **'用时'**
  String get activityDuration;

  /// No description provided for @activityFirstToken.
  ///
  /// In zh, this message translates to:
  /// **'首字'**
  String get activityFirstToken;

  /// No description provided for @activityStepGeneration.
  ///
  /// In zh, this message translates to:
  /// **'生成'**
  String get activityStepGeneration;

  /// No description provided for @activityStepSpeed.
  ///
  /// In zh, this message translates to:
  /// **'速度'**
  String get activityStepSpeed;

  /// No description provided for @activityModel.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get activityModel;

  /// No description provided for @activityStepTiming.
  ///
  /// In zh, this message translates to:
  /// **'计时'**
  String get activityStepTiming;

  /// No description provided for @activityUsage.
  ///
  /// In zh, this message translates to:
  /// **'用量'**
  String get activityUsage;

  /// No description provided for @activityInput.
  ///
  /// In zh, this message translates to:
  /// **'输入'**
  String get activityInput;

  /// No description provided for @activityStepCacheHit.
  ///
  /// In zh, this message translates to:
  /// **'  命中缓存'**
  String get activityStepCacheHit;

  /// No description provided for @activityStepCacheMiss.
  ///
  /// In zh, this message translates to:
  /// **'  未命中'**
  String get activityStepCacheMiss;

  /// No description provided for @activityStepCacheWrite.
  ///
  /// In zh, this message translates to:
  /// **'  写入缓存'**
  String get activityStepCacheWrite;

  /// No description provided for @activityStepReasoning.
  ///
  /// In zh, this message translates to:
  /// **'  推理'**
  String get activityStepReasoning;

  /// No description provided for @activityStepAnswer.
  ///
  /// In zh, this message translates to:
  /// **'  回答'**
  String get activityStepAnswer;

  /// No description provided for @activityStepThinking.
  ///
  /// In zh, this message translates to:
  /// **'思考过程'**
  String get activityStepThinking;

  /// No description provided for @activityStepExplanation.
  ///
  /// In zh, this message translates to:
  /// **'说明'**
  String get activityStepExplanation;

  /// No description provided for @activityStepToolCalls.
  ///
  /// In zh, this message translates to:
  /// **'本步调用的工具'**
  String get activityStepToolCalls;

  /// No description provided for @activityStepProcessing.
  ///
  /// In zh, this message translates to:
  /// **'模型正在处理'**
  String get activityStepProcessing;

  /// No description provided for @activityApprovalAllowed.
  ///
  /// In zh, this message translates to:
  /// **'允许了'**
  String get activityApprovalAllowed;

  /// No description provided for @activityApprovalUnanswered.
  ///
  /// In zh, this message translates to:
  /// **'无人确认'**
  String get activityApprovalUnanswered;

  /// No description provided for @activityApprovalAnswered.
  ///
  /// In zh, this message translates to:
  /// **'已答复'**
  String get activityApprovalAnswered;

  /// No description provided for @activityToolRead.
  ///
  /// In zh, this message translates to:
  /// **'读取'**
  String get activityToolRead;

  /// No description provided for @activityToolWrite.
  ///
  /// In zh, this message translates to:
  /// **'写入'**
  String get activityToolWrite;

  /// No description provided for @activityToolCall.
  ///
  /// In zh, this message translates to:
  /// **'调用工具'**
  String get activityToolCall;

  /// No description provided for @activityTraceTitle.
  ///
  /// In zh, this message translates to:
  /// **'本轮轨迹'**
  String get activityTraceTitle;

  /// No description provided for @activityTraceNotLoaded.
  ///
  /// In zh, this message translates to:
  /// **'本轮记录尚未加载'**
  String get activityTraceNotLoaded;

  /// No description provided for @activityTraceOutputLimit.
  ///
  /// In zh, this message translates to:
  /// **'输出达到上限'**
  String get activityTraceOutputLimit;

  /// No description provided for @activityTraceEngineRestarted.
  ///
  /// In zh, this message translates to:
  /// **'引擎重启，已中断'**
  String get activityTraceEngineRestarted;

  /// No description provided for @activityTraceBlocked.
  ///
  /// In zh, this message translates to:
  /// **'已被拦截'**
  String get activityTraceBlocked;

  /// No description provided for @activityTraceHeading.
  ///
  /// In zh, this message translates to:
  /// **'本轮轨迹  '**
  String get activityTraceHeading;

  /// No description provided for @activityTraceWaiting.
  ///
  /// In zh, this message translates to:
  /// **'等你'**
  String get activityTraceWaiting;

  /// No description provided for @activityTraceNoSteps.
  ///
  /// In zh, this message translates to:
  /// **'本轮没有可计时的步骤'**
  String get activityTraceNoSteps;

  /// No description provided for @activityUsageInputIncludesCache.
  ///
  /// In zh, this message translates to:
  /// **'输入含缓存命中'**
  String get activityUsageInputIncludesCache;

  /// No description provided for @activityCacheHit.
  ///
  /// In zh, this message translates to:
  /// **'缓存命中'**
  String get activityCacheHit;

  /// No description provided for @activitySummaryTodo.
  ///
  /// In zh, this message translates to:
  /// **'更新了待办'**
  String get activitySummaryTodo;

  /// No description provided for @activityUsageContext.
  ///
  /// In zh, this message translates to:
  /// **'上下文'**
  String get activityUsageContext;

  /// No description provided for @activityUsageChat.
  ///
  /// In zh, this message translates to:
  /// **'本对话'**
  String get activityUsageChat;

  /// No description provided for @activityUsageWaiting.
  ///
  /// In zh, this message translates to:
  /// **'等待上下文用量数据'**
  String get activityUsageWaiting;

  /// No description provided for @activityUsageProjected.
  ///
  /// In zh, this message translates to:
  /// **'预计下次请求'**
  String get activityUsageProjected;

  /// No description provided for @activityUsageLastRequest.
  ///
  /// In zh, this message translates to:
  /// **'上次请求'**
  String get activityUsageLastRequest;

  /// No description provided for @activityUsageBreakdownEstimate.
  ///
  /// In zh, this message translates to:
  /// **'分项为独立估算，可能与总量不同'**
  String get activityUsageBreakdownEstimate;

  /// No description provided for @activityUsageCumulativeInput.
  ///
  /// In zh, this message translates to:
  /// **'累计输入'**
  String get activityUsageCumulativeInput;

  /// No description provided for @activityUsageContextFull.
  ///
  /// In zh, this message translates to:
  /// **'上下文将满，发送 /compact 可压缩'**
  String get activityUsageContextFull;

  /// No description provided for @activitySpanZero.
  ///
  /// In zh, this message translates to:
  /// **'0 秒'**
  String get activitySpanZero;

  /// No description provided for @activitySpanTiny.
  ///
  /// In zh, this message translates to:
  /// **'<0.1 秒'**
  String get activitySpanTiny;

  /// No description provided for @activityUsageContextSemantics.
  ///
  /// In zh, this message translates to:
  /// **'上下文已用 {percent}，查看用量'**
  String activityUsageContextSemantics(String percent);

  /// No description provided for @activityUsageSystemTokens.
  ///
  /// In zh, this message translates to:
  /// **'系统 {tokens}'**
  String activityUsageSystemTokens(String tokens);

  /// No description provided for @activityUsageToolTokens.
  ///
  /// In zh, this message translates to:
  /// **'工具 {tokens}'**
  String activityUsageToolTokens(String tokens);

  /// No description provided for @activityUsageMessageTokens.
  ///
  /// In zh, this message translates to:
  /// **'消息 {tokens}'**
  String activityUsageMessageTokens(String tokens);

  /// No description provided for @activityUsageTurns.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 轮'**
  String activityUsageTurns(int count);

  /// No description provided for @activityUsageCacheWriteTokens.
  ///
  /// In zh, this message translates to:
  /// **'写入缓存 {tokens}'**
  String activityUsageCacheWriteTokens(String tokens);

  /// No description provided for @activitySummaryCommands.
  ///
  /// In zh, this message translates to:
  /// **'执行 {count} 条命令'**
  String activitySummaryCommands(int count);

  /// No description provided for @activitySummaryEditedFiles.
  ///
  /// In zh, this message translates to:
  /// **'改了 {count} 个文件'**
  String activitySummaryEditedFiles(int count);

  /// No description provided for @activitySummaryReadFiles.
  ///
  /// In zh, this message translates to:
  /// **'读了 {count} 个文件'**
  String activitySummaryReadFiles(int count);

  /// No description provided for @activitySummarySearches.
  ///
  /// In zh, this message translates to:
  /// **'搜索 {count} 次'**
  String activitySummarySearches(int count);

  /// No description provided for @activitySummaryWeb.
  ///
  /// In zh, this message translates to:
  /// **'联网 {count} 次'**
  String activitySummaryWeb(int count);

  /// No description provided for @activitySummarySubagents.
  ///
  /// In zh, this message translates to:
  /// **'调用子代理 {count} 次'**
  String activitySummarySubagents(int count);

  /// No description provided for @activitySummaryOther.
  ///
  /// In zh, this message translates to:
  /// **'其他工具 {count} 次'**
  String activitySummaryOther(int count);

  /// No description provided for @activitySummaryTotal.
  ///
  /// In zh, this message translates to:
  /// **'使用了 {count} 个工具'**
  String activitySummaryTotal(int count);

  /// No description provided for @activityDiffBlockMarker.
  ///
  /// In zh, this message translates to:
  /// **'@@ 第 {index}/{total} 处修改 @@'**
  String activityDiffBlockMarker(int index, int total);

  /// No description provided for @activityDiffEditMarker.
  ///
  /// In zh, this message translates to:
  /// **'第 {index} 次修改（共 {total} 次）'**
  String activityDiffEditMarker(int index, int total);

  /// No description provided for @activityTraceSpanSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{title} {detail}，用时 {duration}'**
  String activityTraceSpanSemantics(String title, String detail, String duration);

  /// No description provided for @activityTraceGroupSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{label}，用时 {duration}'**
  String activityTraceGroupSemantics(String label, String duration);

  /// No description provided for @activityTraceEstimatedCost.
  ///
  /// In zh, this message translates to:
  /// **'{cost}（按官方单价估算）'**
  String activityTraceEstimatedCost(String cost);

  /// No description provided for @activityTraceReasoningTokens.
  ///
  /// In zh, this message translates to:
  /// **'其中推理 {tokens}'**
  String activityTraceReasoningTokens(String tokens);

  /// No description provided for @activityStepPosition.
  ///
  /// In zh, this message translates to:
  /// **'第 {turn} 轮 · 第 {step} 步'**
  String activityStepPosition(int turn, Object step);

  /// No description provided for @activityStepTokenSpeed.
  ///
  /// In zh, this message translates to:
  /// **'{speed} tokens/秒'**
  String activityStepTokenSpeed(String speed);

  /// No description provided for @activityStepRetryCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 次'**
  String activityStepRetryCount(int count);

  /// No description provided for @activityStepTruncated.
  ///
  /// In zh, this message translates to:
  /// **'{text}\n…（仅显示前 {count}k 字，复制可得全文）'**
  String activityStepTruncated(String text, int count);

  /// No description provided for @activityStepLiveElapsed.
  ///
  /// In zh, this message translates to:
  /// **'{elapsed} · 进行中{suffix}'**
  String activityStepLiveElapsed(String elapsed, String suffix);

  /// No description provided for @activityStepCopySection.
  ///
  /// In zh, this message translates to:
  /// **'复制{title}'**
  String activityStepCopySection(String title);

  /// No description provided for @activityStepCopiedSection.
  ///
  /// In zh, this message translates to:
  /// **'已复制{title}'**
  String activityStepCopiedSection(String title);

  /// No description provided for @activitySlashDescriptionArgs.
  ///
  /// In zh, this message translates to:
  /// **'{description} · 输入参数后发送'**
  String activitySlashDescriptionArgs(String description);

  /// No description provided for @activitySpanSecondsText.
  ///
  /// In zh, this message translates to:
  /// **'{seconds} 秒'**
  String activitySpanSecondsText(String seconds);

  /// No description provided for @activitySpanSeconds.
  ///
  /// In zh, this message translates to:
  /// **'{seconds} 秒'**
  String activitySpanSeconds(int seconds);

  /// No description provided for @activitySpanMinutesSeconds.
  ///
  /// In zh, this message translates to:
  /// **'{minutes} 分 {seconds} 秒'**
  String activitySpanMinutesSeconds(int minutes, String seconds);

  /// No description provided for @activitySpanHoursMinutes.
  ///
  /// In zh, this message translates to:
  /// **'{hours} 小时 {minutes} 分'**
  String activitySpanHoursMinutes(int hours, String minutes);

  /// No description provided for @activityCostUnderCent.
  ///
  /// In zh, this message translates to:
  /// **'不到 {symbol}0.01'**
  String activityCostUnderCent(String symbol);

  /// No description provided for @activityCostApprox.
  ///
  /// In zh, this message translates to:
  /// **'约 {symbol}{amount}'**
  String activityCostApprox(String symbol, String amount);

  /// No description provided for @activitySpanRetries.
  ///
  /// In zh, this message translates to:
  /// **'重试 {count} 次'**
  String activitySpanRetries(int count);

  /// No description provided for @activitySpanToolCalls.
  ///
  /// In zh, this message translates to:
  /// **'决定调用 {count} 个工具'**
  String activitySpanToolCalls(int count);

  /// No description provided for @activityRunningItems.
  ///
  /// In zh, this message translates to:
  /// **'等 {count} 项'**
  String activityRunningItems(int count);

  /// No description provided for @activityRetryAttempt.
  ///
  /// In zh, this message translates to:
  /// **'第 {count} 次'**
  String activityRetryAttempt(int count);

  /// No description provided for @activityDiffFileCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个文件'**
  String activityDiffFileCount(int count);

  /// No description provided for @activityDiffFileSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{path}，新增 {added} 行，删除 {removed} 行'**
  String activityDiffFileSemantics(String path, int added, int removed);

  /// No description provided for @activityDiffEditNumber.
  ///
  /// In zh, this message translates to:
  /// **'第 {edit} 次修改'**
  String activityDiffEditNumber(int edit);

  /// No description provided for @activityDiffHunkNumber.
  ///
  /// In zh, this message translates to:
  /// **'第 {index} 处'**
  String activityDiffHunkNumber(int index);

  /// No description provided for @activityDiffFromLine.
  ///
  /// In zh, this message translates to:
  /// **'第 {line} 行起'**
  String activityDiffFromLine(int line);

  /// No description provided for @activityDiffEditCount.
  ///
  /// In zh, this message translates to:
  /// **'修改 {count} 次'**
  String activityDiffEditCount(int count);

  /// No description provided for @activityLunarZodiac.
  ///
  /// In zh, this message translates to:
  /// **'{animal}年大吉'**
  String activityLunarZodiac(String animal);

  /// No description provided for @activityReminderHours.
  ///
  /// In zh, this message translates to:
  /// **'已经连续干了 {hours} 小时，歇会儿？'**
  String activityReminderHours(int hours);

  /// No description provided for @activityStepModelRequest.
  ///
  /// In zh, this message translates to:
  /// **'一次模型请求'**
  String get activityStepModelRequest;

  /// No description provided for @activityStepModelRequestDetail.
  ///
  /// In zh, this message translates to:
  /// **'一次模型请求 · {detail}'**
  String activityStepModelRequestDetail(String detail);

  /// No description provided for @activityUsageEstimatedCost.
  ///
  /// In zh, this message translates to:
  /// **'约 {symbol}{amount}'**
  String activityUsageEstimatedCost(String symbol, String amount);

  /// No description provided for @activitySlashCommandSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{label}，/{name}'**
  String activitySlashCommandSemantics(String label, String name);

  /// No description provided for @activityToolListSeparator.
  ///
  /// In zh, this message translates to:
  /// **'、'**
  String get activityToolListSeparator;

  /// No description provided for @botsFolderGone.
  ///
  /// In zh, this message translates to:
  /// **'这个文件夹已经不在了'**
  String get botsFolderGone;

  /// No description provided for @botsFolderReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取这个文件夹'**
  String get botsFolderReadFailed;

  /// No description provided for @botsFolderOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'打不开这个文件夹'**
  String get botsFolderOpenFailed;

  /// No description provided for @botsFolderCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个文件夹'**
  String botsFolderCount(int count);

  /// No description provided for @botsChildCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个下级'**
  String botsChildCount(int count);

  /// No description provided for @botsCurrentChat.
  ///
  /// In zh, this message translates to:
  /// **'当前对话'**
  String get botsCurrentChat;

  /// No description provided for @botsSubagentCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个子代理'**
  String botsSubagentCount(int count);

  /// No description provided for @botsRunningCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个运行中'**
  String botsRunningCount(int count);

  /// No description provided for @botsFailedCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个出错'**
  String botsFailedCount(int count);

  /// No description provided for @botsNestedCount.
  ///
  /// In zh, this message translates to:
  /// **'含 {count} 个下级'**
  String botsNestedCount(int count);

  /// No description provided for @botsBackToParent.
  ///
  /// In zh, this message translates to:
  /// **'返回「{title}」'**
  String botsBackToParent(String title);

  /// No description provided for @botsTeamMemberCount.
  ///
  /// In zh, this message translates to:
  /// **'智能体团队，{count} 位成员'**
  String botsTeamMemberCount(int count);

  /// No description provided for @botsAgentTeam.
  ///
  /// In zh, this message translates to:
  /// **'智能体团队'**
  String get botsAgentTeam;

  /// No description provided for @botsSubagentRunningCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个子代理，{running} 个运行中'**
  String botsSubagentRunningCount(int count, int running);

  /// No description provided for @botsSubagents.
  ///
  /// In zh, this message translates to:
  /// **'子代理'**
  String get botsSubagents;

  /// No description provided for @botsNoSubagents.
  ///
  /// In zh, this message translates to:
  /// **'没有派出子代理'**
  String get botsNoSubagents;

  /// No description provided for @botsOpenChatFirst.
  ///
  /// In zh, this message translates to:
  /// **'先打开一个对话'**
  String get botsOpenChatFirst;

  /// No description provided for @botsNoTeamOnHost.
  ///
  /// In zh, this message translates to:
  /// **'这台主机没有智能体团队'**
  String get botsNoTeamOnHost;

  /// No description provided for @botsMembersWorking.
  ///
  /// In zh, this message translates to:
  /// **'{count} 位成员在工作'**
  String botsMembersWorking(int count);

  /// No description provided for @botsTeamStandby.
  ///
  /// In zh, this message translates to:
  /// **'都在待命'**
  String get botsTeamStandby;

  /// No description provided for @botsMembers.
  ///
  /// In zh, this message translates to:
  /// **'成员'**
  String get botsMembers;

  /// No description provided for @botsTasks.
  ///
  /// In zh, this message translates to:
  /// **'任务'**
  String get botsTasks;

  /// No description provided for @botsTeamRecordUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'团队记录有一条读不出来'**
  String get botsTeamRecordUnreadable;

  /// No description provided for @botsMessages.
  ///
  /// In zh, this message translates to:
  /// **'消息'**
  String get botsMessages;

  /// No description provided for @botsOwner.
  ///
  /// In zh, this message translates to:
  /// **'负责人'**
  String get botsOwner;

  /// No description provided for @botsTeamCreateHint.
  ///
  /// In zh, this message translates to:
  /// **'在对话里请 AI 组建团队'**
  String get botsTeamCreateHint;

  /// No description provided for @botsCurrent.
  ///
  /// In zh, this message translates to:
  /// **'当前'**
  String get botsCurrent;

  /// No description provided for @botsNoTasks.
  ///
  /// In zh, this message translates to:
  /// **'还没有任务'**
  String get botsNoTasks;

  /// No description provided for @botsTodo.
  ///
  /// In zh, this message translates to:
  /// **'待办'**
  String get botsTodo;

  /// No description provided for @botsUnassigned.
  ///
  /// In zh, this message translates to:
  /// **'未分配'**
  String get botsUnassigned;

  /// No description provided for @botsTaskWaitingFor.
  ///
  /// In zh, this message translates to:
  /// **'等 {dependencies}'**
  String botsTaskWaitingFor(String dependencies);

  /// No description provided for @botsWriteOverlap.
  ///
  /// In zh, this message translates to:
  /// **'写入范围重叠'**
  String get botsWriteOverlap;

  /// No description provided for @botsWaitingDependencies.
  ///
  /// In zh, this message translates to:
  /// **'等依赖'**
  String get botsWaitingDependencies;

  /// No description provided for @botsReadyToStart.
  ///
  /// In zh, this message translates to:
  /// **'可开始'**
  String get botsReadyToStart;

  /// No description provided for @botsTaskId.
  ///
  /// In zh, this message translates to:
  /// **'编号'**
  String get botsTaskId;

  /// No description provided for @botsDependencies.
  ///
  /// In zh, this message translates to:
  /// **'依赖'**
  String get botsDependencies;

  /// No description provided for @botsWriteScopes.
  ///
  /// In zh, this message translates to:
  /// **'写入范围'**
  String get botsWriteScopes;

  /// No description provided for @botsMessagesReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读到消息'**
  String get botsMessagesReadFailed;

  /// No description provided for @botsNoMemberMessages.
  ///
  /// In zh, this message translates to:
  /// **'成员之间还没有消息'**
  String get botsNoMemberMessages;

  /// No description provided for @botsMessagesIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'部分成员的消息没能读到 · 重试'**
  String get botsMessagesIncomplete;

  /// No description provided for @botsDateTime.
  ///
  /// In zh, this message translates to:
  /// **'{date} {time}'**
  String botsDateTime(String date, String time);

  /// No description provided for @botsDiscardTitle.
  ///
  /// In zh, this message translates to:
  /// **'放弃修改？'**
  String get botsDiscardTitle;

  /// No description provided for @botsKeepEditing.
  ///
  /// In zh, this message translates to:
  /// **'继续编辑'**
  String get botsKeepEditing;

  /// No description provided for @botsDiscard.
  ///
  /// In zh, this message translates to:
  /// **'放弃'**
  String get botsDiscard;

  /// No description provided for @botsGlyphRun.
  ///
  /// In zh, this message translates to:
  /// **'运行'**
  String get botsGlyphRun;

  /// No description provided for @botsGlyphJobOutput.
  ///
  /// In zh, this message translates to:
  /// **'查看后台任务'**
  String get botsGlyphJobOutput;

  /// No description provided for @botsGlyphJobs.
  ///
  /// In zh, this message translates to:
  /// **'后台任务'**
  String get botsGlyphJobs;

  /// No description provided for @botsGlyphStopJob.
  ///
  /// In zh, this message translates to:
  /// **'停止后台任务'**
  String get botsGlyphStopJob;

  /// No description provided for @botsGlyphRead.
  ///
  /// In zh, this message translates to:
  /// **'读取'**
  String get botsGlyphRead;

  /// No description provided for @botsGlyphImage.
  ///
  /// In zh, this message translates to:
  /// **'查看图片'**
  String get botsGlyphImage;

  /// No description provided for @botsGlyphDeliver.
  ///
  /// In zh, this message translates to:
  /// **'交付文件'**
  String get botsGlyphDeliver;

  /// No description provided for @botsGlyphWrite.
  ///
  /// In zh, this message translates to:
  /// **'写入'**
  String get botsGlyphWrite;

  /// No description provided for @botsGlyphSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get botsGlyphSearch;

  /// No description provided for @botsGlyphFindFiles.
  ///
  /// In zh, this message translates to:
  /// **'查找文件'**
  String get botsGlyphFindFiles;

  /// No description provided for @botsGlyphOpenWeb.
  ///
  /// In zh, this message translates to:
  /// **'打开网页'**
  String get botsGlyphOpenWeb;

  /// No description provided for @botsGlyphMessageAgent.
  ///
  /// In zh, this message translates to:
  /// **'发消息给子代理'**
  String get botsGlyphMessageAgent;

  /// No description provided for @botsGlyphInterruptAgent.
  ///
  /// In zh, this message translates to:
  /// **'打断子代理'**
  String get botsGlyphInterruptAgent;

  /// No description provided for @botsGlyphListModels.
  ///
  /// In zh, this message translates to:
  /// **'列出子代理模型'**
  String get botsGlyphListModels;

  /// No description provided for @botsGlyphWorkflow.
  ///
  /// In zh, this message translates to:
  /// **'工作流'**
  String get botsGlyphWorkflow;

  /// No description provided for @botsGlyphLoop.
  ///
  /// In zh, this message translates to:
  /// **'循环任务'**
  String get botsGlyphLoop;

  /// No description provided for @botsGlyphSkill.
  ///
  /// In zh, this message translates to:
  /// **'使用技能'**
  String get botsGlyphSkill;

  /// No description provided for @botsGlyphTodo.
  ///
  /// In zh, this message translates to:
  /// **'更新待办'**
  String get botsGlyphTodo;

  /// No description provided for @botsGlyphSetGoal.
  ///
  /// In zh, this message translates to:
  /// **'设定目标'**
  String get botsGlyphSetGoal;

  /// No description provided for @botsGlyphViewGoal.
  ///
  /// In zh, this message translates to:
  /// **'查看目标'**
  String get botsGlyphViewGoal;

  /// No description provided for @botsGlyphUpdateGoal.
  ///
  /// In zh, this message translates to:
  /// **'更新目标'**
  String get botsGlyphUpdateGoal;

  /// No description provided for @botsGlyphAsk.
  ///
  /// In zh, this message translates to:
  /// **'提问'**
  String get botsGlyphAsk;

  /// No description provided for @botsEmptyCell.
  ///
  /// In zh, this message translates to:
  /// **'（空）'**
  String get botsEmptyCell;

  /// No description provided for @botsYesterdayTime.
  ///
  /// In zh, this message translates to:
  /// **'昨天 {time}'**
  String botsYesterdayTime(String time);

  /// No description provided for @botsOutsideWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'不在工作区里'**
  String get botsOutsideWorkspace;

  /// No description provided for @botsNotFolder.
  ///
  /// In zh, this message translates to:
  /// **'这不是文件夹'**
  String get botsNotFolder;

  /// No description provided for @botsChatNotFound.
  ///
  /// In zh, this message translates to:
  /// **'找不到这个对话'**
  String get botsChatNotFound;

  /// No description provided for @botsBrowseUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'这个连接不支持浏览文件'**
  String get botsBrowseUnsupported;

  /// No description provided for @botsWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'工作区'**
  String get botsWorkspace;

  /// No description provided for @botsSearchFiles.
  ///
  /// In zh, this message translates to:
  /// **'搜索文件'**
  String get botsSearchFiles;

  /// No description provided for @botsGoUp.
  ///
  /// In zh, this message translates to:
  /// **'回到上一级'**
  String get botsGoUp;

  /// No description provided for @botsEmptyFolder.
  ///
  /// In zh, this message translates to:
  /// **'空文件夹'**
  String get botsEmptyFolder;

  /// No description provided for @botsFileCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个文件'**
  String botsFileCount(int count);

  /// No description provided for @botsTruncatedItems.
  ///
  /// In zh, this message translates to:
  /// **'只列出了前 {count} 项'**
  String botsTruncatedItems(int count);

  /// No description provided for @botsMoreActions.
  ///
  /// In zh, this message translates to:
  /// **'更多操作'**
  String get botsMoreActions;

  /// No description provided for @botsSearchFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能搜索'**
  String get botsSearchFailed;

  /// No description provided for @botsNoResults.
  ///
  /// In zh, this message translates to:
  /// **'没有找到'**
  String get botsNoResults;

  /// No description provided for @botsCopyPath.
  ///
  /// In zh, this message translates to:
  /// **'复制路径'**
  String get botsCopyPath;

  /// No description provided for @botsKeyEsc.
  ///
  /// In zh, this message translates to:
  /// **'发送 Esc'**
  String get botsKeyEsc;

  /// No description provided for @botsKeyTab.
  ///
  /// In zh, this message translates to:
  /// **'发送 Tab'**
  String get botsKeyTab;

  /// No description provided for @botsKeyLeft.
  ///
  /// In zh, this message translates to:
  /// **'左'**
  String get botsKeyLeft;

  /// No description provided for @botsKeyUp.
  ///
  /// In zh, this message translates to:
  /// **'上'**
  String get botsKeyUp;

  /// No description provided for @botsKeyDown.
  ///
  /// In zh, this message translates to:
  /// **'下'**
  String get botsKeyDown;

  /// No description provided for @botsKeyRight.
  ///
  /// In zh, this message translates to:
  /// **'右'**
  String get botsKeyRight;

  /// No description provided for @botsKeyPipe.
  ///
  /// In zh, this message translates to:
  /// **'竖线'**
  String get botsKeyPipe;

  /// No description provided for @botsKeyTilde.
  ///
  /// In zh, this message translates to:
  /// **'波浪号'**
  String get botsKeyTilde;

  /// No description provided for @botsKeySlash.
  ///
  /// In zh, this message translates to:
  /// **'斜杠'**
  String get botsKeySlash;

  /// No description provided for @botsKeyDash.
  ///
  /// In zh, this message translates to:
  /// **'短横线'**
  String get botsKeyDash;

  /// No description provided for @botsTerminal.
  ///
  /// In zh, this message translates to:
  /// **'终端'**
  String get botsTerminal;

  /// No description provided for @botsTerminalRename.
  ///
  /// In zh, this message translates to:
  /// **'重命名终端'**
  String get botsTerminalRename;

  /// No description provided for @botsTerminalName.
  ///
  /// In zh, this message translates to:
  /// **'终端名称'**
  String get botsTerminalName;

  /// No description provided for @botsTerminalRenameFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能重命名'**
  String get botsTerminalRenameFailed;

  /// No description provided for @botsTerminalCloseNamed.
  ///
  /// In zh, this message translates to:
  /// **'关闭「{title}」？'**
  String botsTerminalCloseNamed(String title);

  /// No description provided for @botsTerminalCloseBody.
  ///
  /// In zh, this message translates to:
  /// **'里面的进程会结束'**
  String get botsTerminalCloseBody;

  /// No description provided for @botsTerminalUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'这个连接用不了终端'**
  String get botsTerminalUnsupported;

  /// No description provided for @botsTerminalSupportedHosts.
  ///
  /// In zh, this message translates to:
  /// **'在本机、SSH 主机或 Remote 电脑上可用'**
  String get botsTerminalSupportedHosts;

  /// No description provided for @botsTerminalOpening.
  ///
  /// In zh, this message translates to:
  /// **'正在打开终端…'**
  String get botsTerminalOpening;

  /// No description provided for @botsTerminalNone.
  ///
  /// In zh, this message translates to:
  /// **'没有打开的终端'**
  String get botsTerminalNone;

  /// No description provided for @botsTerminalNew.
  ///
  /// In zh, this message translates to:
  /// **'新建终端'**
  String get botsTerminalNew;

  /// No description provided for @botsTerminalClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭终端'**
  String get botsTerminalClose;

  /// No description provided for @botsTerminalChooseShell.
  ///
  /// In zh, this message translates to:
  /// **'选择 Shell'**
  String get botsTerminalChooseShell;

  /// No description provided for @botsTerminalShellFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取 Shell'**
  String get botsTerminalShellFailed;

  /// No description provided for @botsTerminalReading.
  ///
  /// In zh, this message translates to:
  /// **'正在读取…'**
  String get botsTerminalReading;

  /// No description provided for @botsTerminalDefaultShell.
  ///
  /// In zh, this message translates to:
  /// **'默认 Shell'**
  String get botsTerminalDefaultShell;

  /// No description provided for @botsTerminalOtherDevice.
  ///
  /// In zh, this message translates to:
  /// **'其他设备正在输入'**
  String get botsTerminalOtherDevice;

  /// No description provided for @botsTerminalTakeOver.
  ///
  /// In zh, this message translates to:
  /// **'接管'**
  String get botsTerminalTakeOver;

  /// No description provided for @botsTerminalStarting.
  ///
  /// In zh, this message translates to:
  /// **'正在启动…'**
  String get botsTerminalStarting;

  /// No description provided for @botsTerminalConnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接…'**
  String get botsTerminalConnecting;

  /// No description provided for @botsTerminalDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'连接已断开'**
  String get botsTerminalDisconnected;

  /// No description provided for @botsTerminalReconnect.
  ///
  /// In zh, this message translates to:
  /// **'重新连接'**
  String get botsTerminalReconnect;

  /// No description provided for @botsTerminalEnded.
  ///
  /// In zh, this message translates to:
  /// **'已结束'**
  String get botsTerminalEnded;

  /// No description provided for @botsTerminalExitCode.
  ///
  /// In zh, this message translates to:
  /// **'已结束 · 退出码 {code}'**
  String botsTerminalExitCode(int code);

  /// No description provided for @botsTerminalGone.
  ///
  /// In zh, this message translates to:
  /// **'这个终端已不在了'**
  String get botsTerminalGone;

  /// No description provided for @botsTerminalLimit.
  ///
  /// In zh, this message translates to:
  /// **'先关掉不用的终端'**
  String get botsTerminalLimit;

  /// No description provided for @botsListSeparator.
  ///
  /// In zh, this message translates to:
  /// **'，'**
  String get botsListSeparator;

  /// No description provided for @botsNameSeparator.
  ///
  /// In zh, this message translates to:
  /// **'、'**
  String get botsNameSeparator;

  /// No description provided for @botsGlyphSubagent.
  ///
  /// In zh, this message translates to:
  /// **'子代理'**
  String get botsGlyphSubagent;

  /// No description provided for @botsGlyphWebSearch.
  ///
  /// In zh, this message translates to:
  /// **'联网搜索'**
  String get botsGlyphWebSearch;

  /// No description provided for @botsAgentSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{title}，{state}'**
  String botsAgentSemantics(String title, String state);

  /// No description provided for @chatBackgroundTaskNotice.
  ///
  /// In zh, this message translates to:
  /// **'后台任务通知'**
  String get chatBackgroundTaskNotice;

  /// No description provided for @chatBackgroundTaskMessage.
  ///
  /// In zh, this message translates to:
  /// **'后台任务消息'**
  String get chatBackgroundTaskMessage;

  /// No description provided for @chatDeclineQuestion.
  ///
  /// In zh, this message translates to:
  /// **'不回答'**
  String get chatDeclineQuestion;

  /// No description provided for @chatChats.
  ///
  /// In zh, this message translates to:
  /// **'对话列表'**
  String get chatChats;

  /// No description provided for @chatViewChatDetails.
  ///
  /// In zh, this message translates to:
  /// **'查看对话详情'**
  String get chatViewChatDetails;

  /// No description provided for @chatUnsent.
  ///
  /// In zh, this message translates to:
  /// **'未发送'**
  String get chatUnsent;

  /// No description provided for @chatFailedSubmission.
  ///
  /// In zh, this message translates to:
  /// **'未送达 · 已保留'**
  String get chatFailedSubmission;

  /// No description provided for @chatEditFailedSubmission.
  ///
  /// In zh, this message translates to:
  /// **'编辑后重发'**
  String get chatEditFailedSubmission;

  /// No description provided for @chatErrReasoningEffortUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前模型不支持此推理档位，请调整档位或换模型'**
  String get chatErrReasoningEffortUnsupported;

  /// No description provided for @chatSteerNextStep.
  ///
  /// In zh, this message translates to:
  /// **'插话 · 下一步生效'**
  String get chatSteerNextStep;

  /// No description provided for @chatQueuedAfterTurn.
  ///
  /// In zh, this message translates to:
  /// **'排队中 · 本轮结束后发送'**
  String get chatQueuedAfterTurn;

  /// No description provided for @chatSteering.
  ///
  /// In zh, this message translates to:
  /// **'插话中'**
  String get chatSteering;

  /// No description provided for @chatQueued.
  ///
  /// In zh, this message translates to:
  /// **'排队中'**
  String get chatQueued;

  /// No description provided for @chatStoppingTurn.
  ///
  /// In zh, this message translates to:
  /// **'正在停止本轮'**
  String get chatStoppingTurn;

  /// No description provided for @chatSending.
  ///
  /// In zh, this message translates to:
  /// **'发送中'**
  String get chatSending;

  /// No description provided for @chatSendNow.
  ///
  /// In zh, this message translates to:
  /// **'立即发送'**
  String get chatSendNow;

  /// No description provided for @chatSwitchToSteer.
  ///
  /// In zh, this message translates to:
  /// **'改为插话'**
  String get chatSwitchToSteer;

  /// No description provided for @chatWithdraw.
  ///
  /// In zh, this message translates to:
  /// **'撤回'**
  String get chatWithdraw;

  /// No description provided for @chatContinuedInNewChat.
  ///
  /// In zh, this message translates to:
  /// **'已在新对话中继续'**
  String get chatContinuedInNewChat;

  /// No description provided for @chatReadOriginalImageFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取原图失败，请重试'**
  String get chatReadOriginalImageFailed;

  /// No description provided for @chatRegenerateFailed.
  ///
  /// In zh, this message translates to:
  /// **'重新回答失败'**
  String get chatRegenerateFailed;

  /// No description provided for @chatRegeneratedInNewChat.
  ///
  /// In zh, this message translates to:
  /// **'已在新对话中重新回答'**
  String get chatRegeneratedInNewChat;

  /// No description provided for @chatOpenedInNewChatReattach.
  ///
  /// In zh, this message translates to:
  /// **'已在新对话中打开，附件需重新添加'**
  String get chatOpenedInNewChatReattach;

  /// No description provided for @chatOpenedInNewChat.
  ///
  /// In zh, this message translates to:
  /// **'已在新对话中打开'**
  String get chatOpenedInNewChat;

  /// No description provided for @chatForkQueuedLeft.
  ///
  /// In zh, this message translates to:
  /// **'{message}（{left} 条排队消息未能带走）'**
  String chatForkQueuedLeft(String message, int left);

  /// No description provided for @chatReturnToOriginal.
  ///
  /// In zh, this message translates to:
  /// **'返回原对话'**
  String get chatReturnToOriginal;

  /// No description provided for @chatWaitingCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 项待确认'**
  String chatWaitingCount(int count);

  /// No description provided for @chatWaitingBackToBottom.
  ///
  /// In zh, this message translates to:
  /// **'{count} 项待确认，回到底部'**
  String chatWaitingBackToBottom(int count);

  /// No description provided for @chatBackToBottom.
  ///
  /// In zh, this message translates to:
  /// **'回到底部'**
  String get chatBackToBottom;

  /// No description provided for @chatCreateFailed.
  ///
  /// In zh, this message translates to:
  /// **'新建对话失败'**
  String get chatCreateFailed;

  /// No description provided for @chatSendMode.
  ///
  /// In zh, this message translates to:
  /// **'发送方式'**
  String get chatSendMode;

  /// No description provided for @chatSteer.
  ///
  /// In zh, this message translates to:
  /// **'插话'**
  String get chatSteer;

  /// No description provided for @chatSteerHint.
  ///
  /// In zh, this message translates to:
  /// **'不打断，AI 下一步会看到'**
  String get chatSteerHint;

  /// No description provided for @chatInterruptAndSend.
  ///
  /// In zh, this message translates to:
  /// **'中断并发送'**
  String get chatInterruptAndSend;

  /// No description provided for @chatInterruptHint.
  ///
  /// In zh, this message translates to:
  /// **'停下当前任务，先处理这条'**
  String get chatInterruptHint;

  /// No description provided for @chatQueue.
  ///
  /// In zh, this message translates to:
  /// **'排队'**
  String get chatQueue;

  /// No description provided for @chatQueueHint.
  ///
  /// In zh, this message translates to:
  /// **'本轮结束后发送'**
  String get chatQueueHint;

  /// No description provided for @chatWithdrawnEditable.
  ///
  /// In zh, this message translates to:
  /// **'已撤回，可修改后再发'**
  String get chatWithdrawnEditable;

  /// No description provided for @chatWithdrawn.
  ///
  /// In zh, this message translates to:
  /// **'已撤回'**
  String get chatWithdrawn;

  /// No description provided for @chatAttachmentLimit.
  ///
  /// In zh, this message translates to:
  /// **'每条消息最多 {count} 个附件'**
  String chatAttachmentLimit(int count);

  /// No description provided for @chatAttachmentPermission.
  ///
  /// In zh, this message translates to:
  /// **'没有权限，可在系统设置中开启'**
  String get chatAttachmentPermission;

  /// No description provided for @chatOpenAttachmentFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能打开附件'**
  String get chatOpenAttachmentFailed;

  /// No description provided for @chatReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取失败'**
  String get chatReadFailed;

  /// No description provided for @chatReadImageFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取图片'**
  String get chatReadImageFailed;

  /// No description provided for @chatOpenChatFirst.
  ///
  /// In zh, this message translates to:
  /// **'先打开一个对话'**
  String get chatOpenChatFirst;

  /// No description provided for @chatTurnCompleted.
  ///
  /// In zh, this message translates to:
  /// **'这一轮已完成'**
  String get chatTurnCompleted;

  /// No description provided for @chatTurnError.
  ///
  /// In zh, this message translates to:
  /// **'这一轮出错了'**
  String get chatTurnError;

  /// No description provided for @chatAnswerHint.
  ///
  /// In zh, this message translates to:
  /// **'输入回答…'**
  String get chatAnswerHint;

  /// No description provided for @chatAnswerMode.
  ///
  /// In zh, this message translates to:
  /// **'发送文字将回答待答问题'**
  String get chatAnswerMode;

  /// No description provided for @chatMessageMode.
  ///
  /// In zh, this message translates to:
  /// **'发送新消息'**
  String get chatMessageMode;

  /// No description provided for @chatQuestionAnswered.
  ///
  /// In zh, this message translates to:
  /// **'已回答'**
  String get chatQuestionAnswered;

  /// No description provided for @chatStarting.
  ///
  /// In zh, this message translates to:
  /// **'正在启动'**
  String get chatStarting;

  /// No description provided for @chatConnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接'**
  String get chatConnecting;

  /// No description provided for @chatDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'连接已断开'**
  String get chatDisconnected;

  /// No description provided for @chatReconnecting.
  ///
  /// In zh, this message translates to:
  /// **'重新连接中'**
  String get chatReconnecting;

  /// No description provided for @chatGenerating.
  ///
  /// In zh, this message translates to:
  /// **'生成中'**
  String get chatGenerating;

  /// No description provided for @chatGoToSettings.
  ///
  /// In zh, this message translates to:
  /// **'去设置'**
  String get chatGoToSettings;

  /// No description provided for @chatConnectToSend.
  ///
  /// In zh, this message translates to:
  /// **'连接引擎后即可发送'**
  String get chatConnectToSend;

  /// No description provided for @chatGeneratingSteerHint.
  ///
  /// In zh, this message translates to:
  /// **'生成中 · 可直接插话'**
  String get chatGeneratingSteerHint;

  /// No description provided for @chatComposerHint.
  ///
  /// In zh, this message translates to:
  /// **'给 DSH 发消息…'**
  String get chatComposerHint;

  /// No description provided for @chatStopGenerating.
  ///
  /// In zh, this message translates to:
  /// **'停止生成'**
  String get chatStopGenerating;

  /// No description provided for @chatGoal.
  ///
  /// In zh, this message translates to:
  /// **'目标'**
  String get chatGoal;

  /// No description provided for @chatGoalActions.
  ///
  /// In zh, this message translates to:
  /// **'目标操作'**
  String get chatGoalActions;

  /// No description provided for @chatGoalBlocked.
  ///
  /// In zh, this message translates to:
  /// **'受阻'**
  String get chatGoalBlocked;

  /// No description provided for @chatGoalRoundLimit.
  ///
  /// In zh, this message translates to:
  /// **'第 {rounds} / {max} 轮'**
  String chatGoalRoundLimit(int rounds, int max);

  /// No description provided for @chatGoalRound.
  ///
  /// In zh, this message translates to:
  /// **'第 {rounds} 轮'**
  String chatGoalRound(int rounds);

  /// No description provided for @chatEditGoal.
  ///
  /// In zh, this message translates to:
  /// **'编辑目标'**
  String get chatEditGoal;

  /// No description provided for @chatPauseGoal.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get chatPauseGoal;

  /// No description provided for @chatPauseGoalHint.
  ///
  /// In zh, this message translates to:
  /// **'先不自动推进'**
  String get chatPauseGoalHint;

  /// No description provided for @chatResumeGoal.
  ///
  /// In zh, this message translates to:
  /// **'恢复'**
  String get chatResumeGoal;

  /// No description provided for @chatResumeGoalHint.
  ///
  /// In zh, this message translates to:
  /// **'继续自动推进'**
  String get chatResumeGoalHint;

  /// No description provided for @chatClearGoal.
  ///
  /// In zh, this message translates to:
  /// **'清除目标'**
  String get chatClearGoal;

  /// No description provided for @chatGoalHint.
  ///
  /// In zh, this message translates to:
  /// **'要完成什么'**
  String get chatGoalHint;

  /// No description provided for @chatClearGoalTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除目标？'**
  String get chatClearGoalTitle;

  /// No description provided for @chatTodoCurrent.
  ///
  /// In zh, this message translates to:
  /// **'正在：{content}'**
  String chatTodoCurrent(String content);

  /// No description provided for @chatTodoNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步：{content}'**
  String chatTodoNext(String content);

  /// No description provided for @chatTodoAllDone.
  ///
  /// In zh, this message translates to:
  /// **'全部完成'**
  String get chatTodoAllDone;

  /// No description provided for @chatTodoSemantics.
  ///
  /// In zh, this message translates to:
  /// **'待办 {count}，{label}'**
  String chatTodoSemantics(String count, String label);

  /// No description provided for @chatCollapseTodos.
  ///
  /// In zh, this message translates to:
  /// **'收起清单'**
  String get chatCollapseTodos;

  /// No description provided for @chatExpandTodos.
  ///
  /// In zh, this message translates to:
  /// **'展开清单'**
  String get chatExpandTodos;

  /// No description provided for @chatDockFolded.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条状态已叠起'**
  String chatDockFolded(int count);

  /// No description provided for @chatDockSpread.
  ///
  /// In zh, this message translates to:
  /// **'展开'**
  String get chatDockSpread;

  /// No description provided for @chatDockFold.
  ///
  /// In zh, this message translates to:
  /// **'收起状态条'**
  String get chatDockFold;

  /// No description provided for @chatDockNext.
  ///
  /// In zh, this message translates to:
  /// **'下一张'**
  String get chatDockNext;

  /// No description provided for @chatDockPrevious.
  ///
  /// In zh, this message translates to:
  /// **'上一张'**
  String get chatDockPrevious;

  /// No description provided for @chatTodoNotStarted.
  ///
  /// In zh, this message translates to:
  /// **'未开始'**
  String get chatTodoNotStarted;

  /// No description provided for @chatFile.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get chatFile;

  /// No description provided for @chatFolder.
  ///
  /// In zh, this message translates to:
  /// **'文件夹'**
  String get chatFolder;

  /// No description provided for @chatChat.
  ///
  /// In zh, this message translates to:
  /// **'对话'**
  String get chatChat;

  /// No description provided for @chatSubagent.
  ///
  /// In zh, this message translates to:
  /// **'子代理'**
  String get chatSubagent;

  /// No description provided for @chatRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近'**
  String get chatRecent;

  /// No description provided for @chatMentionSearching.
  ///
  /// In zh, this message translates to:
  /// **'正在查找…'**
  String get chatMentionSearching;

  /// No description provided for @chatMentionNoFiles.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配的文件'**
  String get chatMentionNoFiles;

  /// No description provided for @chatMentionNoMatches.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配的文件或对话'**
  String get chatMentionNoMatches;

  /// No description provided for @chatQuote.
  ///
  /// In zh, this message translates to:
  /// **'引用'**
  String get chatQuote;

  /// No description provided for @chatOpenFolder.
  ///
  /// In zh, this message translates to:
  /// **'打开文件夹'**
  String get chatOpenFolder;

  /// No description provided for @chatJustNow.
  ///
  /// In zh, this message translates to:
  /// **'刚刚'**
  String get chatJustNow;

  /// No description provided for @chatMentionAgeMinutes.
  ///
  /// In zh, this message translates to:
  /// **'{count}分钟'**
  String chatMentionAgeMinutes(int count);

  /// No description provided for @chatMentionAgeHours.
  ///
  /// In zh, this message translates to:
  /// **'{count}小时'**
  String chatMentionAgeHours(int count);

  /// No description provided for @chatMentionAgeDays.
  ///
  /// In zh, this message translates to:
  /// **'{count}天'**
  String chatMentionAgeDays(int count);

  /// No description provided for @chatMentionAgeMonths.
  ///
  /// In zh, this message translates to:
  /// **'{count}个月'**
  String chatMentionAgeMonths(int count);

  /// No description provided for @chatMentionAgeYears.
  ///
  /// In zh, this message translates to:
  /// **'{count}年'**
  String chatMentionAgeYears(int count);

  /// No description provided for @chatMermaidChart.
  ///
  /// In zh, this message translates to:
  /// **'Mermaid 图表'**
  String get chatMermaidChart;

  /// No description provided for @chatPreview.
  ///
  /// In zh, this message translates to:
  /// **'预览'**
  String get chatPreview;

  /// No description provided for @chatUnwrapLines.
  ///
  /// In zh, this message translates to:
  /// **'不换行'**
  String get chatUnwrapLines;

  /// No description provided for @chatWrapLines.
  ///
  /// In zh, this message translates to:
  /// **'自动换行'**
  String get chatWrapLines;

  /// No description provided for @chatAlertNote.
  ///
  /// In zh, this message translates to:
  /// **'注意'**
  String get chatAlertNote;

  /// No description provided for @chatAlertTip.
  ///
  /// In zh, this message translates to:
  /// **'提示'**
  String get chatAlertTip;

  /// No description provided for @chatAlertImportant.
  ///
  /// In zh, this message translates to:
  /// **'重要'**
  String get chatAlertImportant;

  /// No description provided for @chatAlertWarning.
  ///
  /// In zh, this message translates to:
  /// **'警告'**
  String get chatAlertWarning;

  /// No description provided for @chatAlertCaution.
  ///
  /// In zh, this message translates to:
  /// **'小心'**
  String get chatAlertCaution;

  /// No description provided for @chatImage.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get chatImage;

  /// No description provided for @chatImageNotFound.
  ///
  /// In zh, this message translates to:
  /// **'找不到图片'**
  String get chatImageNotFound;

  /// No description provided for @chatImageOffline.
  ///
  /// In zh, this message translates to:
  /// **'未连接 DSH'**
  String get chatImageOffline;

  /// No description provided for @chatImageTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'图片过大'**
  String get chatImageTooLarge;

  /// No description provided for @chatImageReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法读取文件'**
  String get chatImageReadFailed;

  /// No description provided for @chatImageDisplayFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法显示'**
  String get chatImageDisplayFailed;

  /// No description provided for @chatImageTapToView.
  ///
  /// In zh, this message translates to:
  /// **'轻点查看'**
  String get chatImageTapToView;

  /// No description provided for @chatImageTapToRetry.
  ///
  /// In zh, this message translates to:
  /// **'轻点重试'**
  String get chatImageTapToRetry;

  /// No description provided for @chatImageUnsupportedAddress.
  ///
  /// In zh, this message translates to:
  /// **'不支持的地址'**
  String get chatImageUnsupportedAddress;

  /// No description provided for @chatViewTurnTrace.
  ///
  /// In zh, this message translates to:
  /// **'查看本轮轨迹'**
  String get chatViewTurnTrace;

  /// No description provided for @chatTokensPerSecond.
  ///
  /// In zh, this message translates to:
  /// **'约 {count} tokens/秒'**
  String chatTokensPerSecond(int count);

  /// No description provided for @chatNoTokensStreaming.
  ///
  /// In zh, this message translates to:
  /// **'没有在出字'**
  String get chatNoTokensStreaming;

  /// No description provided for @chatCurrentStep.
  ///
  /// In zh, this message translates to:
  /// **'这一步 {step}'**
  String chatCurrentStep(String step);

  /// No description provided for @chatTodoProgress.
  ///
  /// In zh, this message translates to:
  /// **'待办进度 {done}/{total}'**
  String chatTodoProgress(int done, int total);

  /// No description provided for @chatProgress.
  ///
  /// In zh, this message translates to:
  /// **'进度 {done}/{total}'**
  String chatProgress(int done, int total);

  /// No description provided for @chatApproveCommand.
  ///
  /// In zh, this message translates to:
  /// **'允许运行这条命令？'**
  String get chatApproveCommand;

  /// No description provided for @chatApproveWrite.
  ///
  /// In zh, this message translates to:
  /// **'允许写入这个文件？'**
  String get chatApproveWrite;

  /// No description provided for @chatApproveEdit.
  ///
  /// In zh, this message translates to:
  /// **'允许修改这个文件？'**
  String get chatApproveEdit;

  /// No description provided for @chatApproveWebpage.
  ///
  /// In zh, this message translates to:
  /// **'允许打开这个网页？'**
  String get chatApproveWebpage;

  /// No description provided for @chatApproveSearch.
  ///
  /// In zh, this message translates to:
  /// **'允许联网搜索？'**
  String get chatApproveSearch;

  /// No description provided for @chatApproveTool.
  ///
  /// In zh, this message translates to:
  /// **'允许使用「{name}」？'**
  String chatApproveTool(String name);

  /// No description provided for @chatDecline.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get chatDecline;

  /// No description provided for @chatAllowOnce.
  ///
  /// In zh, this message translates to:
  /// **'允许本次'**
  String get chatAllowOnce;

  /// No description provided for @chatAllowForChat.
  ///
  /// In zh, this message translates to:
  /// **'本对话都允许'**
  String get chatAllowForChat;

  /// No description provided for @chatSaveToDownloads.
  ///
  /// In zh, this message translates to:
  /// **'存到「下载」'**
  String get chatSaveToDownloads;

  /// No description provided for @chatCopyPath.
  ///
  /// In zh, this message translates to:
  /// **'复制路径'**
  String get chatCopyPath;

  /// No description provided for @chatOpenInDefaultApp.
  ///
  /// In zh, this message translates to:
  /// **'用默认应用打开'**
  String get chatOpenInDefaultApp;

  /// No description provided for @chatDownloadsFolderHint.
  ///
  /// In zh, this message translates to:
  /// **'下载/DSH-Go 文件夹'**
  String get chatDownloadsFolderHint;

  /// No description provided for @chatSavedToDownloadsPath.
  ///
  /// In zh, this message translates to:
  /// **'已存到 下载/{path}'**
  String chatSavedToDownloadsPath(String path);

  /// No description provided for @chatSavedToPath.
  ///
  /// In zh, this message translates to:
  /// **'已存到 {path}'**
  String chatSavedToPath(String path);

  /// No description provided for @chatDeliveredFiles.
  ///
  /// In zh, this message translates to:
  /// **'交付了 {count} 个文件'**
  String chatDeliveredFiles(int count);

  /// No description provided for @chatGeneratedFiles.
  ///
  /// In zh, this message translates to:
  /// **'生成了 {count} 个文件'**
  String chatGeneratedFiles(int count);

  /// No description provided for @chatAllFiles.
  ///
  /// In zh, this message translates to:
  /// **'全部 {count} 个文件'**
  String chatAllFiles(int count);

  /// No description provided for @chatCollapseFileList.
  ///
  /// In zh, this message translates to:
  /// **'收起文件列表'**
  String get chatCollapseFileList;

  /// No description provided for @chatExpandAllFiles.
  ///
  /// In zh, this message translates to:
  /// **'展开全部 {count} 个文件'**
  String chatExpandAllFiles(int count);

  /// No description provided for @chatDownloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载…'**
  String get chatDownloading;

  /// No description provided for @chatDownloadingPercent.
  ///
  /// In zh, this message translates to:
  /// **'正在下载… {percent}%'**
  String chatDownloadingPercent(int percent);

  /// No description provided for @chatOpening.
  ///
  /// In zh, this message translates to:
  /// **'正在打开…'**
  String get chatOpening;

  /// No description provided for @chatSavingToDownloads.
  ///
  /// In zh, this message translates to:
  /// **'正在存到「下载」…'**
  String get chatSavingToDownloads;

  /// No description provided for @chatOpenInPhoneApp.
  ///
  /// In zh, this message translates to:
  /// **'用手机上的应用打开'**
  String get chatOpenInPhoneApp;

  /// No description provided for @chatMoreActions.
  ///
  /// In zh, this message translates to:
  /// **'更多操作'**
  String get chatMoreActions;

  /// No description provided for @chatAlreadyInDownloads.
  ///
  /// In zh, this message translates to:
  /// **'已在手机的「下载」里'**
  String get chatAlreadyInDownloads;

  /// No description provided for @chatArtifactCopyPathOnly.
  ///
  /// In zh, this message translates to:
  /// **'当前连接无法读取文件，只能复制路径'**
  String get chatArtifactCopyPathOnly;

  /// No description provided for @chatReplying.
  ///
  /// In zh, this message translates to:
  /// **'正在回复'**
  String get chatReplying;

  /// No description provided for @chatInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'已中断'**
  String get chatInterrupted;

  /// No description provided for @chatGallery.
  ///
  /// In zh, this message translates to:
  /// **'相册'**
  String get chatGallery;

  /// No description provided for @chatTakePhoto.
  ///
  /// In zh, this message translates to:
  /// **'拍照'**
  String get chatTakePhoto;

  /// No description provided for @chatAddAttachment.
  ///
  /// In zh, this message translates to:
  /// **'添加图片或文件'**
  String get chatAddAttachment;

  /// No description provided for @chatRemoveAttachment.
  ///
  /// In zh, this message translates to:
  /// **'移除「{name}」'**
  String chatRemoveAttachment(String name);

  /// No description provided for @chatAutoApproveCommands.
  ///
  /// In zh, this message translates to:
  /// **'自动允许命令'**
  String get chatAutoApproveCommands;

  /// No description provided for @chatAutoApproving.
  ///
  /// In zh, this message translates to:
  /// **'自动允许中'**
  String get chatAutoApproving;

  /// No description provided for @chatViewMoreChanges.
  ///
  /// In zh, this message translates to:
  /// **'查看改动，还有 {count} 个文件'**
  String chatViewMoreChanges(int count);

  /// No description provided for @chatViewChanges.
  ///
  /// In zh, this message translates to:
  /// **'查看改动'**
  String get chatViewChanges;

  /// No description provided for @chatChangedFiles.
  ///
  /// In zh, this message translates to:
  /// **'改动了 {count} 个文件'**
  String chatChangedFiles(int count);

  /// No description provided for @chatMoreFiles.
  ///
  /// In zh, this message translates to:
  /// **'还有 {count} 个文件'**
  String chatMoreFiles(int count);

  /// No description provided for @chatFileChangeSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{path}，新增 {added} 行，删除 {removed} 行'**
  String chatFileChangeSemantics(String path, int added, int removed);

  /// No description provided for @chatNewFileSuffix.
  ///
  /// In zh, this message translates to:
  /// **'  新建'**
  String get chatNewFileSuffix;

  /// No description provided for @chatPathCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制路径'**
  String get chatPathCopied;

  /// No description provided for @chatCommandCompacted.
  ///
  /// In zh, this message translates to:
  /// **'已压缩 {count} 条历史记录（约 {tokens} tokens）'**
  String chatCommandCompacted(int count, String tokens);

  /// No description provided for @chatCommandPermissionChanged.
  ///
  /// In zh, this message translates to:
  /// **'已切换为{name}'**
  String chatCommandPermissionChanged(String name);

  /// No description provided for @chatCommandCurrentPermission.
  ///
  /// In zh, this message translates to:
  /// **'当前权限：{name}'**
  String chatCommandCurrentPermission(String name);

  /// No description provided for @chatCommandUnknownPermission.
  ///
  /// In zh, this message translates to:
  /// **'没有这个权限预设'**
  String get chatCommandUnknownPermission;

  /// No description provided for @chatCommandFeedbackRequired.
  ///
  /// In zh, this message translates to:
  /// **'写上反馈内容再发送'**
  String get chatCommandFeedbackRequired;

  /// No description provided for @chatCommandFeedbackSubmitted.
  ///
  /// In zh, this message translates to:
  /// **'反馈已提交'**
  String get chatCommandFeedbackSubmitted;

  /// No description provided for @chatCommandNothingToCompact.
  ///
  /// In zh, this message translates to:
  /// **'还没有可压缩的内容'**
  String get chatCommandNothingToCompact;

  /// No description provided for @chatCommandCompactionCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消压缩'**
  String get chatCommandCompactionCancelled;

  /// No description provided for @chatCommandCompactionBusy.
  ///
  /// In zh, this message translates to:
  /// **'正在忙，稍后再压缩'**
  String get chatCommandCompactionBusy;

  /// No description provided for @chatCommandCompactedSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'已压缩，但没能保存'**
  String get chatCommandCompactedSaveFailed;

  /// No description provided for @chatCommandCompactUsage.
  ///
  /// In zh, this message translates to:
  /// **'/compact 不带参数'**
  String get chatCommandCompactUsage;

  /// No description provided for @chatCommandHistoryChanged.
  ///
  /// In zh, this message translates to:
  /// **'对话有变化，请再试一次'**
  String get chatCommandHistoryChanged;

  /// No description provided for @chatCommandCompactionFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能完成压缩，请再试一次'**
  String get chatCommandCompactionFailed;

  /// No description provided for @chatCommandCompactionIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'压缩未完成，请查看对话'**
  String get chatCommandCompactionIncomplete;

  /// No description provided for @chatCommandPlanEnabled.
  ///
  /// In zh, this message translates to:
  /// **'已进入计划模式'**
  String get chatCommandPlanEnabled;

  /// No description provided for @chatCommandPlanEnabling.
  ///
  /// In zh, this message translates to:
  /// **'下一步起进入计划模式'**
  String get chatCommandPlanEnabling;

  /// No description provided for @chatCommandPlanDisabled.
  ///
  /// In zh, this message translates to:
  /// **'已退出计划模式'**
  String get chatCommandPlanDisabled;

  /// No description provided for @chatCommandPlanDisabling.
  ///
  /// In zh, this message translates to:
  /// **'下一步起退出计划模式'**
  String get chatCommandPlanDisabling;

  /// No description provided for @chatCommandPlanCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消进入计划模式'**
  String get chatCommandPlanCancelled;

  /// No description provided for @chatCommandPlanInactive.
  ///
  /// In zh, this message translates to:
  /// **'当前未开启计划模式'**
  String get chatCommandPlanInactive;

  /// No description provided for @chatCommandPlanNoAttachments.
  ///
  /// In zh, this message translates to:
  /// **'退出计划模式时不能附带文件'**
  String get chatCommandPlanNoAttachments;

  /// No description provided for @chatCommandNoGoal.
  ///
  /// In zh, this message translates to:
  /// **'还没有目标'**
  String get chatCommandNoGoal;

  /// No description provided for @chatCommandGoalRequired.
  ///
  /// In zh, this message translates to:
  /// **'写上新的目标再发送'**
  String get chatCommandGoalRequired;

  /// No description provided for @chatCommandGoalAttachments.
  ///
  /// In zh, this message translates to:
  /// **'附件需要和目标一起发送'**
  String get chatCommandGoalAttachments;

  /// No description provided for @chatCommandGoalCleared.
  ///
  /// In zh, this message translates to:
  /// **'已清除目标'**
  String get chatCommandGoalCleared;

  /// No description provided for @chatCommandGoalInvalid.
  ///
  /// In zh, this message translates to:
  /// **'当前无法执行，请查看目标'**
  String get chatCommandGoalInvalid;

  /// No description provided for @chatCommandGoalExists.
  ///
  /// In zh, this message translates to:
  /// **'已有目标，请编辑或清除后再设置'**
  String get chatCommandGoalExists;

  /// No description provided for @chatCommandGoalCreated.
  ///
  /// In zh, this message translates to:
  /// **'已设置目标'**
  String get chatCommandGoalCreated;

  /// No description provided for @chatCommandGoalUpdated.
  ///
  /// In zh, this message translates to:
  /// **'已更新目标'**
  String get chatCommandGoalUpdated;

  /// No description provided for @chatCommandGoalPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停目标'**
  String get chatCommandGoalPaused;

  /// No description provided for @chatCommandGoalResumed.
  ///
  /// In zh, this message translates to:
  /// **'已继续目标'**
  String get chatCommandGoalResumed;

  /// No description provided for @chatCommandCurrentGoal.
  ///
  /// In zh, this message translates to:
  /// **'当前目标'**
  String get chatCommandCurrentGoal;

  /// No description provided for @chatCommandGoalBlocked.
  ///
  /// In zh, this message translates to:
  /// **'等待处理'**
  String get chatCommandGoalBlocked;

  /// No description provided for @chatCommandGoalSummary.
  ///
  /// In zh, this message translates to:
  /// **'{title}\n{objective}\n{status} · 第 {rounds}/{max} 轮'**
  String chatCommandGoalSummary(String title, String objective, String status, int rounds, int max);

  /// No description provided for @chatCommandFailed.
  ///
  /// In zh, this message translates to:
  /// **'执行失败'**
  String get chatCommandFailed;

  /// No description provided for @chatImageStorageDenied.
  ///
  /// In zh, this message translates to:
  /// **'没有存储权限，未能保存'**
  String get chatImageStorageDenied;

  /// No description provided for @chatImageCannotSave.
  ///
  /// In zh, this message translates to:
  /// **'这张图片无法保存'**
  String get chatImageCannotSave;

  /// No description provided for @chatImageDownloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'图片下载失败，请重试'**
  String get chatImageDownloadFailed;

  /// No description provided for @chatImageSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败，请重试'**
  String get chatImageSaveFailed;

  /// No description provided for @chatImageSavedToPhotos.
  ///
  /// In zh, this message translates to:
  /// **'已保存到相册'**
  String get chatImageSavedToPhotos;

  /// No description provided for @chatShareFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开分享'**
  String get chatShareFailed;

  /// No description provided for @chatSubmit.
  ///
  /// In zh, this message translates to:
  /// **'提交'**
  String get chatSubmit;

  /// No description provided for @chatSelectText.
  ///
  /// In zh, this message translates to:
  /// **'选择文字'**
  String get chatSelectText;

  /// No description provided for @chatRegenerate.
  ///
  /// In zh, this message translates to:
  /// **'重新回答'**
  String get chatRegenerate;

  /// No description provided for @chatBranchFromHere.
  ///
  /// In zh, this message translates to:
  /// **'从这里分叉'**
  String get chatBranchFromHere;

  /// No description provided for @chatEditAndResend.
  ///
  /// In zh, this message translates to:
  /// **'编辑后重发'**
  String get chatEditAndResend;

  /// No description provided for @chatRegenerateHint.
  ///
  /// In zh, this message translates to:
  /// **'在新对话中重新生成，原对话不变'**
  String get chatRegenerateHint;

  /// No description provided for @chatBranchHint.
  ///
  /// In zh, this message translates to:
  /// **'在新对话中继续，原对话不变'**
  String get chatBranchHint;

  /// No description provided for @chatEditResendHint.
  ///
  /// In zh, this message translates to:
  /// **'在新对话中改写，图片和文件需重新添加；原对话不变'**
  String get chatEditResendHint;

  /// No description provided for @chatSaveToPhotos.
  ///
  /// In zh, this message translates to:
  /// **'保存到相册'**
  String get chatSaveToPhotos;

  /// No description provided for @chatCopyAll.
  ///
  /// In zh, this message translates to:
  /// **'全部复制'**
  String get chatCopyAll;

  /// No description provided for @chatRequestRetrying.
  ///
  /// In zh, this message translates to:
  /// **'请求失败，正在重试'**
  String get chatRequestRetrying;

  /// No description provided for @chatRequestRetryAttempt.
  ///
  /// In zh, this message translates to:
  /// **'请求失败，正在重试（第 {count} 次）'**
  String chatRequestRetryAttempt(int count);

  /// No description provided for @chatRequestRetryLimit.
  ///
  /// In zh, this message translates to:
  /// **'请求失败，正在重试（{count}/{max}）'**
  String chatRequestRetryLimit(int count, int max);

  /// No description provided for @chatProviderKeyMissing.
  ///
  /// In zh, this message translates to:
  /// **'这个模型渠道还没有密钥'**
  String get chatProviderKeyMissing;

  /// No description provided for @chatDeepSeekKeyMissing.
  ///
  /// In zh, this message translates to:
  /// **'还没有 DeepSeek API Key'**
  String get chatDeepSeekKeyMissing;

  /// No description provided for @chatOutputLimitReached.
  ///
  /// In zh, this message translates to:
  /// **'已达单次输出上限'**
  String get chatOutputLimitReached;

  /// No description provided for @chatTurnBlocked.
  ///
  /// In zh, this message translates to:
  /// **'本轮已被拦截'**
  String get chatTurnBlocked;

  /// No description provided for @chatTurnEngineRestarted.
  ///
  /// In zh, this message translates to:
  /// **'引擎重启过，本轮已中断'**
  String get chatTurnEngineRestarted;

  /// No description provided for @chatQuestionsTitle.
  ///
  /// In zh, this message translates to:
  /// **'有 {count} 个问题想问你'**
  String chatQuestionsTitle(int count);

  /// No description provided for @chatOneQuestion.
  ///
  /// In zh, this message translates to:
  /// **'有个问题想问你'**
  String get chatOneQuestion;

  /// No description provided for @chatMultipleChoices.
  ///
  /// In zh, this message translates to:
  /// **'可多选'**
  String get chatMultipleChoices;

  /// No description provided for @chatCustomAnswer.
  ///
  /// In zh, this message translates to:
  /// **'其他回答'**
  String get chatCustomAnswer;

  /// No description provided for @chatCustomAnswerHint.
  ///
  /// In zh, this message translates to:
  /// **'输入你的回答'**
  String get chatCustomAnswerHint;

  /// No description provided for @chatQuoteSemantics.
  ///
  /// In zh, this message translates to:
  /// **'引用：{text}'**
  String chatQuoteSemantics(String text);

  /// No description provided for @chatRemoveQuote.
  ///
  /// In zh, this message translates to:
  /// **'移除引用'**
  String get chatRemoveQuote;

  /// No description provided for @chatReadOnlySubagent.
  ///
  /// In zh, this message translates to:
  /// **'一次性子代理，只能查看'**
  String get chatReadOnlySubagent;

  /// No description provided for @chatThinkingActive.
  ///
  /// In zh, this message translates to:
  /// **'思考中'**
  String get chatThinkingActive;

  /// No description provided for @chatThinking.
  ///
  /// In zh, this message translates to:
  /// **'思考'**
  String get chatThinking;

  /// No description provided for @chatTranslate.
  ///
  /// In zh, this message translates to:
  /// **'翻译'**
  String get chatTranslate;

  /// No description provided for @chatTranslationUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'翻译暂不可用'**
  String get chatTranslationUnavailable;

  /// No description provided for @chatViewOriginal.
  ///
  /// In zh, this message translates to:
  /// **'查看原文'**
  String get chatViewOriginal;

  /// No description provided for @chatViewTranslation.
  ///
  /// In zh, this message translates to:
  /// **'查看译文'**
  String get chatViewTranslation;

  /// No description provided for @chatTranslating.
  ///
  /// In zh, this message translates to:
  /// **'正在翻译'**
  String get chatTranslating;

  /// No description provided for @chatToolFailures.
  ///
  /// In zh, this message translates to:
  /// **'{label},{count} 个失败'**
  String chatToolFailures(String label, int count);

  /// No description provided for @chatToolNeedsApproval.
  ///
  /// In zh, this message translates to:
  /// **'需要授权后才能执行'**
  String get chatToolNeedsApproval;

  /// No description provided for @chatCommand.
  ///
  /// In zh, this message translates to:
  /// **'命令'**
  String get chatCommand;

  /// No description provided for @chatToolLineRange.
  ///
  /// In zh, this message translates to:
  /// **' · 第 {first}⁠–⁠{last} 行'**
  String chatToolLineRange(int first, int last);

  /// No description provided for @chatParameters.
  ///
  /// In zh, this message translates to:
  /// **'参数'**
  String get chatParameters;

  /// No description provided for @chatOutput.
  ///
  /// In zh, this message translates to:
  /// **'输出'**
  String get chatOutput;

  /// No description provided for @chatResult.
  ///
  /// In zh, this message translates to:
  /// **'结果'**
  String get chatResult;

  /// No description provided for @chatError.
  ///
  /// In zh, this message translates to:
  /// **'错误'**
  String get chatError;

  /// No description provided for @chatChanges.
  ///
  /// In zh, this message translates to:
  /// **'改动'**
  String get chatChanges;

  /// No description provided for @chatContent.
  ///
  /// In zh, this message translates to:
  /// **'内容'**
  String get chatContent;

  /// No description provided for @chatNoOutput.
  ///
  /// In zh, this message translates to:
  /// **'没有输出'**
  String get chatNoOutput;

  /// No description provided for @chatToolDeclined.
  ///
  /// In zh, this message translates to:
  /// **'已拒绝这次调用'**
  String get chatToolDeclined;

  /// No description provided for @chatToolRunning.
  ///
  /// In zh, this message translates to:
  /// **'正在执行…'**
  String get chatToolRunning;

  /// No description provided for @chatNoDetails.
  ///
  /// In zh, this message translates to:
  /// **'暂无详情'**
  String get chatNoDetails;

  /// No description provided for @chatOutputHiddenLines.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{中间省略 {shown} 行}}'**
  String chatOutputHiddenLines(int count, String shown);

  /// No description provided for @chatOutputHiddenChars.
  ///
  /// In zh, this message translates to:
  /// **'中间省略 {count} 字'**
  String chatOutputHiddenChars(String count);

  /// No description provided for @chatOutputSummary.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{共 {lines} 行}} · {chars} 字'**
  String chatOutputSummary(int count, String lines, String chars);

  /// No description provided for @chatOutputViewAll.
  ///
  /// In zh, this message translates to:
  /// **'查看全部'**
  String get chatOutputViewAll;

  /// No description provided for @chatOutputCopyAll.
  ///
  /// In zh, this message translates to:
  /// **'复制全文'**
  String get chatOutputCopyAll;

  /// No description provided for @chatOutputCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制全文'**
  String get chatOutputCopied;

  /// No description provided for @chatOutputToEnd.
  ///
  /// In zh, this message translates to:
  /// **'跳到末尾'**
  String get chatOutputToEnd;

  /// No description provided for @chatOutputToStart.
  ///
  /// In zh, this message translates to:
  /// **'回到开头'**
  String get chatOutputToStart;

  /// No description provided for @chatErrApiKey.
  ///
  /// In zh, this message translates to:
  /// **'API Key 无效或已过期'**
  String get chatErrApiKey;

  /// No description provided for @chatErrForbidden.
  ///
  /// In zh, this message translates to:
  /// **'凭据不可用或权限不足'**
  String get chatErrForbidden;

  /// No description provided for @chatErrBalance.
  ///
  /// In zh, this message translates to:
  /// **'余额不足'**
  String get chatErrBalance;

  /// No description provided for @chatErrAccountQuota.
  ///
  /// In zh, this message translates to:
  /// **'账号额度已用完'**
  String get chatErrAccountQuota;

  /// No description provided for @chatErrRateLimit.
  ///
  /// In zh, this message translates to:
  /// **'请求太频繁，稍后再试'**
  String get chatErrRateLimit;

  /// No description provided for @chatErrContextLength.
  ///
  /// In zh, this message translates to:
  /// **'对话太长。若 /compact 也失败，请新建对话或换模型'**
  String get chatErrContextLength;

  /// No description provided for @chatErrModelUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'模型服务暂时不可用'**
  String get chatErrModelUnavailable;

  /// No description provided for @chatErrModelTimeout.
  ///
  /// In zh, this message translates to:
  /// **'模型响应超时'**
  String get chatErrModelTimeout;

  /// No description provided for @chatErrModelConnection.
  ///
  /// In zh, this message translates to:
  /// **'没能连上模型服务'**
  String get chatErrModelConnection;

  /// No description provided for @chatErrModelEmpty.
  ///
  /// In zh, this message translates to:
  /// **'模型没有返回内容'**
  String get chatErrModelEmpty;

  /// No description provided for @chatErrEngineOutdated.
  ///
  /// In zh, this message translates to:
  /// **'这个模型需要新版引擎'**
  String get chatErrEngineOutdated;

  /// No description provided for @chatErrModelUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前模型不可用'**
  String get chatErrModelUnsupported;

  /// No description provided for @chatSwitchModel.
  ///
  /// In zh, this message translates to:
  /// **'换模型'**
  String get chatSwitchModel;

  /// No description provided for @chatErrTurn.
  ///
  /// In zh, this message translates to:
  /// **'本轮出错了'**
  String get chatErrTurn;

  /// No description provided for @chatTurnSteps.
  ///
  /// In zh, this message translates to:
  /// **'{count} 步'**
  String chatTurnSteps(int count);

  /// No description provided for @chatTurnFootnoteSemantics.
  ///
  /// In zh, this message translates to:
  /// **'本轮 {summary}，查看本轮轨迹'**
  String chatTurnFootnoteSemantics(String summary);

  /// No description provided for @chatTurnToolCalls.
  ///
  /// In zh, this message translates to:
  /// **'{count} 次工具调用'**
  String chatTurnToolCalls(int count);

  /// No description provided for @chatTurnMessages.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条消息'**
  String chatTurnMessages(int count);

  /// No description provided for @chatTurnThoughts.
  ///
  /// In zh, this message translates to:
  /// **'{count} 段思考'**
  String chatTurnThoughts(int count);

  /// No description provided for @chatGoalSemantics.
  ///
  /// In zh, this message translates to:
  /// **'目标，{objective}'**
  String chatGoalSemantics(String objective);

  /// No description provided for @chatGoalStateSemantics.
  ///
  /// In zh, this message translates to:
  /// **'目标，{objective}，{state}'**
  String chatGoalStateSemantics(String objective, String state);

  /// No description provided for @chatTodoItemSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{content}，{state}'**
  String chatTodoItemSemantics(String content, String state);

  /// No description provided for @chatMentionSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{kind}：{label}'**
  String chatMentionSemantics(String kind, String label);

  /// No description provided for @chatArtifactSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{name}，{description}'**
  String chatArtifactSemantics(String name, String description);

  /// No description provided for @commonMonthDay.
  ///
  /// In zh, this message translates to:
  /// **'{month}月{day}日'**
  String commonMonthDay(int month, int day);

  /// No description provided for @commonOpenBrowserHost.
  ///
  /// In zh, this message translates to:
  /// **'在浏览器打开 {host}？'**
  String commonOpenBrowserHost(String host);

  /// No description provided for @commonCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get commonCancel;

  /// No description provided for @commonRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get commonRetry;

  /// No description provided for @commonClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get commonClose;

  /// No description provided for @commonCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制'**
  String get commonCopied;

  /// No description provided for @commonSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get commonSave;

  /// No description provided for @commonSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get commonSettings;

  /// No description provided for @commonBack.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get commonBack;

  /// No description provided for @commonCopy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get commonCopy;

  /// No description provided for @commonDone.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get commonDone;

  /// No description provided for @commonDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get commonDelete;

  /// No description provided for @commonShare.
  ///
  /// In zh, this message translates to:
  /// **'分享'**
  String get commonShare;

  /// No description provided for @commonAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get commonAdd;

  /// No description provided for @commonEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get commonEdit;

  /// No description provided for @commonClear.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get commonClear;

  /// No description provided for @commonCollapse.
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get commonCollapse;

  /// No description provided for @commonOpen.
  ///
  /// In zh, this message translates to:
  /// **'打开'**
  String get commonOpen;

  /// No description provided for @commonDetails.
  ///
  /// In zh, this message translates to:
  /// **'详情'**
  String get commonDetails;

  /// No description provided for @commonMore.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get commonMore;

  /// No description provided for @commonCreate.
  ///
  /// In zh, this message translates to:
  /// **'创建'**
  String get commonCreate;

  /// No description provided for @commonSend.
  ///
  /// In zh, this message translates to:
  /// **'发送'**
  String get commonSend;

  /// No description provided for @commonPaste.
  ///
  /// In zh, this message translates to:
  /// **'粘贴'**
  String get commonPaste;

  /// No description provided for @commonConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get commonConfirm;

  /// No description provided for @commonRename.
  ///
  /// In zh, this message translates to:
  /// **'重命名'**
  String get commonRename;

  /// No description provided for @commonContinue.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get commonContinue;

  /// No description provided for @commonDefault.
  ///
  /// In zh, this message translates to:
  /// **'默认'**
  String get commonDefault;

  /// No description provided for @commonSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get commonSaved;

  /// No description provided for @commonSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能保存'**
  String get commonSaveFailed;

  /// No description provided for @commonSaveFailedRetry.
  ///
  /// In zh, this message translates to:
  /// **'没能保存，请重试'**
  String get commonSaveFailedRetry;

  /// No description provided for @commonFailedTryAgain.
  ///
  /// In zh, this message translates to:
  /// **'没能完成，再试一次'**
  String get commonFailedTryAgain;

  /// No description provided for @commonEngineUnreachable.
  ///
  /// In zh, this message translates to:
  /// **'没能连上引擎'**
  String get commonEngineUnreachable;

  /// No description provided for @commonConnectionFailed.
  ///
  /// In zh, this message translates to:
  /// **'连接失败'**
  String get commonConnectionFailed;

  /// No description provided for @commonCopyLink.
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get commonCopyLink;

  /// No description provided for @commonOpenWith.
  ///
  /// In zh, this message translates to:
  /// **'用其他应用打开'**
  String get commonOpenWith;

  /// No description provided for @commonUntitledChat.
  ///
  /// In zh, this message translates to:
  /// **'未命名对话'**
  String get commonUntitledChat;

  /// No description provided for @commonNewChat.
  ///
  /// In zh, this message translates to:
  /// **'新对话'**
  String get commonNewChat;

  /// No description provided for @commonYesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天'**
  String get commonYesterday;

  /// No description provided for @commonSignIn.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get commonSignIn;

  /// No description provided for @commonThisPhone.
  ///
  /// In zh, this message translates to:
  /// **'本机'**
  String get commonThisPhone;

  /// No description provided for @commonRemoteHost.
  ///
  /// In zh, this message translates to:
  /// **'远程主机'**
  String get commonRemoteHost;

  /// No description provided for @commonFollowSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get commonFollowSystem;

  /// No description provided for @commonLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get commonLight;

  /// No description provided for @commonDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get commonDark;

  /// No description provided for @commonInProgress.
  ///
  /// In zh, this message translates to:
  /// **'进行中'**
  String get commonInProgress;

  /// No description provided for @commonCompleted.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get commonCompleted;

  /// No description provided for @commonStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止'**
  String get commonStopped;

  /// No description provided for @commonCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消'**
  String get commonCancelled;

  /// No description provided for @commonRunning.
  ///
  /// In zh, this message translates to:
  /// **'运行中'**
  String get commonRunning;

  /// No description provided for @commonPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get commonPaused;

  /// No description provided for @commonDeclined.
  ///
  /// In zh, this message translates to:
  /// **'已拒绝'**
  String get commonDeclined;

  /// No description provided for @commonFailed.
  ///
  /// In zh, this message translates to:
  /// **'失败'**
  String get commonFailed;

  /// No description provided for @commonStopping.
  ///
  /// In zh, this message translates to:
  /// **'正在停止'**
  String get commonStopping;

  /// No description provided for @commonWaitingApproval.
  ///
  /// In zh, this message translates to:
  /// **'等你确认'**
  String get commonWaitingApproval;

  /// No description provided for @commonWaitingAnswer.
  ///
  /// In zh, this message translates to:
  /// **'等你回答'**
  String get commonWaitingAnswer;

  /// No description provided for @commonNotConnected.
  ///
  /// In zh, this message translates to:
  /// **'未连接'**
  String get commonNotConnected;

  /// No description provided for @commonName.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get commonName;

  /// No description provided for @commonStatus.
  ///
  /// In zh, this message translates to:
  /// **'状态'**
  String get commonStatus;

  /// No description provided for @commonVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本'**
  String get commonVersion;

  /// No description provided for @commonOther.
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get commonOther;

  /// No description provided for @commonPin.
  ///
  /// In zh, this message translates to:
  /// **'置顶'**
  String get commonPin;

  /// No description provided for @commonReply.
  ///
  /// In zh, this message translates to:
  /// **'回复'**
  String get commonReply;

  /// No description provided for @commonItemCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 项'**
  String commonItemCount(int count);

  /// No description provided for @engineNewChatDefaultsLast.
  ///
  /// In zh, this message translates to:
  /// **'新对话默认（上次选择）'**
  String get engineNewChatDefaultsLast;

  /// No description provided for @engineNewChatDefaultsFixed.
  ///
  /// In zh, this message translates to:
  /// **'新对话默认（固定）'**
  String get engineNewChatDefaultsFixed;

  /// No description provided for @engineNewChatUseLast.
  ///
  /// In zh, this message translates to:
  /// **'沿用上次'**
  String get engineNewChatUseLast;

  /// No description provided for @engineNewChatUseFixed.
  ///
  /// In zh, this message translates to:
  /// **'固定默认'**
  String get engineNewChatUseFixed;

  /// No description provided for @engineNewChatDefaultsHint.
  ///
  /// In zh, this message translates to:
  /// **'保存在当前主机，只影响新对话的模型和思考深度。权限仍用独立默认，不继承临时会话授权。'**
  String get engineNewChatDefaultsHint;

  /// No description provided for @engineNewChatDefaultsLegacy.
  ///
  /// In zh, this message translates to:
  /// **'此引擎仅支持沿用上次选择；不支持固定默认，也无法确认切换时默认值是否保存成功。'**
  String get engineNewChatDefaultsLegacy;

  /// No description provided for @engineNewChatDefaultsUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'此主机没有可编辑的默认模型设置'**
  String get engineNewChatDefaultsUnsupported;

  /// No description provided for @engineNewChatDefaultsSelectionUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'此模型或思考深度已不可用，请重新选择。'**
  String get engineNewChatDefaultsSelectionUnavailable;

  /// No description provided for @engineNewChatDefaultsInheritedEffort.
  ///
  /// In zh, this message translates to:
  /// **'主机基础配置指定了思考深度，不能在这里为无思考模型清除。请先调整主机配置。'**
  String get engineNewChatDefaultsInheritedEffort;

  /// No description provided for @engineNewChatDefaultsSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存并确认默认值…'**
  String get engineNewChatDefaultsSaving;

  /// No description provided for @engineNewChatDefaultsUnconfirmed.
  ///
  /// In zh, this message translates to:
  /// **'没能确认完整默认值，请刷新后检查模型和思考深度。主机基础配置或其他客户端可能已改变它们。'**
  String get engineNewChatDefaultsUnconfirmed;

  /// No description provided for @engineModelDefaultSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'当前对话的模型已切换，但新对话默认未保存。请到设置 › 模型检查并重试。'**
  String get engineModelDefaultSaveFailed;

  /// No description provided for @engineSettingsReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取设置'**
  String get engineSettingsReadFailed;

  /// No description provided for @engineProviderHeaderInvalidName.
  ///
  /// In zh, this message translates to:
  /// **'请求头名称只能包含英文字母、数字或 HTTP 标记符号，不能包含空格或冒号'**
  String get engineProviderHeaderInvalidName;

  /// No description provided for @engineProviderHeaderReserved.
  ///
  /// In zh, this message translates to:
  /// **'User-Agent 由引擎设置，请移除此请求头'**
  String get engineProviderHeaderReserved;

  /// No description provided for @engineProviderHeaderDuplicate.
  ///
  /// In zh, this message translates to:
  /// **'请求头名称重复（不区分大小写）'**
  String get engineProviderHeaderDuplicate;

  /// No description provided for @engineProviderHeaderInvalidValue.
  ///
  /// In zh, this message translates to:
  /// **'请求头值只能包含单行 Latin-1 文本，不支持换行或控制字符（制表符除外）'**
  String get engineProviderHeaderInvalidValue;

  /// No description provided for @engineProviderReady.
  ///
  /// In zh, this message translates to:
  /// **'可用'**
  String get engineProviderReady;

  /// No description provided for @engineProviderMissingKey.
  ///
  /// In zh, this message translates to:
  /// **'缺少 API Key'**
  String get engineProviderMissingKey;

  /// No description provided for @engineProviderMisconfigured.
  ///
  /// In zh, this message translates to:
  /// **'配置有误'**
  String get engineProviderMisconfigured;

  /// No description provided for @engineProviderInactive.
  ///
  /// In zh, this message translates to:
  /// **'未启用'**
  String get engineProviderInactive;

  /// No description provided for @engineProviderConfiguredInWeb.
  ///
  /// In zh, this message translates to:
  /// **'网页版配置'**
  String get engineProviderConfiguredInWeb;

  /// No description provided for @engineProvidersStartEngine.
  ///
  /// In zh, this message translates to:
  /// **'引擎运行后可添加渠道'**
  String get engineProvidersStartEngine;

  /// No description provided for @engineProvidersReadOnly.
  ///
  /// In zh, this message translates to:
  /// **'引擎设置是只读的，无法添加'**
  String get engineProvidersReadOnly;

  /// No description provided for @engineProviderContext.
  ///
  /// In zh, this message translates to:
  /// **'上下文 {size}'**
  String engineProviderContext(String size);

  /// No description provided for @engineProviderModels.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个模型'**
  String engineProviderModels(int count);

  /// No description provided for @engineModelThinking.
  ///
  /// In zh, this message translates to:
  /// **'思考'**
  String get engineModelThinking;

  /// No description provided for @engineModelVision.
  ///
  /// In zh, this message translates to:
  /// **'识图'**
  String get engineModelVision;

  /// No description provided for @engineSettingsHostChanged.
  ///
  /// In zh, this message translates to:
  /// **'主机已切换，请重新打开设置后编辑。'**
  String get engineSettingsHostChanged;

  /// No description provided for @engineSecretTargetChanged.
  ///
  /// In zh, this message translates to:
  /// **'此项已变化，请重新打开后编辑。'**
  String get engineSecretTargetChanged;

  /// No description provided for @featuresCurrentChat.
  ///
  /// In zh, this message translates to:
  /// **'当前对话'**
  String get featuresCurrentChat;

  /// No description provided for @featuresPresetDefaultSet.
  ///
  /// In zh, this message translates to:
  /// **'新对话将使用「{name}」'**
  String featuresPresetDefaultSet(String name);

  /// No description provided for @featuresPresetDefaultFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能设为默认'**
  String get featuresPresetDefaultFailed;

  /// No description provided for @featuresPresetDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除「{name}」？'**
  String featuresPresetDeleteTitle(String name);

  /// No description provided for @featuresPresetDeleteHint.
  ///
  /// In zh, this message translates to:
  /// **'新对话不能再选它，已开始的对话不受影响。'**
  String get featuresPresetDeleteHint;

  /// No description provided for @featuresDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除'**
  String get featuresDeleted;

  /// No description provided for @featuresDeleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能删除'**
  String get featuresDeleteFailed;

  /// No description provided for @featuresPresetAlreadyDefault.
  ///
  /// In zh, this message translates to:
  /// **'已是新对话默认'**
  String get featuresPresetAlreadyDefault;

  /// No description provided for @featuresPresetSetDefault.
  ///
  /// In zh, this message translates to:
  /// **'设为新对话默认'**
  String get featuresPresetSetDefault;

  /// No description provided for @featuresPresetViewConfig.
  ///
  /// In zh, this message translates to:
  /// **'查看配置'**
  String get featuresPresetViewConfig;

  /// No description provided for @featuresPresetDuplicate.
  ///
  /// In zh, this message translates to:
  /// **'复制为新预设'**
  String get featuresPresetDuplicate;

  /// No description provided for @featuresPresetDefaultDeleteHint.
  ///
  /// In zh, this message translates to:
  /// **'先把别的预设设为新对话默认'**
  String get featuresPresetDefaultDeleteHint;

  /// No description provided for @featuresAgentPresets.
  ///
  /// In zh, this message translates to:
  /// **'Agent 预设'**
  String get featuresAgentPresets;

  /// No description provided for @featuresAgentPresetsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'新对话的工具与工作方式'**
  String get featuresAgentPresetsSubtitle;

  /// No description provided for @featuresNew.
  ///
  /// In zh, this message translates to:
  /// **'新建'**
  String get featuresNew;

  /// No description provided for @featuresPresetsReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取 Agent 预设'**
  String get featuresPresetsReadFailed;

  /// No description provided for @featuresLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get featuresLoadFailed;

  /// No description provided for @featuresNewChatDefault.
  ///
  /// In zh, this message translates to:
  /// **'新对话默认'**
  String get featuresNewChatDefault;

  /// No description provided for @featuresEmptyDocument.
  ///
  /// In zh, this message translates to:
  /// **'（空）'**
  String get featuresEmptyDocument;

  /// No description provided for @featuresReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取'**
  String get featuresReadFailed;

  /// No description provided for @featuresTodayTime.
  ///
  /// In zh, this message translates to:
  /// **'今天 {time}'**
  String featuresTodayTime(String time);

  /// No description provided for @featuresTomorrowTime.
  ///
  /// In zh, this message translates to:
  /// **'明天 {time}'**
  String featuresTomorrowTime(String time);

  /// No description provided for @featuresYesterdayTime.
  ///
  /// In zh, this message translates to:
  /// **'昨天 {time}'**
  String featuresYesterdayTime(String time);

  /// No description provided for @featuresScheduleSummaryNext.
  ///
  /// In zh, this message translates to:
  /// **'{rule} · 下次 {time}'**
  String featuresScheduleSummaryNext(String rule, String time);

  /// No description provided for @featuresEnded.
  ///
  /// In zh, this message translates to:
  /// **'已结束'**
  String get featuresEnded;

  /// No description provided for @featuresScheduleSummaryEnded.
  ///
  /// In zh, this message translates to:
  /// **'已结束 · {time} 运行过'**
  String featuresScheduleSummaryEnded(String time);

  /// No description provided for @featuresJobElapsed.
  ///
  /// In zh, this message translates to:
  /// **'已运行 {span}'**
  String featuresJobElapsed(String span);

  /// No description provided for @featuresJobDuration.
  ///
  /// In zh, this message translates to:
  /// **'用时 {span}'**
  String featuresJobDuration(String span);

  /// No description provided for @featuresPermissionReadOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅可查看'**
  String get featuresPermissionReadOnly;

  /// No description provided for @featuresPermissionWorkspaceWrite.
  ///
  /// In zh, this message translates to:
  /// **'工作区内修改'**
  String get featuresPermissionWorkspaceWrite;

  /// No description provided for @featuresPermissionFullAccess.
  ///
  /// In zh, this message translates to:
  /// **'完全权限'**
  String get featuresPermissionFullAccess;

  /// No description provided for @featuresPermissionAutoReview.
  ///
  /// In zh, this message translates to:
  /// **'自动审查'**
  String get featuresPermissionAutoReview;

  /// No description provided for @featuresPermissionCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get featuresPermissionCustom;

  /// No description provided for @featuresPermissionReadOnlyHint.
  ///
  /// In zh, this message translates to:
  /// **'只看文件，不做修改'**
  String get featuresPermissionReadOnlyHint;

  /// No description provided for @featuresPermissionWorkspaceWriteHint.
  ///
  /// In zh, this message translates to:
  /// **'可改工作区内的文件，越界先问你'**
  String get featuresPermissionWorkspaceWriteHint;

  /// No description provided for @featuresPermissionFullAccessHint.
  ///
  /// In zh, this message translates to:
  /// **'不再确认，直接执行'**
  String get featuresPermissionFullAccessHint;

  /// No description provided for @featuresPermissionAutoReviewHint.
  ///
  /// In zh, this message translates to:
  /// **'由模型逐次审查，拿不准再问你'**
  String get featuresPermissionAutoReviewHint;

  /// No description provided for @featuresPresetStandard.
  ///
  /// In zh, this message translates to:
  /// **'标准模式'**
  String get featuresPresetStandard;

  /// No description provided for @featuresPresetPtc.
  ///
  /// In zh, this message translates to:
  /// **'PTC 模式'**
  String get featuresPresetPtc;

  /// No description provided for @featuresPresetMinimal.
  ///
  /// In zh, this message translates to:
  /// **'极简模式'**
  String get featuresPresetMinimal;

  /// No description provided for @featuresPresetCreator.
  ///
  /// In zh, this message translates to:
  /// **'创造模式'**
  String get featuresPresetCreator;

  /// No description provided for @featuresPresetStandardDescription.
  ///
  /// In zh, this message translates to:
  /// **'代码、文件和资料，适合大多数任务'**
  String get featuresPresetStandardDescription;

  /// No description provided for @featuresPresetPtcDescription.
  ///
  /// In zh, this message translates to:
  /// **'批量调用工具，再筛选、统计、汇总'**
  String get featuresPresetPtcDescription;

  /// No description provided for @featuresPresetMinimalDescription.
  ///
  /// In zh, this message translates to:
  /// **'只用终端和读图，适合测试对比'**
  String get featuresPresetMinimalDescription;

  /// No description provided for @featuresPresetCreatorDescription.
  ///
  /// In zh, this message translates to:
  /// **'让 Agent 写插件，定制 DSH 本身'**
  String get featuresPresetCreatorDescription;

  /// No description provided for @featuresHostUnreachable.
  ///
  /// In zh, this message translates to:
  /// **'连不上「{name}」'**
  String featuresHostUnreachable(String name);

  /// No description provided for @featuresHostConnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接「{name}」…'**
  String featuresHostConnecting(String name);

  /// No description provided for @featuresPermissionAutoTitle.
  ///
  /// In zh, this message translates to:
  /// **'开启自动审查？'**
  String get featuresPermissionAutoTitle;

  /// No description provided for @featuresPermissionAutoWarning.
  ///
  /// In zh, this message translates to:
  /// **'每次操作由模型判断放不放行，可能误判。'**
  String get featuresPermissionAutoWarning;

  /// No description provided for @featuresSwitchFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能切换'**
  String get featuresSwitchFailed;

  /// No description provided for @featuresPermissions.
  ///
  /// In zh, this message translates to:
  /// **'权限'**
  String get featuresPermissions;

  /// No description provided for @featuresPermissionsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'执行命令、修改文件前，要不要先问你'**
  String get featuresPermissionsSubtitle;

  /// No description provided for @featuresPermissionsReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取权限设置'**
  String get featuresPermissionsReadFailed;

  /// No description provided for @featuresPermissionCustomHint.
  ///
  /// In zh, this message translates to:
  /// **'当前用的是自定义权限，选预设会替换它'**
  String get featuresPermissionCustomHint;

  /// No description provided for @featuresModuleInstructions.
  ///
  /// In zh, this message translates to:
  /// **'工作区指令加载'**
  String get featuresModuleInstructions;

  /// No description provided for @featuresModuleTime.
  ///
  /// In zh, this message translates to:
  /// **'时间感知'**
  String get featuresModuleTime;

  /// No description provided for @featuresModuleBash.
  ///
  /// In zh, this message translates to:
  /// **'Bash 命令工具'**
  String get featuresModuleBash;

  /// No description provided for @featuresModulePersistentBash.
  ///
  /// In zh, this message translates to:
  /// **'持久 Bash 工具'**
  String get featuresModulePersistentBash;

  /// No description provided for @featuresModulePowerShell.
  ///
  /// In zh, this message translates to:
  /// **'PowerShell 命令工具'**
  String get featuresModulePowerShell;

  /// No description provided for @featuresModuleFiles.
  ///
  /// In zh, this message translates to:
  /// **'文件读写工具'**
  String get featuresModuleFiles;

  /// No description provided for @featuresModuleFileSearch.
  ///
  /// In zh, this message translates to:
  /// **'文件搜索工具'**
  String get featuresModuleFileSearch;

  /// No description provided for @featuresModuleJobs.
  ///
  /// In zh, this message translates to:
  /// **'后台任务工具'**
  String get featuresModuleJobs;

  /// No description provided for @featuresModuleSchedule.
  ///
  /// In zh, this message translates to:
  /// **'自动化任务工具'**
  String get featuresModuleSchedule;

  /// No description provided for @featuresModuleLocalSkills.
  ///
  /// In zh, this message translates to:
  /// **'本地技能加载'**
  String get featuresModuleLocalSkills;

  /// No description provided for @featuresModuleSkillTool.
  ///
  /// In zh, this message translates to:
  /// **'技能加载工具'**
  String get featuresModuleSkillTool;

  /// No description provided for @featuresModuleGoalCommand.
  ///
  /// In zh, this message translates to:
  /// **'目标管理命令'**
  String get featuresModuleGoalCommand;

  /// No description provided for @featuresModuleGoalTool.
  ///
  /// In zh, this message translates to:
  /// **'目标管理工具'**
  String get featuresModuleGoalTool;

  /// No description provided for @featuresModulePlan.
  ///
  /// In zh, this message translates to:
  /// **'计划模式'**
  String get featuresModulePlan;

  /// No description provided for @featuresModuleCompaction.
  ///
  /// In zh, this message translates to:
  /// **'上下文压缩'**
  String get featuresModuleCompaction;

  /// No description provided for @featuresModuleCompactCommand.
  ///
  /// In zh, this message translates to:
  /// **'上下文压缩命令'**
  String get featuresModuleCompactCommand;

  /// No description provided for @featuresModuleAskUser.
  ///
  /// In zh, this message translates to:
  /// **'向用户提问工具'**
  String get featuresModuleAskUser;

  /// No description provided for @featuresModuleTodo.
  ///
  /// In zh, this message translates to:
  /// **'待办清单工具'**
  String get featuresModuleTodo;

  /// No description provided for @featuresModuleWeb.
  ///
  /// In zh, this message translates to:
  /// **'网页搜索与读取工具'**
  String get featuresModuleWeb;

  /// No description provided for @featuresModulePresent.
  ///
  /// In zh, this message translates to:
  /// **'文件交付工具'**
  String get featuresModulePresent;

  /// No description provided for @featuresModuleCordis.
  ///
  /// In zh, this message translates to:
  /// **'插件 API 查询工具'**
  String get featuresModuleCordis;

  /// No description provided for @featuresModuleSubagent.
  ///
  /// In zh, this message translates to:
  /// **'子代理委派工具'**
  String get featuresModuleSubagent;

  /// No description provided for @featuresModuleSubagentControl.
  ///
  /// In zh, this message translates to:
  /// **'子代理控制工具'**
  String get featuresModuleSubagentControl;

  /// No description provided for @featuresModuleWorkflow.
  ///
  /// In zh, this message translates to:
  /// **'工作流工具'**
  String get featuresModuleWorkflow;

  /// No description provided for @featuresModulePluginManager.
  ///
  /// In zh, this message translates to:
  /// **'插件管理工具'**
  String get featuresModulePluginManager;

  /// No description provided for @featuresModulePluginMarket.
  ///
  /// In zh, this message translates to:
  /// **'插件市场工具'**
  String get featuresModulePluginMarket;

  /// No description provided for @featuresModuleToolCalls.
  ///
  /// In zh, this message translates to:
  /// **'工具调用方式'**
  String get featuresModuleToolCalls;

  /// No description provided for @featuresModuleTerminal.
  ///
  /// In zh, this message translates to:
  /// **'持久终端服务'**
  String get featuresModuleTerminal;

  /// No description provided for @featuresModulePersona.
  ///
  /// In zh, this message translates to:
  /// **'智能体角色设定'**
  String get featuresModulePersona;

  /// No description provided for @featuresGroupDelegation.
  ///
  /// In zh, this message translates to:
  /// **'子代理委派'**
  String get featuresGroupDelegation;

  /// No description provided for @featuresGroupTerminal.
  ///
  /// In zh, this message translates to:
  /// **'持久终端'**
  String get featuresGroupTerminal;

  /// No description provided for @featuresPresetIdRequired.
  ///
  /// In zh, this message translates to:
  /// **'填写标识'**
  String get featuresPresetIdRequired;

  /// No description provided for @featuresPresetIdLength.
  ///
  /// In zh, this message translates to:
  /// **'最多 40 个字符'**
  String get featuresPresetIdLength;

  /// No description provided for @featuresPresetIdFormat.
  ///
  /// In zh, this message translates to:
  /// **'只用小写字母、数字和连字符'**
  String get featuresPresetIdFormat;

  /// No description provided for @featuresPresetIdTaken.
  ///
  /// In zh, this message translates to:
  /// **'这个标识已被使用'**
  String get featuresPresetIdTaken;

  /// No description provided for @featuresPresetCopyName.
  ///
  /// In zh, this message translates to:
  /// **'{name} 副本'**
  String featuresPresetCopyName(String name);

  /// No description provided for @featuresPresetBasedOn.
  ///
  /// In zh, this message translates to:
  /// **'基于'**
  String get featuresPresetBasedOn;

  /// No description provided for @featuresNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'填写名称'**
  String get featuresNameRequired;

  /// No description provided for @featuresCreatorOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能打开创造模式'**
  String get featuresCreatorOpenFailed;

  /// No description provided for @featuresPresetNameHint.
  ///
  /// In zh, this message translates to:
  /// **'比如：代码审查'**
  String get featuresPresetNameHint;

  /// No description provided for @featuresPresetId.
  ///
  /// In zh, this message translates to:
  /// **'标识'**
  String get featuresPresetId;

  /// No description provided for @featuresPresetIdHint.
  ///
  /// In zh, this message translates to:
  /// **'小写字母、数字和连字符'**
  String get featuresPresetIdHint;

  /// No description provided for @featuresPresetDescription.
  ///
  /// In zh, this message translates to:
  /// **'说明'**
  String get featuresPresetDescription;

  /// No description provided for @featuresPresetDescriptionHint.
  ///
  /// In zh, this message translates to:
  /// **'一句话说明它适合做什么'**
  String get featuresPresetDescriptionHint;

  /// No description provided for @featuresPresetConfigReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取预设配置'**
  String get featuresPresetConfigReadFailed;

  /// No description provided for @featuresPresetCreateTitle.
  ///
  /// In zh, this message translates to:
  /// **'新建 Agent 预设'**
  String get featuresPresetCreateTitle;

  /// No description provided for @featuresPresetDuplicateTitle.
  ///
  /// In zh, this message translates to:
  /// **'复制 Agent 预设'**
  String get featuresPresetDuplicateTitle;

  /// No description provided for @featuresPresetEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑 Agent 预设'**
  String get featuresPresetEditTitle;

  /// No description provided for @featuresCreatorOpening.
  ///
  /// In zh, this message translates to:
  /// **'正在打开创造模式'**
  String get featuresCreatorOpening;

  /// No description provided for @featuresWaitingEngine.
  ///
  /// In zh, this message translates to:
  /// **'等待引擎连接'**
  String get featuresWaitingEngine;

  /// No description provided for @featuresCreatorUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'创造模式不可用'**
  String get featuresCreatorUnavailable;

  /// No description provided for @featuresPresetStartUpdate.
  ///
  /// In zh, this message translates to:
  /// **'开始更新'**
  String get featuresPresetStartUpdate;

  /// No description provided for @featuresPresetStartCreate.
  ///
  /// In zh, this message translates to:
  /// **'开始创建'**
  String get featuresPresetStartCreate;

  /// No description provided for @featuresPresetSystemPrompt.
  ///
  /// In zh, this message translates to:
  /// **'系统提示'**
  String get featuresPresetSystemPrompt;

  /// No description provided for @featuresPresetSystemPromptHint.
  ///
  /// In zh, this message translates to:
  /// **'你是谁、怎么工作'**
  String get featuresPresetSystemPromptHint;

  /// No description provided for @featuresPresetReplaceSystemPrompt.
  ///
  /// In zh, this message translates to:
  /// **'完整替换系统提示'**
  String get featuresPresetReplaceSystemPrompt;

  /// No description provided for @featuresPresetTools.
  ///
  /// In zh, this message translates to:
  /// **'工具'**
  String get featuresPresetTools;

  /// No description provided for @featuresSkills.
  ///
  /// In zh, this message translates to:
  /// **'技能'**
  String get featuresSkills;

  /// No description provided for @featuresPresetContextModes.
  ///
  /// In zh, this message translates to:
  /// **'上下文与模式'**
  String get featuresPresetContextModes;

  /// No description provided for @featuresCronMinute.
  ///
  /// In zh, this message translates to:
  /// **'分钟'**
  String get featuresCronMinute;

  /// No description provided for @featuresCronHour.
  ///
  /// In zh, this message translates to:
  /// **'小时'**
  String get featuresCronHour;

  /// No description provided for @featuresDate.
  ///
  /// In zh, this message translates to:
  /// **'日期'**
  String get featuresDate;

  /// No description provided for @featuresCronMonth.
  ///
  /// In zh, this message translates to:
  /// **'月份'**
  String get featuresCronMonth;

  /// No description provided for @featuresCronWeekday.
  ///
  /// In zh, this message translates to:
  /// **'星期'**
  String get featuresCronWeekday;

  /// No description provided for @featuresCronRequired.
  ///
  /// In zh, this message translates to:
  /// **'填写 5 段 Cron 表达式'**
  String get featuresCronRequired;

  /// No description provided for @featuresCronWhitespace.
  ///
  /// In zh, this message translates to:
  /// **'首尾不能有空格'**
  String get featuresCronWhitespace;

  /// No description provided for @featuresCronFieldCount.
  ///
  /// In zh, this message translates to:
  /// **'需要 5 段，现在是 {count} 段'**
  String featuresCronFieldCount(int count);

  /// No description provided for @featuresCronInvalidField.
  ///
  /// In zh, this message translates to:
  /// **'第 {index} 段（{name}）写法不对'**
  String featuresCronInvalidField(int index, String name);

  /// No description provided for @featuresWeekdayMon.
  ///
  /// In zh, this message translates to:
  /// **'一'**
  String get featuresWeekdayMon;

  /// No description provided for @featuresWeekdayTue.
  ///
  /// In zh, this message translates to:
  /// **'二'**
  String get featuresWeekdayTue;

  /// No description provided for @featuresWeekdayWed.
  ///
  /// In zh, this message translates to:
  /// **'三'**
  String get featuresWeekdayWed;

  /// No description provided for @featuresWeekdayThu.
  ///
  /// In zh, this message translates to:
  /// **'四'**
  String get featuresWeekdayThu;

  /// No description provided for @featuresWeekdayFri.
  ///
  /// In zh, this message translates to:
  /// **'五'**
  String get featuresWeekdayFri;

  /// No description provided for @featuresWeekdaySat.
  ///
  /// In zh, this message translates to:
  /// **'六'**
  String get featuresWeekdaySat;

  /// No description provided for @featuresWeekdaySun.
  ///
  /// In zh, this message translates to:
  /// **'日'**
  String get featuresWeekdaySun;

  /// No description provided for @featuresMonthJan.
  ///
  /// In zh, this message translates to:
  /// **'一月'**
  String get featuresMonthJan;

  /// No description provided for @featuresMonthFeb.
  ///
  /// In zh, this message translates to:
  /// **'二月'**
  String get featuresMonthFeb;

  /// No description provided for @featuresMonthMar.
  ///
  /// In zh, this message translates to:
  /// **'三月'**
  String get featuresMonthMar;

  /// No description provided for @featuresMonthApr.
  ///
  /// In zh, this message translates to:
  /// **'四月'**
  String get featuresMonthApr;

  /// No description provided for @featuresMonthMay.
  ///
  /// In zh, this message translates to:
  /// **'五月'**
  String get featuresMonthMay;

  /// No description provided for @featuresMonthJun.
  ///
  /// In zh, this message translates to:
  /// **'六月'**
  String get featuresMonthJun;

  /// No description provided for @featuresMonthJul.
  ///
  /// In zh, this message translates to:
  /// **'七月'**
  String get featuresMonthJul;

  /// No description provided for @featuresMonthAug.
  ///
  /// In zh, this message translates to:
  /// **'八月'**
  String get featuresMonthAug;

  /// No description provided for @featuresMonthSep.
  ///
  /// In zh, this message translates to:
  /// **'九月'**
  String get featuresMonthSep;

  /// No description provided for @featuresMonthOct.
  ///
  /// In zh, this message translates to:
  /// **'十月'**
  String get featuresMonthOct;

  /// No description provided for @featuresMonthNov.
  ///
  /// In zh, this message translates to:
  /// **'十一月'**
  String get featuresMonthNov;

  /// No description provided for @featuresMonthDec.
  ///
  /// In zh, this message translates to:
  /// **'十二月'**
  String get featuresMonthDec;

  /// No description provided for @featuresWeekdayName.
  ///
  /// In zh, this message translates to:
  /// **'周{day}'**
  String featuresWeekdayName(String day);

  /// No description provided for @featuresCronWeekdayRange.
  ///
  /// In zh, this message translates to:
  /// **'{first}至{last}'**
  String featuresCronWeekdayRange(String first, String last);

  /// No description provided for @featuresCronEveryDay.
  ///
  /// In zh, this message translates to:
  /// **'每天{months}'**
  String featuresCronEveryDay(String months);

  /// No description provided for @featuresCronMonthDays.
  ///
  /// In zh, this message translates to:
  /// **'每月 {days} 日{months}'**
  String featuresCronMonthDays(String days, String months);

  /// No description provided for @featuresCronMonthDaysAndWeekdays.
  ///
  /// In zh, this message translates to:
  /// **'每月 {days} 日且{weekdays}{months}'**
  String featuresCronMonthDaysAndWeekdays(String days, String weekdays, String months);

  /// No description provided for @featuresCronMonthDaysOrWeekdays.
  ///
  /// In zh, this message translates to:
  /// **'每月 {days} 日或{weekdays}{months}'**
  String featuresCronMonthDaysOrWeekdays(String days, String weekdays, String months);

  /// No description provided for @featuresCronHourRange.
  ///
  /// In zh, this message translates to:
  /// **'{first} 至 {last}'**
  String featuresCronHourRange(String first, String last);

  /// No description provided for @featuresEveryMinute.
  ///
  /// In zh, this message translates to:
  /// **'每分钟'**
  String get featuresEveryMinute;

  /// No description provided for @featuresCronEveryMinutes.
  ///
  /// In zh, this message translates to:
  /// **'每 {count} 分钟'**
  String featuresCronEveryMinutes(int count);

  /// No description provided for @featuresEveryHour.
  ///
  /// In zh, this message translates to:
  /// **'每小时'**
  String get featuresEveryHour;

  /// No description provided for @featuresCronHourlyMinutes.
  ///
  /// In zh, this message translates to:
  /// **'每小时的第 {minutes} 分钟'**
  String featuresCronHourlyMinutes(String minutes);

  /// No description provided for @featuresCronHoursEveryMinute.
  ///
  /// In zh, this message translates to:
  /// **'{hours} 点的每分钟'**
  String featuresCronHoursEveryMinute(String hours);

  /// No description provided for @featuresCronHoursEveryMinutes.
  ///
  /// In zh, this message translates to:
  /// **'{hours} 点内每 {count} 分钟'**
  String featuresCronHoursEveryMinutes(String hours, int count);

  /// No description provided for @featuresCronEveryHours.
  ///
  /// In zh, this message translates to:
  /// **'每 {count} 小时'**
  String featuresCronEveryHours(int count);

  /// No description provided for @featuresCronHoursMinutes.
  ///
  /// In zh, this message translates to:
  /// **'{hours} 点的第 {minutes} 分钟'**
  String featuresCronHoursMinutes(String hours, String minutes);

  /// No description provided for @featuresRepeatDaily.
  ///
  /// In zh, this message translates to:
  /// **'每天'**
  String get featuresRepeatDaily;

  /// No description provided for @featuresRepeatWeekdays.
  ///
  /// In zh, this message translates to:
  /// **'工作日'**
  String get featuresRepeatWeekdays;

  /// No description provided for @featuresRepeatWeekly.
  ///
  /// In zh, this message translates to:
  /// **'每周'**
  String get featuresRepeatWeekly;

  /// No description provided for @featuresRepeatMonthly.
  ///
  /// In zh, this message translates to:
  /// **'每月'**
  String get featuresRepeatMonthly;

  /// No description provided for @featuresRepeatInterval.
  ///
  /// In zh, this message translates to:
  /// **'间隔'**
  String get featuresRepeatInterval;

  /// No description provided for @featuresRepeatOnce.
  ///
  /// In zh, this message translates to:
  /// **'仅一次'**
  String get featuresRepeatOnce;

  /// No description provided for @featuresRepeatAdvanced.
  ///
  /// In zh, this message translates to:
  /// **'高级'**
  String get featuresRepeatAdvanced;

  /// No description provided for @featuresRepeatCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get featuresRepeatCustom;

  /// No description provided for @featuresIntervalSeconds.
  ///
  /// In zh, this message translates to:
  /// **'秒'**
  String get featuresIntervalSeconds;

  /// No description provided for @featuresZoneUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'时区不可用'**
  String get featuresZoneUnavailable;

  /// No description provided for @featuresChooseDay.
  ///
  /// In zh, this message translates to:
  /// **'至少选一天'**
  String get featuresChooseDay;

  /// No description provided for @featuresIntervalMinimum.
  ///
  /// In zh, this message translates to:
  /// **'间隔至少为 1'**
  String get featuresIntervalMinimum;

  /// No description provided for @featuresMinimumMinute.
  ///
  /// In zh, this message translates to:
  /// **'至少 1 分钟'**
  String get featuresMinimumMinute;

  /// No description provided for @featuresTimeDoesNotExist.
  ///
  /// In zh, this message translates to:
  /// **'这个时间在该时区不存在'**
  String get featuresTimeDoesNotExist;

  /// No description provided for @featuresChooseFutureTime.
  ///
  /// In zh, this message translates to:
  /// **'选一个以后的时间'**
  String get featuresChooseFutureTime;

  /// No description provided for @featuresCronNeverRuns.
  ///
  /// In zh, this message translates to:
  /// **'这个表达式不会运行'**
  String get featuresCronNeverRuns;

  /// No description provided for @featuresRuleDaily.
  ///
  /// In zh, this message translates to:
  /// **'每天 {time}'**
  String featuresRuleDaily(String time);

  /// No description provided for @featuresRuleWeekdays.
  ///
  /// In zh, this message translates to:
  /// **'每个工作日 {time}'**
  String featuresRuleWeekdays(String time);

  /// No description provided for @featuresRuleWeekends.
  ///
  /// In zh, this message translates to:
  /// **'每个周末 {time}'**
  String featuresRuleWeekends(String time);

  /// No description provided for @featuresRuleWeekly.
  ///
  /// In zh, this message translates to:
  /// **'每周{days} {time}'**
  String featuresRuleWeekly(String days, String time);

  /// No description provided for @featuresRuleMonthly.
  ///
  /// In zh, this message translates to:
  /// **'每月 {days} 日 {time}'**
  String featuresRuleMonthly(String days, String time);

  /// No description provided for @featuresRepeat.
  ///
  /// In zh, this message translates to:
  /// **'重复'**
  String get featuresRepeat;

  /// No description provided for @featuresChat.
  ///
  /// In zh, this message translates to:
  /// **'对话'**
  String get featuresChat;

  /// No description provided for @featuresWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'工作区'**
  String get featuresWorkspace;

  /// No description provided for @featuresInstructionRequired.
  ///
  /// In zh, this message translates to:
  /// **'填写指令'**
  String get featuresInstructionRequired;

  /// No description provided for @featuresScheduleSaveError.
  ///
  /// In zh, this message translates to:
  /// **'没能保存：{reason}'**
  String featuresScheduleSaveError(String reason);

  /// No description provided for @featuresScheduleCreateError.
  ///
  /// In zh, this message translates to:
  /// **'没能创建：{reason}'**
  String featuresScheduleCreateError(String reason);

  /// No description provided for @featuresScheduleNameHint.
  ///
  /// In zh, this message translates to:
  /// **'比如：每日站会提醒'**
  String get featuresScheduleNameHint;

  /// No description provided for @featuresScheduleInstruction.
  ///
  /// In zh, this message translates to:
  /// **'指令'**
  String get featuresScheduleInstruction;

  /// No description provided for @featuresScheduleInstructionHint.
  ///
  /// In zh, this message translates to:
  /// **'比如：整理昨天的提交，发我摘要'**
  String get featuresScheduleInstructionHint;

  /// No description provided for @featuresScheduleRunTime.
  ///
  /// In zh, this message translates to:
  /// **'运行时间'**
  String get featuresScheduleRunTime;

  /// No description provided for @featuresScheduleOpenChat.
  ///
  /// In zh, this message translates to:
  /// **'去对话里看看'**
  String get featuresScheduleOpenChat;

  /// No description provided for @featuresScheduleEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑自动化任务'**
  String get featuresScheduleEditTitle;

  /// No description provided for @featuresScheduleCreateTitle.
  ///
  /// In zh, this message translates to:
  /// **'新建自动化任务'**
  String get featuresScheduleCreateTitle;

  /// No description provided for @featuresScheduleSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存'**
  String get featuresScheduleSaving;

  /// No description provided for @featuresScheduleCreating.
  ///
  /// In zh, this message translates to:
  /// **'正在对话里创建'**
  String get featuresScheduleCreating;

  /// No description provided for @featuresTime.
  ///
  /// In zh, this message translates to:
  /// **'时间'**
  String get featuresTime;

  /// No description provided for @featuresNotSelected.
  ///
  /// In zh, this message translates to:
  /// **'未选'**
  String get featuresNotSelected;

  /// No description provided for @featuresMonthDaysLabel.
  ///
  /// In zh, this message translates to:
  /// **'{days} 日'**
  String featuresMonthDaysLabel(String days);

  /// No description provided for @featuresTimeZone.
  ///
  /// In zh, this message translates to:
  /// **'时区'**
  String get featuresTimeZone;

  /// No description provided for @featuresScheduleRunLocation.
  ///
  /// In zh, this message translates to:
  /// **'在哪里运行'**
  String get featuresScheduleRunLocation;

  /// No description provided for @featuresJustCreatedChat.
  ///
  /// In zh, this message translates to:
  /// **'刚建的对话'**
  String get featuresJustCreatedChat;

  /// No description provided for @featuresModel.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get featuresModel;

  /// No description provided for @featuresRequestRefused.
  ///
  /// In zh, this message translates to:
  /// **'引擎没有接受这个请求'**
  String get featuresRequestRefused;

  /// No description provided for @featuresScheduleNotFound.
  ///
  /// In zh, this message translates to:
  /// **'这个任务已经不在了'**
  String get featuresScheduleNotFound;

  /// No description provided for @featuresScheduleEndedError.
  ///
  /// In zh, this message translates to:
  /// **'任务已结束，不能再改'**
  String get featuresScheduleEndedError;

  /// No description provided for @featuresScheduleConflict.
  ///
  /// In zh, this message translates to:
  /// **'任务刚被改过，返回后再试'**
  String get featuresScheduleConflict;

  /// No description provided for @featuresScheduleInvalidPrompt.
  ///
  /// In zh, this message translates to:
  /// **'名称和指令不能为空，名称最多 120 字'**
  String get featuresScheduleInvalidPrompt;

  /// No description provided for @featuresScheduleInvalidTime.
  ///
  /// In zh, this message translates to:
  /// **'运行时间不对'**
  String get featuresScheduleInvalidTime;

  /// No description provided for @featuresScheduleIntervalTooShort.
  ///
  /// In zh, this message translates to:
  /// **'间隔至少 1 分钟'**
  String get featuresScheduleIntervalTooShort;

  /// No description provided for @featuresScheduleTimeOutOfRange.
  ///
  /// In zh, this message translates to:
  /// **'时间超出范围'**
  String get featuresScheduleTimeOutOfRange;

  /// No description provided for @featuresScheduleSubagentError.
  ///
  /// In zh, this message translates to:
  /// **'这个对话收不到自动化任务'**
  String get featuresScheduleSubagentError;

  /// No description provided for @featuresEvery.
  ///
  /// In zh, this message translates to:
  /// **'每'**
  String get featuresEvery;

  /// No description provided for @featuresCronExpression.
  ///
  /// In zh, this message translates to:
  /// **'Cron 表达式'**
  String get featuresCronExpression;

  /// No description provided for @featuresCronFieldGuide.
  ///
  /// In zh, this message translates to:
  /// **'分  时  日  月  周'**
  String get featuresCronFieldGuide;

  /// No description provided for @featuresZoneTimeSuffix.
  ///
  /// In zh, this message translates to:
  /// **'（{city}时间）'**
  String featuresZoneTimeSuffix(String city);

  /// No description provided for @featuresScheduleNextLocal.
  ///
  /// In zh, this message translates to:
  /// **'接下来（本机时间）'**
  String get featuresScheduleNextLocal;

  /// No description provided for @featuresScheduleNext.
  ///
  /// In zh, this message translates to:
  /// **'接下来'**
  String get featuresScheduleNext;

  /// No description provided for @featuresMonthDayChoice.
  ///
  /// In zh, this message translates to:
  /// **'{day} 日'**
  String featuresMonthDayChoice(int day);

  /// No description provided for @featuresZonesCommon.
  ///
  /// In zh, this message translates to:
  /// **'常用'**
  String get featuresZonesCommon;

  /// No description provided for @featuresZonesAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get featuresZonesAll;

  /// No description provided for @featuresZoneSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索城市、时区或 UTC 偏移'**
  String get featuresZoneSearchHint;

  /// No description provided for @featuresZonesNoMatch.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配的时区'**
  String get featuresZonesNoMatch;

  /// No description provided for @featuresZoneUTC.
  ///
  /// In zh, this message translates to:
  /// **'协调世界时'**
  String get featuresZoneUTC;

  /// No description provided for @featuresZoneShanghai.
  ///
  /// In zh, this message translates to:
  /// **'上海'**
  String get featuresZoneShanghai;

  /// No description provided for @featuresZoneUrumqi.
  ///
  /// In zh, this message translates to:
  /// **'乌鲁木齐'**
  String get featuresZoneUrumqi;

  /// No description provided for @featuresZoneHongKong.
  ///
  /// In zh, this message translates to:
  /// **'香港'**
  String get featuresZoneHongKong;

  /// No description provided for @featuresZoneMacau.
  ///
  /// In zh, this message translates to:
  /// **'澳门'**
  String get featuresZoneMacau;

  /// No description provided for @featuresZoneTaipei.
  ///
  /// In zh, this message translates to:
  /// **'台北'**
  String get featuresZoneTaipei;

  /// No description provided for @featuresZoneTokyo.
  ///
  /// In zh, this message translates to:
  /// **'东京'**
  String get featuresZoneTokyo;

  /// No description provided for @featuresZoneSeoul.
  ///
  /// In zh, this message translates to:
  /// **'首尔'**
  String get featuresZoneSeoul;

  /// No description provided for @featuresZoneSingapore.
  ///
  /// In zh, this message translates to:
  /// **'新加坡'**
  String get featuresZoneSingapore;

  /// No description provided for @featuresZoneKualaLumpur.
  ///
  /// In zh, this message translates to:
  /// **'吉隆坡'**
  String get featuresZoneKualaLumpur;

  /// No description provided for @featuresZoneBangkok.
  ///
  /// In zh, this message translates to:
  /// **'曼谷'**
  String get featuresZoneBangkok;

  /// No description provided for @featuresZoneHoChiMinh.
  ///
  /// In zh, this message translates to:
  /// **'胡志明市'**
  String get featuresZoneHoChiMinh;

  /// No description provided for @featuresZoneJakarta.
  ///
  /// In zh, this message translates to:
  /// **'雅加达'**
  String get featuresZoneJakarta;

  /// No description provided for @featuresZoneManila.
  ///
  /// In zh, this message translates to:
  /// **'马尼拉'**
  String get featuresZoneManila;

  /// No description provided for @featuresZoneKolkata.
  ///
  /// In zh, this message translates to:
  /// **'加尔各答'**
  String get featuresZoneKolkata;

  /// No description provided for @featuresZoneDubai.
  ///
  /// In zh, this message translates to:
  /// **'迪拜'**
  String get featuresZoneDubai;

  /// No description provided for @featuresZoneJerusalem.
  ///
  /// In zh, this message translates to:
  /// **'耶路撒冷'**
  String get featuresZoneJerusalem;

  /// No description provided for @featuresZoneLondon.
  ///
  /// In zh, this message translates to:
  /// **'伦敦'**
  String get featuresZoneLondon;

  /// No description provided for @featuresZoneDublin.
  ///
  /// In zh, this message translates to:
  /// **'都柏林'**
  String get featuresZoneDublin;

  /// No description provided for @featuresZoneLisbon.
  ///
  /// In zh, this message translates to:
  /// **'里斯本'**
  String get featuresZoneLisbon;

  /// No description provided for @featuresZoneParis.
  ///
  /// In zh, this message translates to:
  /// **'巴黎'**
  String get featuresZoneParis;

  /// No description provided for @featuresZoneBerlin.
  ///
  /// In zh, this message translates to:
  /// **'柏林'**
  String get featuresZoneBerlin;

  /// No description provided for @featuresZoneMadrid.
  ///
  /// In zh, this message translates to:
  /// **'马德里'**
  String get featuresZoneMadrid;

  /// No description provided for @featuresZoneRome.
  ///
  /// In zh, this message translates to:
  /// **'罗马'**
  String get featuresZoneRome;

  /// No description provided for @featuresZoneAmsterdam.
  ///
  /// In zh, this message translates to:
  /// **'阿姆斯特丹'**
  String get featuresZoneAmsterdam;

  /// No description provided for @featuresZoneZurich.
  ///
  /// In zh, this message translates to:
  /// **'苏黎世'**
  String get featuresZoneZurich;

  /// No description provided for @featuresZoneStockholm.
  ///
  /// In zh, this message translates to:
  /// **'斯德哥尔摩'**
  String get featuresZoneStockholm;

  /// No description provided for @featuresZoneWarsaw.
  ///
  /// In zh, this message translates to:
  /// **'华沙'**
  String get featuresZoneWarsaw;

  /// No description provided for @featuresZoneAthens.
  ///
  /// In zh, this message translates to:
  /// **'雅典'**
  String get featuresZoneAthens;

  /// No description provided for @featuresZoneIstanbul.
  ///
  /// In zh, this message translates to:
  /// **'伊斯坦布尔'**
  String get featuresZoneIstanbul;

  /// No description provided for @featuresZoneMoscow.
  ///
  /// In zh, this message translates to:
  /// **'莫斯科'**
  String get featuresZoneMoscow;

  /// No description provided for @featuresZoneCairo.
  ///
  /// In zh, this message translates to:
  /// **'开罗'**
  String get featuresZoneCairo;

  /// No description provided for @featuresZoneJohannesburg.
  ///
  /// In zh, this message translates to:
  /// **'约翰内斯堡'**
  String get featuresZoneJohannesburg;

  /// No description provided for @featuresZoneLagos.
  ///
  /// In zh, this message translates to:
  /// **'拉各斯'**
  String get featuresZoneLagos;

  /// No description provided for @featuresZoneNewYork.
  ///
  /// In zh, this message translates to:
  /// **'纽约'**
  String get featuresZoneNewYork;

  /// No description provided for @featuresZoneToronto.
  ///
  /// In zh, this message translates to:
  /// **'多伦多'**
  String get featuresZoneToronto;

  /// No description provided for @featuresZoneChicago.
  ///
  /// In zh, this message translates to:
  /// **'芝加哥'**
  String get featuresZoneChicago;

  /// No description provided for @featuresZoneDenver.
  ///
  /// In zh, this message translates to:
  /// **'丹佛'**
  String get featuresZoneDenver;

  /// No description provided for @featuresZonePhoenix.
  ///
  /// In zh, this message translates to:
  /// **'凤凰城'**
  String get featuresZonePhoenix;

  /// No description provided for @featuresZoneLosAngeles.
  ///
  /// In zh, this message translates to:
  /// **'洛杉矶'**
  String get featuresZoneLosAngeles;

  /// No description provided for @featuresZoneVancouver.
  ///
  /// In zh, this message translates to:
  /// **'温哥华'**
  String get featuresZoneVancouver;

  /// No description provided for @featuresZoneAnchorage.
  ///
  /// In zh, this message translates to:
  /// **'安克雷奇'**
  String get featuresZoneAnchorage;

  /// No description provided for @featuresZoneMexicoCity.
  ///
  /// In zh, this message translates to:
  /// **'墨西哥城'**
  String get featuresZoneMexicoCity;

  /// No description provided for @featuresZoneBogota.
  ///
  /// In zh, this message translates to:
  /// **'波哥大'**
  String get featuresZoneBogota;

  /// No description provided for @featuresZoneLima.
  ///
  /// In zh, this message translates to:
  /// **'利马'**
  String get featuresZoneLima;

  /// No description provided for @featuresZoneSantiago.
  ///
  /// In zh, this message translates to:
  /// **'圣地亚哥'**
  String get featuresZoneSantiago;

  /// No description provided for @featuresZoneSaoPaulo.
  ///
  /// In zh, this message translates to:
  /// **'圣保罗'**
  String get featuresZoneSaoPaulo;

  /// No description provided for @featuresZoneBuenosAires.
  ///
  /// In zh, this message translates to:
  /// **'布宜诺斯艾利斯'**
  String get featuresZoneBuenosAires;

  /// No description provided for @featuresZoneHonolulu.
  ///
  /// In zh, this message translates to:
  /// **'檀香山'**
  String get featuresZoneHonolulu;

  /// No description provided for @featuresZoneAuckland.
  ///
  /// In zh, this message translates to:
  /// **'奥克兰'**
  String get featuresZoneAuckland;

  /// No description provided for @featuresZoneSydney.
  ///
  /// In zh, this message translates to:
  /// **'悉尼'**
  String get featuresZoneSydney;

  /// No description provided for @featuresZoneMelbourne.
  ///
  /// In zh, this message translates to:
  /// **'墨尔本'**
  String get featuresZoneMelbourne;

  /// No description provided for @featuresZoneBrisbane.
  ///
  /// In zh, this message translates to:
  /// **'布里斯班'**
  String get featuresZoneBrisbane;

  /// No description provided for @featuresZonePerth.
  ///
  /// In zh, this message translates to:
  /// **'珀斯'**
  String get featuresZonePerth;

  /// No description provided for @featuresScheduleCreated.
  ///
  /// In zh, this message translates to:
  /// **'已创建'**
  String get featuresScheduleCreated;

  /// No description provided for @featuresSchedulesReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取自动化任务'**
  String get featuresSchedulesReadFailed;

  /// No description provided for @featuresSchedulesEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有自动化任务'**
  String get featuresSchedulesEmpty;

  /// No description provided for @featuresSchedulesEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'到点自动发进对话，替你跑一遍'**
  String get featuresSchedulesEmptyHint;

  /// No description provided for @featuresScheduleNewTask.
  ///
  /// In zh, this message translates to:
  /// **'新建任务'**
  String get featuresScheduleNewTask;

  /// No description provided for @featuresSchedulesNoMatch.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配的任务'**
  String get featuresSchedulesNoMatch;

  /// No description provided for @featuresSchedulesNoActive.
  ///
  /// In zh, this message translates to:
  /// **'没有开启中的任务'**
  String get featuresSchedulesNoActive;

  /// No description provided for @featuresSchedulesNoEnded.
  ///
  /// In zh, this message translates to:
  /// **'没有已结束的任务'**
  String get featuresSchedulesNoEnded;

  /// No description provided for @featuresSchedules.
  ///
  /// In zh, this message translates to:
  /// **'自动化任务'**
  String get featuresSchedules;

  /// No description provided for @featuresSchedulesSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'到点自动发进原来的对话'**
  String get featuresSchedulesSubtitle;

  /// No description provided for @featuresSchedulesSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索任务'**
  String get featuresSchedulesSearch;

  /// No description provided for @featuresSchedulesAllCount.
  ///
  /// In zh, this message translates to:
  /// **'全部 {count}'**
  String featuresSchedulesAllCount(int count);

  /// No description provided for @featuresScheduleUntitled.
  ///
  /// In zh, this message translates to:
  /// **'未命名任务'**
  String get featuresScheduleUntitled;

  /// No description provided for @featuresScheduleSent.
  ///
  /// In zh, this message translates to:
  /// **'已发进对话'**
  String get featuresScheduleSent;

  /// No description provided for @featuresView.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get featuresView;

  /// No description provided for @featuresSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能发送'**
  String get featuresSendFailed;

  /// No description provided for @featuresScheduleDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除这个任务？'**
  String get featuresScheduleDeleteTitle;

  /// No description provided for @featuresScheduleDeleteHint.
  ///
  /// In zh, this message translates to:
  /// **'会停止之后的运行，并删掉它的运行记录。原来的对话不受影响。'**
  String get featuresScheduleDeleteHint;

  /// No description provided for @featuresScheduleDeleted.
  ///
  /// In zh, this message translates to:
  /// **'任务已删除'**
  String get featuresScheduleDeleted;

  /// No description provided for @featuresScheduleActive.
  ///
  /// In zh, this message translates to:
  /// **'已开启'**
  String get featuresScheduleActive;

  /// No description provided for @featuresScheduleRun.
  ///
  /// In zh, this message translates to:
  /// **'运行'**
  String get featuresScheduleRun;

  /// No description provided for @featuresScheduleNextRun.
  ///
  /// In zh, this message translates to:
  /// **'下次'**
  String get featuresScheduleNextRun;

  /// No description provided for @featuresScheduleLastRun.
  ///
  /// In zh, this message translates to:
  /// **'上次'**
  String get featuresScheduleLastRun;

  /// No description provided for @featuresScheduleRule.
  ///
  /// In zh, this message translates to:
  /// **'规则'**
  String get featuresScheduleRule;

  /// No description provided for @featuresScheduleLinkedChat.
  ///
  /// In zh, this message translates to:
  /// **'关联对话'**
  String get featuresScheduleLinkedChat;

  /// No description provided for @featuresScheduleChatDeleted.
  ///
  /// In zh, this message translates to:
  /// **'对话已删除'**
  String get featuresScheduleChatDeleted;

  /// No description provided for @featuresScheduleEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑任务'**
  String get featuresScheduleEdit;

  /// No description provided for @featuresScheduleRunNow.
  ///
  /// In zh, this message translates to:
  /// **'立即运行'**
  String get featuresScheduleRunNow;

  /// No description provided for @featuresScheduleHistory.
  ///
  /// In zh, this message translates to:
  /// **'运行记录'**
  String get featuresScheduleHistory;

  /// No description provided for @featuresScheduleNeverRun.
  ///
  /// In zh, this message translates to:
  /// **'还没有运行过'**
  String get featuresScheduleNeverRun;

  /// No description provided for @featuresScheduleHistoryUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'记录不可用'**
  String get featuresScheduleHistoryUnavailable;

  /// No description provided for @featuresScheduleHistoryReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取运行记录'**
  String get featuresScheduleHistoryReadFailed;

  /// No description provided for @featuresScheduleDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除任务'**
  String get featuresScheduleDelete;

  /// No description provided for @featuresExportSavedTo.
  ///
  /// In zh, this message translates to:
  /// **'已存到 {path}'**
  String featuresExportSavedTo(String path);

  /// No description provided for @featuresExportTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出对话日志'**
  String get featuresExportTitle;

  /// No description provided for @featuresExportSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'打包成一个 ZIP，用于反馈或备份'**
  String get featuresExportSubtitle;

  /// No description provided for @featuresExportUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'这个连接导不了'**
  String get featuresExportUnavailable;

  /// No description provided for @featuresExportRemoteHint.
  ///
  /// In zh, this message translates to:
  /// **'经 DSH Remote 中转时拿不到日志，可以在电脑上的网页版导出'**
  String get featuresExportRemoteHint;

  /// No description provided for @featuresExportShareHint.
  ///
  /// In zh, this message translates to:
  /// **'附在问题反馈里，或发给自己'**
  String get featuresExportShareHint;

  /// No description provided for @featuresExportSaveDownloads.
  ///
  /// In zh, this message translates to:
  /// **'存到「下载」'**
  String get featuresExportSaveDownloads;

  /// No description provided for @featuresExportDownloadsHint.
  ///
  /// In zh, this message translates to:
  /// **'存进 下载/DSH-Go'**
  String get featuresExportDownloadsHint;

  /// No description provided for @featuresExportContents.
  ///
  /// In zh, this message translates to:
  /// **'含这个对话和子代理的全部记录与附件'**
  String get featuresExportContents;

  /// No description provided for @featuresArtifactsSemantic.
  ///
  /// In zh, this message translates to:
  /// **'产出的文件，共 {count} 个，查看全部'**
  String featuresArtifactsSemantic(int count);

  /// No description provided for @featuresArtifactsTitle.
  ///
  /// In zh, this message translates to:
  /// **'产出的文件'**
  String get featuresArtifactsTitle;

  /// No description provided for @featuresArtifactsAllCount.
  ///
  /// In zh, this message translates to:
  /// **'全部 {count} 个'**
  String featuresArtifactsAllCount(int count);

  /// No description provided for @featuresArtifactsCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个'**
  String featuresArtifactsCount(int count);

  /// No description provided for @featuresArtifactsNoFiles.
  ///
  /// In zh, this message translates to:
  /// **'还没有文件'**
  String get featuresArtifactsNoFiles;

  /// No description provided for @featuresArtifactsTotal.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个文件 · 交付的和生成的'**
  String featuresArtifactsTotal(int count);

  /// No description provided for @featuresArtifactsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有产出文件'**
  String get featuresArtifactsEmpty;

  /// No description provided for @featuresArtifactsEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'AI 交付或生成的文件会出现在这里'**
  String get featuresArtifactsEmptyHint;

  /// No description provided for @featuresListSeparator.
  ///
  /// In zh, this message translates to:
  /// **'、'**
  String get featuresListSeparator;

  /// No description provided for @featuresErrorReason.
  ///
  /// In zh, this message translates to:
  /// **'{title}：{reason}'**
  String featuresErrorReason(String title, String reason);

  /// No description provided for @featuresYearDate.
  ///
  /// In zh, this message translates to:
  /// **'{year}年{date}'**
  String featuresYearDate(int year, String date);

  /// No description provided for @featuresDateWeekdayTime.
  ///
  /// In zh, this message translates to:
  /// **'{date} {week} {time}'**
  String featuresDateWeekdayTime(String date, String week, String time);

  /// No description provided for @featuresDateWeekday.
  ///
  /// In zh, this message translates to:
  /// **'{date} 周{day}'**
  String featuresDateWeekday(String date, String day);

  /// No description provided for @featuresOnceDescription.
  ///
  /// In zh, this message translates to:
  /// **'{rule} · {date} {time}'**
  String featuresOnceDescription(String rule, String date, String time);

  /// No description provided for @featuresCronMonthSuffix.
  ///
  /// In zh, this message translates to:
  /// **'（{months}）'**
  String featuresCronMonthSuffix(String months);

  /// No description provided for @featuresRuleIntervalSeconds.
  ///
  /// In zh, this message translates to:
  /// **'每 {count} 秒'**
  String featuresRuleIntervalSeconds(int count);

  /// No description provided for @featuresRuleIntervalMinutes.
  ///
  /// In zh, this message translates to:
  /// **'每 {count} 分钟'**
  String featuresRuleIntervalMinutes(int count);

  /// No description provided for @featuresRuleIntervalHours.
  ///
  /// In zh, this message translates to:
  /// **'每 {count} 小时'**
  String featuresRuleIntervalHours(int count);

  /// No description provided for @featuresSchedulesActiveCount.
  ///
  /// In zh, this message translates to:
  /// **'已开启 {count}'**
  String featuresSchedulesActiveCount(int count);

  /// No description provided for @featuresSchedulesEndedCount.
  ///
  /// In zh, this message translates to:
  /// **'已结束 {count}'**
  String featuresSchedulesEndedCount(int count);

  /// No description provided for @featuresScheduleRetention.
  ///
  /// In zh, this message translates to:
  /// **'只保留最近 {days} 天、最多 {count} 条'**
  String featuresScheduleRetention(int days, int count);

  /// No description provided for @featuresScheduleRetentionUnknown.
  ///
  /// In zh, this message translates to:
  /// **'只保留最近 {days} 天、最多 — 条'**
  String featuresScheduleRetentionUnknown(int days);

  /// No description provided for @featuresArtifactsDeliveredTurn.
  ///
  /// In zh, this message translates to:
  /// **'第 {turn} 轮 · 交付'**
  String featuresArtifactsDeliveredTurn(int turn);

  /// No description provided for @featuresArtifactsGeneratedTurn.
  ///
  /// In zh, this message translates to:
  /// **'第 {turn} 轮 · 生成'**
  String featuresArtifactsGeneratedTurn(int turn);

  /// No description provided for @featuresPresetCreateRequest.
  ///
  /// In zh, this message translates to:
  /// **'新建 Agent 预设「{name}」（{id}）：在工作区写下这两个文件（内容原样），再用 plugin_manager 的 install_bundle 安装 `{directory}` 目录。只做这些。\n\n'**
  String featuresPresetCreateRequest(String name, String id, String directory);

  /// No description provided for @featuresPresetUpdateRequest.
  ///
  /// In zh, this message translates to:
  /// **'更新 Agent 预设「{name}」（{id}）：在工作区写下这两个文件（内容原样），用 plugin_manager 先移除组合包 `{replacing}`，再用 install_bundle 安装 `{directory}` 目录。只做这些。\n\n'**
  String featuresPresetUpdateRequest(String name, String id, String replacing, String directory);

  /// No description provided for @featuresZoneThisPhone.
  ///
  /// In zh, this message translates to:
  /// **'{city} · 本机'**
  String featuresZoneThisPhone(String city);

  /// No description provided for @featuresPermissionResetHint.
  ///
  /// In zh, this message translates to:
  /// **'新对话的默认权限已失效'**
  String get featuresPermissionResetHint;

  /// No description provided for @featuresPermissionResetDefault.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认'**
  String get featuresPermissionResetDefault;

  /// No description provided for @fileImageName.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get fileImageName;

  /// No description provided for @fileSharedText.
  ///
  /// In zh, this message translates to:
  /// **'分享的文字.txt'**
  String get fileSharedText;

  /// No description provided for @fileChatFallback.
  ///
  /// In zh, this message translates to:
  /// **'对话'**
  String get fileChatFallback;

  /// No description provided for @fileUploadToHost.
  ///
  /// In zh, this message translates to:
  /// **'传文件到电脑'**
  String get fileUploadToHost;

  /// No description provided for @fileUploadToHostHint.
  ///
  /// In zh, this message translates to:
  /// **'放进这个对话在电脑上的工作区，原文件不压缩'**
  String get fileUploadToHostHint;

  /// No description provided for @fileUploadProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在传 {done}/{total}：{name}'**
  String fileUploadProgress(int done, int total, String name);

  /// No description provided for @fileUploadDone.
  ///
  /// In zh, this message translates to:
  /// **'已传到电脑：{names}'**
  String fileUploadDone(String names);

  /// No description provided for @fileUploadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能传到电脑'**
  String get fileUploadFailed;

  /// No description provided for @harmonyUnknownResults.
  ///
  /// In zh, this message translates to:
  /// **'有工具调用没等到结果，可能已经执行，也可能没有。处理之前，这个对话不能再调用工具。'**
  String get harmonyUnknownResults;

  /// No description provided for @harmonyUnknownResultsReview.
  ///
  /// In zh, this message translates to:
  /// **'处理'**
  String get harmonyUnknownResultsReview;

  /// No description provided for @harmonyUnknownResultsTitle.
  ///
  /// In zh, this message translates to:
  /// **'这些工具调用的结果未知'**
  String get harmonyUnknownResultsTitle;

  /// No description provided for @harmonyUnknownResultsBody.
  ///
  /// In zh, this message translates to:
  /// **'{tools}\n\n应用在等结果时中断了，它们可能已经执行，也可能没有。可以先看看实际情况，比如文件改了没有。\n\n继续之后，这些调用不会重新运行，记录也不会改成成功。'**
  String harmonyUnknownResultsBody(String tools);

  /// No description provided for @harmonyUnknownResultsContinue.
  ///
  /// In zh, this message translates to:
  /// **'继续这个对话'**
  String get harmonyUnknownResultsContinue;

  /// No description provided for @harmonyUnknownResultsChanged.
  ///
  /// In zh, this message translates to:
  /// **'情况变了，请再看一遍。'**
  String get harmonyUnknownResultsChanged;

  /// No description provided for @harmonyUnknownResultsFailed.
  ///
  /// In zh, this message translates to:
  /// **'没有确认成功，请再试一次。'**
  String get harmonyUnknownResultsFailed;

  /// No description provided for @harmonyCallsNotRecorded.
  ///
  /// In zh, this message translates to:
  /// **'本机引擎记不下工具调用的状态，工具调用已暂停。重启引擎后再试。'**
  String get harmonyCallsNotRecorded;

  /// No description provided for @harmonySchedulesLocal.
  ///
  /// In zh, this message translates to:
  /// **'本机的任务只在应用运行时触发：应用被系统挂起时，到点不会运行'**
  String get harmonySchedulesLocal;

  /// No description provided for @harmonyTerminalNoPty.
  ///
  /// In zh, this message translates to:
  /// **'这个引擎没有交互终端，可连 SSH 主机'**
  String get harmonyTerminalNoPty;

  /// No description provided for @harmonyTerminalSupportedHosts.
  ///
  /// In zh, this message translates to:
  /// **'在 SSH 主机上可用'**
  String get harmonyTerminalSupportedHosts;

  /// No description provided for @harmonyKwAccent.
  ///
  /// In zh, this message translates to:
  /// **'颜色,主题色,强调色'**
  String get harmonyKwAccent;

  /// No description provided for @harmonySaveToFile.
  ///
  /// In zh, this message translates to:
  /// **'保存到文件'**
  String get harmonySaveToFile;

  /// No description provided for @harmonySaveChooseLocation.
  ///
  /// In zh, this message translates to:
  /// **'选择保存位置'**
  String get harmonySaveChooseLocation;

  /// No description provided for @harmonySaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存…'**
  String get harmonySaving;

  /// No description provided for @harmonySaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get harmonySaved;

  /// No description provided for @harmonyCommandExportDescription.
  ///
  /// In zh, this message translates to:
  /// **'把这个对话的完整记录打包成 ZIP，分享或保存到文件'**
  String get harmonyCommandExportDescription;

  /// No description provided for @harmonyReminderSet.
  ///
  /// In zh, this message translates to:
  /// **'已设提醒'**
  String get harmonyReminderSet;

  /// No description provided for @harmonyReminderRefused.
  ///
  /// In zh, this message translates to:
  /// **'系统没有接受提醒，没有设置。'**
  String get harmonyReminderRefused;

  /// No description provided for @hostDetailsConnectionType.
  ///
  /// In zh, this message translates to:
  /// **'连接方式'**
  String get hostDetailsConnectionType;

  /// No description provided for @hubSessionDetails.
  ///
  /// In zh, this message translates to:
  /// **'对话详情'**
  String get hubSessionDetails;

  /// No description provided for @hubTerminal.
  ///
  /// In zh, this message translates to:
  /// **'终端'**
  String get hubTerminal;

  /// No description provided for @hubSessionNoTurns.
  ///
  /// In zh, this message translates to:
  /// **'还没有完整的一轮'**
  String get hubSessionNoTurns;

  /// No description provided for @hubSessionElapsed.
  ///
  /// In zh, this message translates to:
  /// **'用时'**
  String get hubSessionElapsed;

  /// No description provided for @hubSessionSteps.
  ///
  /// In zh, this message translates to:
  /// **'步骤'**
  String get hubSessionSteps;

  /// No description provided for @hubSessionChangedFiles.
  ///
  /// In zh, this message translates to:
  /// **'改动文件'**
  String get hubSessionChangedFiles;

  /// No description provided for @hubSessionTrajectoryHint.
  ///
  /// In zh, this message translates to:
  /// **'每一轮的步骤和用时会排在这里'**
  String get hubSessionTrajectoryHint;

  /// No description provided for @hubSessionLoadEarlier.
  ///
  /// In zh, this message translates to:
  /// **'加载更早的轮次'**
  String get hubSessionLoadEarlier;

  /// No description provided for @hubSessionError.
  ///
  /// In zh, this message translates to:
  /// **'出错'**
  String get hubSessionError;

  /// No description provided for @hubSessionInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'被中断'**
  String get hubSessionInterrupted;

  /// No description provided for @hubSessionOutputLimit.
  ///
  /// In zh, this message translates to:
  /// **'达到输出上限'**
  String get hubSessionOutputLimit;

  /// No description provided for @hubSessionNoChanges.
  ///
  /// In zh, this message translates to:
  /// **'还没有改过文件'**
  String get hubSessionNoChanges;

  /// No description provided for @hubSessionShellChangesHint.
  ///
  /// In zh, this message translates to:
  /// **'用 shell 命令改的文件不在这里'**
  String get hubSessionShellChangesHint;

  /// No description provided for @hubSessionChanges.
  ///
  /// In zh, this message translates to:
  /// **'对话改动'**
  String get hubSessionChanges;

  /// No description provided for @hubSessionChangesNote.
  ///
  /// In zh, this message translates to:
  /// **'只统计已加载的记录里，用写入和编辑工具做的改动'**
  String get hubSessionChangesNote;

  /// No description provided for @hubSessionNoGoal.
  ///
  /// In zh, this message translates to:
  /// **'还没有目标或待办'**
  String get hubSessionNoGoal;

  /// No description provided for @hubSessionGoalHint.
  ///
  /// In zh, this message translates to:
  /// **'复杂任务里 AI 会列出待办，进度在这里看'**
  String get hubSessionGoalHint;

  /// No description provided for @hubSessionGoal.
  ///
  /// In zh, this message translates to:
  /// **'目标'**
  String get hubSessionGoal;

  /// No description provided for @hubSessionPlanMode.
  ///
  /// In zh, this message translates to:
  /// **'计划模式'**
  String get hubSessionPlanMode;

  /// No description provided for @hubSessionPlanSwitching.
  ///
  /// In zh, this message translates to:
  /// **'正在切换计划模式'**
  String get hubSessionPlanSwitching;

  /// No description provided for @hubSessionPlanHint.
  ///
  /// In zh, this message translates to:
  /// **'AI 先出方案，不改文件'**
  String get hubSessionPlanHint;

  /// No description provided for @hubSessionTodos.
  ///
  /// In zh, this message translates to:
  /// **'待办'**
  String get hubSessionTodos;

  /// No description provided for @hubSessionNotStarted.
  ///
  /// In zh, this message translates to:
  /// **'未开始'**
  String get hubSessionNotStarted;

  /// No description provided for @hubSessionTurnUsage.
  ///
  /// In zh, this message translates to:
  /// **'每轮用量'**
  String get hubSessionTurnUsage;

  /// No description provided for @hubSessionNoSubagents.
  ///
  /// In zh, this message translates to:
  /// **'没有派出子代理'**
  String get hubSessionNoSubagents;

  /// No description provided for @hubSessionDelegations.
  ///
  /// In zh, this message translates to:
  /// **'派活记录'**
  String get hubSessionDelegations;

  /// No description provided for @hubTabTrajectory.
  ///
  /// In zh, this message translates to:
  /// **'轨迹'**
  String get hubTabTrajectory;

  /// No description provided for @hubTabChanges.
  ///
  /// In zh, this message translates to:
  /// **'改动'**
  String get hubTabChanges;

  /// No description provided for @hubTabFiles.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get hubTabFiles;

  /// No description provided for @hubTabProgress.
  ///
  /// In zh, this message translates to:
  /// **'进度'**
  String get hubTabProgress;

  /// No description provided for @hubTabContext.
  ///
  /// In zh, this message translates to:
  /// **'上下文'**
  String get hubTabContext;

  /// No description provided for @hubTabSubagents.
  ///
  /// In zh, this message translates to:
  /// **'子代理'**
  String get hubTabSubagents;

  /// No description provided for @hubSettingsFullAccessTitle.
  ///
  /// In zh, this message translates to:
  /// **'开启完全权限？'**
  String get hubSettingsFullAccessTitle;

  /// No description provided for @hubSettingsFullAccessBody.
  ///
  /// In zh, this message translates to:
  /// **'AI 执行命令、改动文件前不再问你。'**
  String get hubSettingsFullAccessBody;

  /// No description provided for @hubSettingsInterface.
  ///
  /// In zh, this message translates to:
  /// **'界面'**
  String get hubSettingsInterface;

  /// No description provided for @hubSettingsAppearance.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get hubSettingsAppearance;

  /// No description provided for @hubSettingsChatTextSize.
  ///
  /// In zh, this message translates to:
  /// **'对话字号'**
  String get hubSettingsChatTextSize;

  /// No description provided for @hubSettingsCollapseSteps.
  ///
  /// In zh, this message translates to:
  /// **'完成后收起过程'**
  String get hubSettingsCollapseSteps;

  /// No description provided for @hubSettingsProviders.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get hubSettingsProviders;

  /// No description provided for @hubSettingsLicenses.
  ///
  /// In zh, this message translates to:
  /// **'开源许可'**
  String get hubSettingsLicenses;

  /// No description provided for @hubSessionTurns.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 轮'**
  String hubSessionTurns(int count);

  /// No description provided for @hubSessionTurnsRunning.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 轮 · 进行中'**
  String hubSessionTurnsRunning(int count);

  /// No description provided for @hubSessionStepCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 步'**
  String hubSessionStepCount(int count);

  /// No description provided for @hubSessionWaitTime.
  ///
  /// In zh, this message translates to:
  /// **'等你 {duration}'**
  String hubSessionWaitTime(String duration);

  /// No description provided for @hubSessionTurn.
  ///
  /// In zh, this message translates to:
  /// **'第 {turn} 轮'**
  String hubSessionTurn(int turn);

  /// No description provided for @hubSessionFileCount.
  ///
  /// In zh, this message translates to:
  /// **'改动了 {count} 个文件'**
  String hubSessionFileCount(int count);

  /// No description provided for @hubSessionEditCount.
  ///
  /// In zh, this message translates to:
  /// **'改了 {count} 次'**
  String hubSessionEditCount(int count);

  /// No description provided for @hubSessionTurnOf.
  ///
  /// In zh, this message translates to:
  /// **'第 {turn} / {total} 轮'**
  String hubSessionTurnOf(int turn, int total);

  /// No description provided for @hubSessionCacheHit.
  ///
  /// In zh, this message translates to:
  /// **'命中 {percent}'**
  String hubSessionCacheHit(String percent);

  /// No description provided for @hubSessionBlocked.
  ///
  /// In zh, this message translates to:
  /// **'受阻'**
  String get hubSessionBlocked;

  /// No description provided for @hubSessionBlockedReason.
  ///
  /// In zh, this message translates to:
  /// **'受阻：{reason}'**
  String hubSessionBlockedReason(String reason);

  /// No description provided for @hubSessionTodoSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{content},{status}'**
  String hubSessionTodoSemantics(String content, String status);

  /// No description provided for @hubGroupAi.
  ///
  /// In zh, this message translates to:
  /// **'AI'**
  String get hubGroupAi;

  /// No description provided for @hubGroupCapabilities.
  ///
  /// In zh, this message translates to:
  /// **'能力'**
  String get hubGroupCapabilities;

  /// No description provided for @hubGroupGeneral.
  ///
  /// In zh, this message translates to:
  /// **'通用'**
  String get hubGroupGeneral;

  /// No description provided for @hubGroupHosts.
  ///
  /// In zh, this message translates to:
  /// **'主机'**
  String get hubGroupHosts;

  /// No description provided for @hubGroupHelp.
  ///
  /// In zh, this message translates to:
  /// **'帮助与关于'**
  String get hubGroupHelp;

  /// No description provided for @hubAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于鱼鱼远程'**
  String get hubAbout;

  /// No description provided for @hubThemeLightDark.
  ///
  /// In zh, this message translates to:
  /// **'明暗'**
  String get hubThemeLightDark;

  /// No description provided for @iosSaveToFiles.
  ///
  /// In zh, this message translates to:
  /// **'存到「文件」'**
  String get iosSaveToFiles;

  /// No description provided for @iosFilesFolderHint.
  ///
  /// In zh, this message translates to:
  /// **'文件 App 的 DSH Go 文件夹'**
  String get iosFilesFolderHint;

  /// No description provided for @iosSavingToFiles.
  ///
  /// In zh, this message translates to:
  /// **'正在存到「文件」…'**
  String get iosSavingToFiles;

  /// No description provided for @iosCommandExportDescription.
  ///
  /// In zh, this message translates to:
  /// **'把这个对话的完整记录打包成 ZIP，分享或存到「文件」'**
  String get iosCommandExportDescription;

  /// No description provided for @iosPhotosDenied.
  ///
  /// In zh, this message translates to:
  /// **'没有相册权限，未能保存'**
  String get iosPhotosDenied;

  /// No description provided for @localeTitle.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get localeTitle;

  /// No description provided for @localeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get localeSystem;

  /// No description provided for @localeZh.
  ///
  /// In zh, this message translates to:
  /// **'简体中文'**
  String get localeZh;

  /// No description provided for @localeEn.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get localeEn;

  /// No description provided for @mediaAiGenerated.
  ///
  /// In zh, this message translates to:
  /// **'AI 生成'**
  String get mediaAiGenerated;

  /// No description provided for @mediaCostEstimate.
  ///
  /// In zh, this message translates to:
  /// **'约 {amount}'**
  String mediaCostEstimate(String amount);

  /// No description provided for @mediaSavedCount.
  ///
  /// In zh, this message translates to:
  /// **'已保存 {count} 张到相册'**
  String mediaSavedCount(int count);

  /// No description provided for @mediaRegenerate.
  ///
  /// In zh, this message translates to:
  /// **'重新生成'**
  String get mediaRegenerate;

  /// No description provided for @mediaCopyPrompt.
  ///
  /// In zh, this message translates to:
  /// **'复制提示词'**
  String get mediaCopyPrompt;

  /// No description provided for @mediaFileGone.
  ///
  /// In zh, this message translates to:
  /// **'文件已不在'**
  String get mediaFileGone;

  /// No description provided for @mediaKindImage.
  ///
  /// In zh, this message translates to:
  /// **'图像'**
  String get mediaKindImage;

  /// No description provided for @mediaKindVideo.
  ///
  /// In zh, this message translates to:
  /// **'视频'**
  String get mediaKindVideo;

  /// No description provided for @mediaTitleImage.
  ///
  /// In zh, this message translates to:
  /// **'生成图像'**
  String get mediaTitleImage;

  /// No description provided for @mediaTitleVideo.
  ///
  /// In zh, this message translates to:
  /// **'生成视频'**
  String get mediaTitleVideo;

  /// No description provided for @mediaOpenElsewhere.
  ///
  /// In zh, this message translates to:
  /// **'在其他应用中打开'**
  String get mediaOpenElsewhere;

  /// No description provided for @mediaShowInFiles.
  ///
  /// In zh, this message translates to:
  /// **'在文件中显示'**
  String get mediaShowInFiles;

  /// No description provided for @mediaGenerating.
  ///
  /// In zh, this message translates to:
  /// **'生成中'**
  String get mediaGenerating;

  /// No description provided for @mediaCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消'**
  String get mediaCancelled;

  /// No description provided for @mediaNotGenerated.
  ///
  /// In zh, this message translates to:
  /// **'未生成'**
  String get mediaNotGenerated;

  /// No description provided for @mediaPartial.
  ///
  /// In zh, this message translates to:
  /// **'{done} / {total} 张'**
  String mediaPartial(int done, int total);

  /// No description provided for @mediaCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 张'**
  String mediaCount(int count);

  /// No description provided for @mediaSeconds.
  ///
  /// In zh, this message translates to:
  /// **'{seconds} 秒'**
  String mediaSeconds(int seconds);

  /// No description provided for @mediaImageOf.
  ///
  /// In zh, this message translates to:
  /// **'第 {index} 张，共 {count} 张'**
  String mediaImageOf(int index, int count);

  /// No description provided for @mediaPageOf.
  ///
  /// In zh, this message translates to:
  /// **'{index} / {count}'**
  String mediaPageOf(int index, int count);

  /// No description provided for @mediaErrorPolicyInput.
  ///
  /// In zh, this message translates to:
  /// **'描述未通过内容审核'**
  String get mediaErrorPolicyInput;

  /// No description provided for @mediaErrorPolicyOutput.
  ///
  /// In zh, this message translates to:
  /// **'生成结果未通过内容审核'**
  String get mediaErrorPolicyOutput;

  /// No description provided for @mediaErrorAuth.
  ///
  /// In zh, this message translates to:
  /// **'服务未授权'**
  String get mediaErrorAuth;

  /// No description provided for @mediaErrorBalance.
  ///
  /// In zh, this message translates to:
  /// **'余额不足'**
  String get mediaErrorBalance;

  /// No description provided for @mediaErrorQuota.
  ///
  /// In zh, this message translates to:
  /// **'今天的额度已用完'**
  String get mediaErrorQuota;

  /// No description provided for @mediaErrorUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'服务暂时不可用'**
  String get mediaErrorUnavailable;

  /// No description provided for @mediaErrorExpired.
  ///
  /// In zh, this message translates to:
  /// **'结果已过期'**
  String get mediaErrorExpired;

  /// No description provided for @mediaErrorGeneric.
  ///
  /// In zh, this message translates to:
  /// **'没能生成'**
  String get mediaErrorGeneric;

  /// No description provided for @mediaEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get mediaEdit;

  /// No description provided for @mediaMakeVideo.
  ///
  /// In zh, this message translates to:
  /// **'做成视频'**
  String get mediaMakeVideo;

  /// No description provided for @mediaDetailModel.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get mediaDetailModel;

  /// No description provided for @mediaDetailSize.
  ///
  /// In zh, this message translates to:
  /// **'尺寸'**
  String get mediaDetailSize;

  /// No description provided for @mediaDetailCost.
  ///
  /// In zh, this message translates to:
  /// **'费用'**
  String get mediaDetailCost;

  /// No description provided for @mediaDetailProvenance.
  ///
  /// In zh, this message translates to:
  /// **'来源标识'**
  String get mediaDetailProvenance;

  /// No description provided for @mediaDetailFile.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get mediaDetailFile;

  /// No description provided for @mediaOriginalPrompt.
  ///
  /// In zh, this message translates to:
  /// **'原文：{text}'**
  String mediaOriginalPrompt(String text);

  /// No description provided for @mediaProvenanceC2pa.
  ///
  /// In zh, this message translates to:
  /// **'C2PA'**
  String get mediaProvenanceC2pa;

  /// No description provided for @mediaProvenanceImplicit.
  ///
  /// In zh, this message translates to:
  /// **'隐式'**
  String get mediaProvenanceImplicit;

  /// No description provided for @mediaProvenanceVisible.
  ///
  /// In zh, this message translates to:
  /// **'可见水印'**
  String get mediaProvenanceVisible;

  /// No description provided for @mediaParamDuration.
  ///
  /// In zh, this message translates to:
  /// **'时长'**
  String get mediaParamDuration;

  /// No description provided for @mediaVideoLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载视频…'**
  String get mediaVideoLoading;

  /// No description provided for @mediaVideoCannotPlay.
  ///
  /// In zh, this message translates to:
  /// **'无法在 App 内播放此视频，请重试或使用其他应用打开。'**
  String get mediaVideoCannotPlay;

  /// No description provided for @mediaVideoUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'此版本暂不支持在 App 内播放视频，可保存到相册或在其他应用中打开。'**
  String get mediaVideoUnsupported;

  /// No description provided for @mediaVideoPlay.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get mediaVideoPlay;

  /// No description provided for @mediaVideoPause.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get mediaVideoPause;

  /// No description provided for @mediaVideoSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'视频保存失败，请重试。'**
  String get mediaVideoSaveFailed;

  /// No description provided for @mediaImageLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载图片'**
  String get mediaImageLoading;

  /// No description provided for @mediaImageReload.
  ///
  /// In zh, this message translates to:
  /// **'重新加载'**
  String get mediaImageReload;

  /// No description provided for @mediaImageReloadHint.
  ///
  /// In zh, this message translates to:
  /// **'只重新读取文件，不会重新生成或收费'**
  String get mediaImageReloadHint;

  /// No description provided for @mediaVideoNoPoster.
  ///
  /// In zh, this message translates to:
  /// **'轻点播放视频'**
  String get mediaVideoNoPoster;

  /// No description provided for @mediaSavedFilesCount.
  ///
  /// In zh, this message translates to:
  /// **'已保存 {count} 个文件到相册'**
  String mediaSavedFilesCount(int count);

  /// No description provided for @nearbyThisChat.
  ///
  /// In zh, this message translates to:
  /// **'本对话'**
  String get nearbyThisChat;

  /// No description provided for @nearbyPermissionTitle.
  ///
  /// In zh, this message translates to:
  /// **'本对话的权限'**
  String get nearbyPermissionTitle;

  /// No description provided for @nearbyNewChatDefault.
  ///
  /// In zh, this message translates to:
  /// **'新对话默认：{name}'**
  String nearbyNewChatDefault(String name);

  /// No description provided for @nearbySetAsDefault.
  ///
  /// In zh, this message translates to:
  /// **'设为新对话默认'**
  String get nearbySetAsDefault;

  /// No description provided for @nearbyPermissionPill.
  ///
  /// In zh, this message translates to:
  /// **'本对话的权限：{name}'**
  String nearbyPermissionPill(String name);

  /// No description provided for @phoneEngineTidyingFilesEllipsis.
  ///
  /// In zh, this message translates to:
  /// **'正在整理插件文件…'**
  String get phoneEngineTidyingFilesEllipsis;

  /// No description provided for @phoneEngineTitle.
  ///
  /// In zh, this message translates to:
  /// **'本机引擎'**
  String get phoneEngineTitle;

  /// No description provided for @phoneDecisionContinued.
  ///
  /// In zh, this message translates to:
  /// **'你点了继续'**
  String get phoneDecisionContinued;

  /// No description provided for @phoneDecisionDone.
  ///
  /// In zh, this message translates to:
  /// **'已执行'**
  String get phoneDecisionDone;

  /// No description provided for @phoneDecisionTimeout.
  ///
  /// In zh, this message translates to:
  /// **'超时'**
  String get phoneDecisionTimeout;

  /// No description provided for @phoneAccentMist.
  ///
  /// In zh, this message translates to:
  /// **'雾蓝'**
  String get phoneAccentMist;

  /// No description provided for @phoneAccentDaiqing.
  ///
  /// In zh, this message translates to:
  /// **'黛青'**
  String get phoneAccentDaiqing;

  /// No description provided for @phoneAccentDusk.
  ///
  /// In zh, this message translates to:
  /// **'暮紫'**
  String get phoneAccentDusk;

  /// No description provided for @phoneAccentTurquoise.
  ///
  /// In zh, this message translates to:
  /// **'松石'**
  String get phoneAccentTurquoise;

  /// No description provided for @phoneAccentAmber.
  ///
  /// In zh, this message translates to:
  /// **'琥珀'**
  String get phoneAccentAmber;

  /// No description provided for @phoneAccentGraphite.
  ///
  /// In zh, this message translates to:
  /// **'石墨'**
  String get phoneAccentGraphite;

  /// No description provided for @phoneAccentCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get phoneAccentCustom;

  /// No description provided for @plugInputRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写此项'**
  String get plugInputRequired;

  /// No description provided for @plugInputInvalidValue.
  ///
  /// In zh, this message translates to:
  /// **'此处的值无效'**
  String get plugInputInvalidValue;

  /// No description provided for @plugInputNumber.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效数字'**
  String get plugInputNumber;

  /// No description provided for @plugInputBounds.
  ///
  /// In zh, this message translates to:
  /// **'请输入 {min}–{max} 之间的值'**
  String plugInputBounds(String min, String max);

  /// No description provided for @plugInputLength.
  ///
  /// In zh, this message translates to:
  /// **'长度需为 {min}–{max} 个字符'**
  String plugInputLength(int min, int max);

  /// No description provided for @plugInputPattern.
  ///
  /// In zh, this message translates to:
  /// **'格式不正确'**
  String get plugInputPattern;

  /// No description provided for @plugInputDate.
  ///
  /// In zh, this message translates to:
  /// **'请选择有效日期'**
  String get plugInputDate;

  /// No description provided for @plugInputTime.
  ///
  /// In zh, this message translates to:
  /// **'请选择有效时间'**
  String get plugInputTime;

  /// No description provided for @plugInputUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'此处不支持这个组件'**
  String get plugInputUnavailable;

  /// No description provided for @plugInputNoPassword.
  ///
  /// In zh, this message translates to:
  /// **'插件不能使用密码输入框'**
  String get plugInputNoPassword;

  /// No description provided for @plugInputBadBinding.
  ///
  /// In zh, this message translates to:
  /// **'输入绑定必须是 data 下的字段路径'**
  String get plugInputBadBinding;

  /// No description provided for @plugInputDuplicateBinding.
  ///
  /// In zh, this message translates to:
  /// **'一个字段只能绑定一个输入组件'**
  String get plugInputDuplicateBinding;

  /// No description provided for @plugInputNamedPattern.
  ///
  /// In zh, this message translates to:
  /// **'只支持内置的格式校验'**
  String get plugInputNamedPattern;

  /// No description provided for @plugInputNestedForm.
  ///
  /// In zh, this message translates to:
  /// **'表单不能嵌套'**
  String get plugInputNestedForm;

  /// No description provided for @plugInputSubmitMissing.
  ///
  /// In zh, this message translates to:
  /// **'表单缺少提交动作'**
  String get plugInputSubmitMissing;

  /// No description provided for @plugInputTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'内容过多，请缩短后重试'**
  String get plugInputTooLarge;

  /// No description provided for @plugInputCheckFields.
  ///
  /// In zh, this message translates to:
  /// **'请检查标出的项目'**
  String get plugInputCheckFields;

  /// No description provided for @plugInputFailed.
  ///
  /// In zh, this message translates to:
  /// **'未保存，请重试'**
  String get plugInputFailed;

  /// No description provided for @plugInputSubmit.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get plugInputSubmit;

  /// No description provided for @plugInputChoose.
  ///
  /// In zh, this message translates to:
  /// **'选择'**
  String get plugInputChoose;

  /// No description provided for @plugInputPrevious.
  ///
  /// In zh, this message translates to:
  /// **'上一页'**
  String get plugInputPrevious;

  /// No description provided for @plugInputNext.
  ///
  /// In zh, this message translates to:
  /// **'下一页'**
  String get plugInputNext;

  /// No description provided for @plugInputDecrease.
  ///
  /// In zh, this message translates to:
  /// **'减少{label}'**
  String plugInputDecrease(String label);

  /// No description provided for @plugInputIncrease.
  ///
  /// In zh, this message translates to:
  /// **'增加{label}'**
  String plugInputIncrease(String label);

  /// No description provided for @plugInputRating.
  ///
  /// In zh, this message translates to:
  /// **'{label}：{value} 分，共 {max} 分'**
  String plugInputRating(String label, int value, int max);

  /// No description provided for @plugInputFormula.
  ///
  /// In zh, this message translates to:
  /// **'公式无效或超出上限'**
  String get plugInputFormula;

  /// No description provided for @plugInputDatePicker.
  ///
  /// In zh, this message translates to:
  /// **'插件日期'**
  String get plugInputDatePicker;

  /// No description provided for @plugInputTimePicker.
  ///
  /// In zh, this message translates to:
  /// **'插件时间'**
  String get plugInputTimePicker;

  /// No description provided for @plugInputChoices.
  ///
  /// In zh, this message translates to:
  /// **'插件选项'**
  String get plugInputChoices;

  /// No description provided for @pluginsFile.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get pluginsFile;

  /// No description provided for @pluginsChat.
  ///
  /// In zh, this message translates to:
  /// **'对话'**
  String get pluginsChat;

  /// No description provided for @pluginsImage.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get pluginsImage;

  /// No description provided for @pluginsTheme.
  ///
  /// In zh, this message translates to:
  /// **'主题'**
  String get pluginsTheme;

  /// No description provided for @pluginsColors.
  ///
  /// In zh, this message translates to:
  /// **'配色'**
  String get pluginsColors;

  /// No description provided for @pluginsCustomColor.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get pluginsCustomColor;

  /// No description provided for @pluginsColorLabel.
  ///
  /// In zh, this message translates to:
  /// **'配色：{label}'**
  String pluginsColorLabel(String label);

  /// No description provided for @pluginsCoral.
  ///
  /// In zh, this message translates to:
  /// **'珊瑚'**
  String get pluginsCoral;

  /// No description provided for @pluginsRouge.
  ///
  /// In zh, this message translates to:
  /// **'胭脂'**
  String get pluginsRouge;

  /// No description provided for @pluginsOchre.
  ///
  /// In zh, this message translates to:
  /// **'赭石'**
  String get pluginsOchre;

  /// No description provided for @pluginsMoss.
  ///
  /// In zh, this message translates to:
  /// **'苔绿'**
  String get pluginsMoss;

  /// No description provided for @pluginsLake.
  ///
  /// In zh, this message translates to:
  /// **'湖蓝'**
  String get pluginsLake;

  /// No description provided for @pluginsIndigo.
  ///
  /// In zh, this message translates to:
  /// **'靛紫'**
  String get pluginsIndigo;

  /// No description provided for @pluginsHue.
  ///
  /// In zh, this message translates to:
  /// **'色相'**
  String get pluginsHue;

  /// No description provided for @pluginsWallpaper.
  ///
  /// In zh, this message translates to:
  /// **'壁纸'**
  String get pluginsWallpaper;

  /// No description provided for @pluginsFollowWallpaper.
  ///
  /// In zh, this message translates to:
  /// **'跟随壁纸'**
  String get pluginsFollowWallpaper;

  /// No description provided for @plugViewInvalid.
  ///
  /// In zh, this message translates to:
  /// **'插件界面有误'**
  String get plugViewInvalid;

  /// No description provided for @plugViewEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无数据'**
  String get plugViewEmpty;

  /// No description provided for @plugViewImageUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'图片无法显示'**
  String get plugViewImageUnavailable;

  /// No description provided for @plugViewUnavailableList.
  ///
  /// In zh, this message translates to:
  /// **'列表无法显示'**
  String get plugViewUnavailableList;

  /// No description provided for @plugViewUnavailableKeyValue.
  ///
  /// In zh, this message translates to:
  /// **'信息无法显示'**
  String get plugViewUnavailableKeyValue;

  /// No description provided for @plugViewUnavailableProgress.
  ///
  /// In zh, this message translates to:
  /// **'进度无法显示'**
  String get plugViewUnavailableProgress;

  /// No description provided for @plugViewUnavailableTable.
  ///
  /// In zh, this message translates to:
  /// **'表格无法显示'**
  String get plugViewUnavailableTable;

  /// No description provided for @plugViewUnavailableActions.
  ///
  /// In zh, this message translates to:
  /// **'按钮无法显示'**
  String get plugViewUnavailableActions;

  /// No description provided for @plugViewFrom.
  ///
  /// In zh, this message translates to:
  /// **'来自 {name}'**
  String plugViewFrom(String name);

  /// No description provided for @plugViewUnknownTone.
  ///
  /// In zh, this message translates to:
  /// **'未知 tone {value}，已忽略；可用：good, warn, bad, info, muted'**
  String plugViewUnknownTone(String value);

  /// No description provided for @plugViewBadActionId.
  ///
  /// In zh, this message translates to:
  /// **'动作 id {value} 不合规，这个元素不可点'**
  String plugViewBadActionId(String value);

  /// No description provided for @plugViewBadAction.
  ///
  /// In zh, this message translates to:
  /// **'动作应该是 id 字符串或 {shape}，已忽略'**
  String plugViewBadAction(String shape);

  /// No description provided for @plugViewArgsLimit.
  ///
  /// In zh, this message translates to:
  /// **'动作参数超过 {limit} 字节，已忽略'**
  String plugViewArgsLimit(int limit);

  /// No description provided for @plugViewUnknownIcon.
  ///
  /// In zh, this message translates to:
  /// **'未知图标 {value}，画默认图标'**
  String plugViewUnknownIcon(String value);

  /// No description provided for @plugViewExpectedItems.
  ///
  /// In zh, this message translates to:
  /// **'应该是数组，每项是 {shape}'**
  String plugViewExpectedItems(String shape);

  /// No description provided for @plugViewSkippedItem.
  ///
  /// In zh, this message translates to:
  /// **'应该是 {shape}，这项已跳过'**
  String plugViewSkippedItem(String shape);

  /// No description provided for @plugViewBadMax.
  ///
  /// In zh, this message translates to:
  /// **'max 应该是大于 0 的数，按 100 算'**
  String get plugViewBadMax;

  /// No description provided for @plugViewColumnLimit.
  ///
  /// In zh, this message translates to:
  /// **'{first} 列，超过上限 {second}'**
  String plugViewColumnLimit(int first, int second);

  /// No description provided for @plugViewFirstColumns.
  ///
  /// In zh, this message translates to:
  /// **'只显示前 {limit} 列'**
  String plugViewFirstColumns(int limit);

  /// No description provided for @plugViewFirstRows.
  ///
  /// In zh, this message translates to:
  /// **'只显示前 {limit} 行'**
  String plugViewFirstRows(int limit);

  /// No description provided for @plugViewOnePrimary.
  ///
  /// In zh, this message translates to:
  /// **'一张视图只能有一个主按钮，这个按普通按钮画'**
  String get plugViewOnePrimary;

  /// No description provided for @plugViewBadImageSource.
  ///
  /// In zh, this message translates to:
  /// **'图片只收插件资源 asset:<路径>（png、jpg、webp、gif）或 data:image/…'**
  String get plugViewBadImageSource;

  /// No description provided for @plugViewBadAspect.
  ///
  /// In zh, this message translates to:
  /// **'aspect 应该是 0.25 到 4 之间的数，已忽略'**
  String get plugViewBadAspect;

  /// No description provided for @plugViewImageTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'data: 图片超过 {limit} 字节'**
  String plugViewImageTooLarge(int limit);

  /// No description provided for @plugViewImageDecode.
  ///
  /// In zh, this message translates to:
  /// **'图片无法解码（只收 PNG、JPEG、WebP、GIF）'**
  String get plugViewImageDecode;

  /// No description provided for @plugViewImagePixels.
  ///
  /// In zh, this message translates to:
  /// **'图片尺寸超过上限：单边 4096、总数 400 万像素'**
  String get plugViewImagePixels;

  /// No description provided for @plugViewTooDeep.
  ///
  /// In zh, this message translates to:
  /// **'JSON 嵌套超过 {limit} 层'**
  String plugViewTooDeep(int limit);

  /// No description provided for @plugViewV2Content.
  ///
  /// In zh, this message translates to:
  /// **'插件内容'**
  String get plugViewV2Content;

  /// No description provided for @plugViewVersionFallback.
  ///
  /// In zh, this message translates to:
  /// **'暂不支持视图版本 {version}，已使用兼容显示'**
  String plugViewVersionFallback(String version);

  /// No description provided for @plugViewStyleInvalid.
  ///
  /// In zh, this message translates to:
  /// **'样式无效，支持 {values}'**
  String plugViewStyleInvalid(String values);

  /// No description provided for @plugViewStyleReserved.
  ///
  /// In zh, this message translates to:
  /// **'此样式由 App 保留，已忽略'**
  String get plugViewStyleReserved;

  /// No description provided for @plugViewStyleContainerOnly.
  ///
  /// In zh, this message translates to:
  /// **'此样式仅用于 stack 和 row'**
  String get plugViewStyleContainerOnly;

  /// No description provided for @plugViewStyleTextOnly.
  ///
  /// In zh, this message translates to:
  /// **'此样式仅用于 text、metric 和 callout'**
  String get plugViewStyleTextOnly;

  /// No description provided for @plugViewContrastAdjusted.
  ///
  /// In zh, this message translates to:
  /// **'{mode}：{before} 已校正为 {after}，对比度至少 {minimum}:1'**
  String plugViewContrastAdjusted(String mode, String before, String after, String minimum);

  /// No description provided for @plugViewRichLimit.
  ///
  /// In zh, this message translates to:
  /// **'富文本超出上限，已截断'**
  String get plugViewRichLimit;

  /// No description provided for @plugViewBadTrend.
  ///
  /// In zh, this message translates to:
  /// **'trend 要 2–{max} 个数字（可以有 null），已忽略'**
  String plugViewBadTrend(int max);

  /// No description provided for @plugViewGalleryPicture.
  ///
  /// In zh, this message translates to:
  /// **'第 {index} 张'**
  String plugViewGalleryPicture(int index);

  /// No description provided for @portalAppName.
  ///
  /// In zh, this message translates to:
  /// **'鱼鱼远程'**
  String get portalAppName;

  /// No description provided for @portalRemoteOnly.
  ///
  /// In zh, this message translates to:
  /// **'连接 YuRemote 服务器，引擎仅在远程主机运行。'**
  String get portalRemoteOnly;

  /// No description provided for @portalAddress.
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get portalAddress;

  /// No description provided for @portalName.
  ///
  /// In zh, this message translates to:
  /// **'服务器名称'**
  String get portalName;

  /// No description provided for @portalPassword.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get portalPassword;

  /// No description provided for @portalScan.
  ///
  /// In zh, this message translates to:
  /// **'扫描服务器或配对链接'**
  String get portalScan;

  /// No description provided for @portalPairingReady.
  ///
  /// In zh, this message translates to:
  /// **'配对链接已就绪'**
  String get portalPairingReady;

  /// No description provided for @portalWebRemoved.
  ///
  /// In zh, this message translates to:
  /// **'鱼鱼远程不提供内嵌网页功能。'**
  String get portalWebRemoved;

  /// No description provided for @portalProjectRepository.
  ///
  /// In zh, this message translates to:
  /// **'项目仓库'**
  String get portalProjectRepository;

  /// No description provided for @portalUpstreamCredit.
  ///
  /// In zh, this message translates to:
  /// **'上游来源'**
  String get portalUpstreamCredit;

  /// No description provided for @portalLicenseSplit.
  ///
  /// In zh, this message translates to:
  /// **'鱼鱼远程及导入的 Dart 包采用 AGPL-3.0 许可。独立的服务端网关采用 MIT 许可。'**
  String get portalLicenseSplit;

  /// No description provided for @portalArtworkCredit.
  ///
  /// In zh, this message translates to:
  /// **'鱼鱼远程插画由 Tsuki 提供。未包含上游受保护的品牌与吉祥物。'**
  String get portalArtworkCredit;

  /// No description provided for @portalDirectoryParent.
  ///
  /// In zh, this message translates to:
  /// **'上一级文件夹'**
  String get portalDirectoryParent;

  /// No description provided for @portalDirectoryHostHint.
  ///
  /// In zh, this message translates to:
  /// **'文件夹位于远程主机上，而非此设备。'**
  String get portalDirectoryHostHint;

  /// No description provided for @readListUpdating.
  ///
  /// In zh, this message translates to:
  /// **'更新中 · 上次结果'**
  String get readListUpdating;

  /// No description provided for @readListOffline.
  ///
  /// In zh, this message translates to:
  /// **'离线 · 上次结果'**
  String get readListOffline;

  /// No description provided for @readListFailed.
  ///
  /// In zh, this message translates to:
  /// **'未更新 · 上次结果'**
  String get readListFailed;

  /// No description provided for @remoteStepConnect.
  ///
  /// In zh, this message translates to:
  /// **'连接服务器'**
  String get remoteStepConnect;

  /// No description provided for @remoteStepVerifyHostKey.
  ///
  /// In zh, this message translates to:
  /// **'验证主机指纹'**
  String get remoteStepVerifyHostKey;

  /// No description provided for @remoteStepStartDsh.
  ///
  /// In zh, this message translates to:
  /// **'启动 DSH'**
  String get remoteStepStartDsh;

  /// No description provided for @remoteStepTunnel.
  ///
  /// In zh, this message translates to:
  /// **'建立隧道'**
  String get remoteStepTunnel;

  /// No description provided for @remoteConnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接'**
  String get remoteConnecting;

  /// No description provided for @remoteConnected.
  ///
  /// In zh, this message translates to:
  /// **'已连接'**
  String get remoteConnected;

  /// No description provided for @remoteReconnecting.
  ///
  /// In zh, this message translates to:
  /// **'重新连接中'**
  String get remoteReconnecting;

  /// No description provided for @remoteReconnectAttempt.
  ///
  /// In zh, this message translates to:
  /// **'重新连接中 · 第 {count} 次'**
  String remoteReconnectAttempt(int count);

  /// No description provided for @remoteHostedErrNetwork.
  ///
  /// In zh, this message translates to:
  /// **'没能连上分享服务，检查网络后重试'**
  String get remoteHostedErrNetwork;

  /// No description provided for @remoteHostedErrTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'对话太大，生成不了链接'**
  String get remoteHostedErrTooLarge;

  /// No description provided for @remoteHostedErrRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'分享太频繁，稍后再试'**
  String get remoteHostedErrRateLimited;

  /// No description provided for @remoteHostedErrCreate.
  ///
  /// In zh, this message translates to:
  /// **'没能生成链接'**
  String get remoteHostedErrCreate;

  /// No description provided for @remoteHostedErrUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'分享服务暂时不可用，稍后再试'**
  String get remoteHostedErrUnavailable;

  /// No description provided for @remoteHostedErrGone.
  ///
  /// In zh, this message translates to:
  /// **'链接已过期或被删除'**
  String get remoteHostedErrGone;

  /// No description provided for @remoteHostedErrForbidden.
  ///
  /// In zh, this message translates to:
  /// **'没有权限删除这个链接'**
  String get remoteHostedErrForbidden;

  /// No description provided for @remoteHostedErrBroken.
  ///
  /// In zh, this message translates to:
  /// **'链接不完整或已损坏'**
  String get remoteHostedErrBroken;

  /// No description provided for @remoteChat.
  ///
  /// In zh, this message translates to:
  /// **'对话'**
  String get remoteChat;

  /// No description provided for @remoteHostedTtlWeek.
  ///
  /// In zh, this message translates to:
  /// **'7 天'**
  String get remoteHostedTtlWeek;

  /// No description provided for @remoteHostedTtlMonth.
  ///
  /// In zh, this message translates to:
  /// **'30 天'**
  String get remoteHostedTtlMonth;

  /// No description provided for @remoteHostedTtlForever.
  ///
  /// In zh, this message translates to:
  /// **'永久'**
  String get remoteHostedTtlForever;

  /// No description provided for @remoteLinkCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制链接'**
  String get remoteLinkCopied;

  /// No description provided for @remotePathDirect.
  ///
  /// In zh, this message translates to:
  /// **'直连'**
  String get remotePathDirect;

  /// No description provided for @remotePathTurn.
  ///
  /// In zh, this message translates to:
  /// **'TURN'**
  String get remotePathTurn;

  /// No description provided for @remotePathRelay.
  ///
  /// In zh, this message translates to:
  /// **'Relay 中继'**
  String get remotePathRelay;

  /// No description provided for @remoteHost.
  ///
  /// In zh, this message translates to:
  /// **'主机'**
  String get remoteHost;

  /// No description provided for @remoteHostedUpdateRequired.
  ///
  /// In zh, this message translates to:
  /// **'需要更新 App 才能打开'**
  String get remoteHostedUpdateRequired;

  /// No description provided for @remoteHostedCannotOpen.
  ///
  /// In zh, this message translates to:
  /// **'这个链接无法打开'**
  String get remoteHostedCannotOpen;

  /// No description provided for @remoteOpening.
  ///
  /// In zh, this message translates to:
  /// **'正在打开…'**
  String get remoteOpening;

  /// No description provided for @remoteHostedNeverExpires.
  ///
  /// In zh, this message translates to:
  /// **'永久有效'**
  String get remoteHostedNeverExpires;

  /// No description provided for @remoteHostedExpired.
  ///
  /// In zh, this message translates to:
  /// **'已过期'**
  String get remoteHostedExpired;

  /// No description provided for @remoteHostedExpiresToday.
  ///
  /// In zh, this message translates to:
  /// **'今天到期'**
  String get remoteHostedExpiresToday;

  /// No description provided for @remoteHostedExpiresTomorrow.
  ///
  /// In zh, this message translates to:
  /// **'明天到期'**
  String get remoteHostedExpiresTomorrow;

  /// No description provided for @remoteHostedExpiresOn.
  ///
  /// In zh, this message translates to:
  /// **'{date}到期'**
  String remoteHostedExpiresOn(String date);

  /// No description provided for @remoteHostedDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除这个链接？'**
  String get remoteHostedDeleteTitle;

  /// No description provided for @remoteHostedDeleteBody.
  ///
  /// In zh, this message translates to:
  /// **'「{title}」的链接会立即失效'**
  String remoteHostedDeleteBody(String title);

  /// No description provided for @remoteHostedLinkDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除链接'**
  String get remoteHostedLinkDeleted;

  /// No description provided for @remoteUndo.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get remoteUndo;

  /// No description provided for @remoteHostedMyLinks.
  ///
  /// In zh, this message translates to:
  /// **'我的分享链接'**
  String get remoteHostedMyLinks;

  /// No description provided for @remoteHostedNoLinks.
  ///
  /// In zh, this message translates to:
  /// **'还没有分享链接'**
  String get remoteHostedNoLinks;

  /// No description provided for @remoteHostedErrDeleteNetwork.
  ///
  /// In zh, this message translates to:
  /// **'没能删除，检查网络后重试'**
  String get remoteHostedErrDeleteNetwork;

  /// No description provided for @remoteHostedErrDelete.
  ///
  /// In zh, this message translates to:
  /// **'没能删除，稍后再试'**
  String get remoteHostedErrDelete;

  /// No description provided for @remoteDirectoryPickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择文件夹'**
  String get remoteDirectoryPickerTitle;

  /// No description provided for @remoteDirectoryChoose.
  ///
  /// In zh, this message translates to:
  /// **'选择'**
  String get remoteDirectoryChoose;

  /// No description provided for @remoteDirectoryDefault.
  ///
  /// In zh, this message translates to:
  /// **'默认工作目录'**
  String get remoteDirectoryDefault;

  /// No description provided for @remoteDirectoryHome.
  ///
  /// In zh, this message translates to:
  /// **'主目录'**
  String get remoteDirectoryHome;

  /// No description provided for @remoteDirectoryPhoneStorage.
  ///
  /// In zh, this message translates to:
  /// **'手机存储'**
  String get remoteDirectoryPhoneStorage;

  /// No description provided for @remoteDirectoryLocations.
  ///
  /// In zh, this message translates to:
  /// **'位置'**
  String get remoteDirectoryLocations;

  /// No description provided for @remoteDirectoryRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近'**
  String get remoteDirectoryRecent;

  /// No description provided for @remoteDirectoryEnterPath.
  ///
  /// In zh, this message translates to:
  /// **'输入路径'**
  String get remoteDirectoryEnterPath;

  /// No description provided for @remoteDirectoryGo.
  ///
  /// In zh, this message translates to:
  /// **'前往'**
  String get remoteDirectoryGo;

  /// No description provided for @remoteDirectoryAbsolutePath.
  ///
  /// In zh, this message translates to:
  /// **'写完整路径，如 /root/workspace 或 C:/Users/me'**
  String get remoteDirectoryAbsolutePath;

  /// No description provided for @remoteDirectoryNewFolder.
  ///
  /// In zh, this message translates to:
  /// **'新建文件夹'**
  String get remoteDirectoryNewFolder;

  /// No description provided for @remoteDirectoryParentCaption.
  ///
  /// In zh, this message translates to:
  /// **'在「{name}」里'**
  String remoteDirectoryParentCaption(String name);

  /// No description provided for @remoteDirectoryFolderName.
  ///
  /// In zh, this message translates to:
  /// **'文件夹名称'**
  String get remoteDirectoryFolderName;

  /// No description provided for @remoteDirectoryRoot.
  ///
  /// In zh, this message translates to:
  /// **'根目录'**
  String get remoteDirectoryRoot;

  /// No description provided for @remoteDirectoryErrCreate.
  ///
  /// In zh, this message translates to:
  /// **'没能新建文件夹'**
  String get remoteDirectoryErrCreate;

  /// No description provided for @remoteDirectoryNoSubfolders.
  ///
  /// In zh, this message translates to:
  /// **'这里没有子文件夹'**
  String get remoteDirectoryNoSubfolders;

  /// No description provided for @remoteDirectoryHideHidden.
  ///
  /// In zh, this message translates to:
  /// **'收起隐藏文件夹'**
  String get remoteDirectoryHideHidden;

  /// No description provided for @remoteDirectoryShowHidden.
  ///
  /// In zh, this message translates to:
  /// **'显示 {count} 个隐藏文件夹'**
  String remoteDirectoryShowHidden(int count);

  /// No description provided for @remoteDirectoryTruncated.
  ///
  /// In zh, this message translates to:
  /// **'文件夹太多，只列出了前面一部分'**
  String get remoteDirectoryTruncated;

  /// No description provided for @remoteWorkspaceAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加工作区'**
  String get remoteWorkspaceAdd;

  /// No description provided for @remoteWorkspaceAdded.
  ///
  /// In zh, this message translates to:
  /// **'已添加「{name}」'**
  String remoteWorkspaceAdded(String name);

  /// No description provided for @remoteWorkspaceErrAdd.
  ///
  /// In zh, this message translates to:
  /// **'没能添加工作区'**
  String get remoteWorkspaceErrAdd;

  /// No description provided for @remoteWorkspaceNoChats.
  ///
  /// In zh, this message translates to:
  /// **'没有对话'**
  String get remoteWorkspaceNoChats;

  /// No description provided for @remoteWorkspaceChatCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个对话'**
  String remoteWorkspaceChatCount(int count);

  /// No description provided for @remoteWorkspaceErrRename.
  ///
  /// In zh, this message translates to:
  /// **'没能重命名'**
  String get remoteWorkspaceErrRename;

  /// No description provided for @remoteWorkspaceRemoved.
  ///
  /// In zh, this message translates to:
  /// **'已移除「{name}」'**
  String remoteWorkspaceRemoved(String name);

  /// No description provided for @remoteWorkspaceErrRemove.
  ///
  /// In zh, this message translates to:
  /// **'没能移除工作区'**
  String get remoteWorkspaceErrRemove;

  /// No description provided for @remoteWorkspaceRename.
  ///
  /// In zh, this message translates to:
  /// **'重命名工作区'**
  String get remoteWorkspaceRename;

  /// No description provided for @remoteWorkspaceName.
  ///
  /// In zh, this message translates to:
  /// **'工作区名称'**
  String get remoteWorkspaceName;

  /// No description provided for @remoteWorkspaceNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'起个名字'**
  String get remoteWorkspaceNameRequired;

  /// No description provided for @remoteWorkspaceRemoveTitle.
  ///
  /// In zh, this message translates to:
  /// **'移除「{name}」？'**
  String remoteWorkspaceRemoveTitle(String name);

  /// No description provided for @remoteWorkspaceRemoveBody.
  ///
  /// In zh, this message translates to:
  /// **'文件夹和对话都会保留'**
  String get remoteWorkspaceRemoveBody;

  /// No description provided for @remoteWorkspaceRemove.
  ///
  /// In zh, this message translates to:
  /// **'移除'**
  String get remoteWorkspaceRemove;

  /// No description provided for @remoteWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'工作区'**
  String get remoteWorkspace;

  /// No description provided for @remoteWorkspaceNewChatHere.
  ///
  /// In zh, this message translates to:
  /// **'在这里新建对话'**
  String get remoteWorkspaceNewChatHere;

  /// No description provided for @remoteWorkspaceUnpin.
  ///
  /// In zh, this message translates to:
  /// **'取消置顶'**
  String get remoteWorkspaceUnpin;

  /// No description provided for @remoteWorkspaceGroup.
  ///
  /// In zh, this message translates to:
  /// **'分组'**
  String get remoteWorkspaceGroup;

  /// No description provided for @remoteWorkspaceUngrouped.
  ///
  /// In zh, this message translates to:
  /// **'未分组'**
  String get remoteWorkspaceUngrouped;

  /// No description provided for @remoteWorkspaceRemoveAction.
  ///
  /// In zh, this message translates to:
  /// **'移除工作区'**
  String get remoteWorkspaceRemoveAction;

  /// No description provided for @remoteWorkspaceNewGroup.
  ///
  /// In zh, this message translates to:
  /// **'新建分组'**
  String get remoteWorkspaceNewGroup;

  /// No description provided for @remoteWorkspaceGroupName.
  ///
  /// In zh, this message translates to:
  /// **'分组名称'**
  String get remoteWorkspaceGroupName;

  /// No description provided for @remoteDirectoryInvalidName.
  ///
  /// In zh, this message translates to:
  /// **'名字里不能有「/」'**
  String get remoteDirectoryInvalidName;

  /// No description provided for @remoteWorkspaceErrNameConflict.
  ///
  /// In zh, this message translates to:
  /// **'已有同名的工作区'**
  String get remoteWorkspaceErrNameConflict;

  /// No description provided for @remoteWorkspaceErrInvalidPath.
  ///
  /// In zh, this message translates to:
  /// **'这个文件夹不能用作工作区'**
  String get remoteWorkspaceErrInvalidPath;

  /// No description provided for @remoteWorkspaceErrNotFound.
  ///
  /// In zh, this message translates to:
  /// **'这个工作区已经不在了'**
  String get remoteWorkspaceErrNotFound;

  /// No description provided for @remoteDirectoryErrUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'打不开这个文件夹'**
  String get remoteDirectoryErrUnreadable;

  /// No description provided for @remoteDirectoryErrExists.
  ///
  /// In zh, this message translates to:
  /// **'已经有同名的文件夹'**
  String get remoteDirectoryErrExists;

  /// No description provided for @remoteDirectoryErrUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'这台主机不能在这里浏览文件夹'**
  String get remoteDirectoryErrUnavailable;

  /// No description provided for @remoteWorkspaceErrUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'这台主机不支持这个操作'**
  String get remoteWorkspaceErrUnsupported;

  /// No description provided for @remoteWorkspaceAllChats.
  ///
  /// In zh, this message translates to:
  /// **'全部对话'**
  String get remoteWorkspaceAllChats;

  /// No description provided for @remoteWorkspaceSwitcherSemantics.
  ///
  /// In zh, this message translates to:
  /// **'工作区：{name}。切换工作区'**
  String remoteWorkspaceSwitcherSemantics(String name);

  /// No description provided for @remoteWorkspaceManage.
  ///
  /// In zh, this message translates to:
  /// **'管理工作区'**
  String get remoteWorkspaceManage;

  /// No description provided for @remoteWorkspaceErrLoad.
  ///
  /// In zh, this message translates to:
  /// **'没能读取工作区'**
  String get remoteWorkspaceErrLoad;

  /// No description provided for @remoteWorkspaceEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有工作区'**
  String get remoteWorkspaceEmpty;

  /// No description provided for @remoteWorkspaceEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'把常用的文件夹加进来'**
  String get remoteWorkspaceEmptyHint;

  /// No description provided for @remoteWorkspaceCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个工作区'**
  String remoteWorkspaceCount(int count);

  /// No description provided for @remoteDirectoryConfirmFolder.
  ///
  /// In zh, this message translates to:
  /// **'{action}「{name}」'**
  String remoteDirectoryConfirmFolder(String action, String name);

  /// No description provided for @remoteHostedMonthDate.
  ///
  /// In zh, this message translates to:
  /// **'{month} 月 {day} 日'**
  String remoteHostedMonthDate(String month, int day);

  /// No description provided for @remoteHostedYearDate.
  ///
  /// In zh, this message translates to:
  /// **'{year} 年 {month} 月 {day} 日'**
  String remoteHostedYearDate(int year, String month, int day);

  /// No description provided for @remoteErrorDetail.
  ///
  /// In zh, this message translates to:
  /// **'{message}（{detail}）'**
  String remoteErrorDetail(String message, String detail);

  /// No description provided for @remotePathLan.
  ///
  /// In zh, this message translates to:
  /// **'LAN 局域网'**
  String get remotePathLan;

  /// No description provided for @remotePathP2p.
  ///
  /// In zh, this message translates to:
  /// **'P2P 点对点'**
  String get remotePathP2p;

  /// No description provided for @remoteNetworkDetails.
  ///
  /// In zh, this message translates to:
  /// **'网络详情'**
  String get remoteNetworkDetails;

  /// No description provided for @remoteHostedLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法读取已保存的分享链接，请重试。'**
  String get remoteHostedLoadFailed;

  /// No description provided for @remoteHostedSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'分享链接的更改尚未保存，请重试。'**
  String get remoteHostedSaveFailed;

  /// No description provided for @remoteHostedDeleteSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除未完成，链接仍然有效。请重试。'**
  String get remoteHostedDeleteSaveFailed;

  /// No description provided for @remoteHostedUndoUnsaved.
  ///
  /// In zh, this message translates to:
  /// **'本次删除已取消，但撤销尚未保存。重启后可能继续删除，请到“我的分享链接”重试保存。'**
  String get remoteHostedUndoUnsaved;

  /// No description provided for @remoteHostedUndoFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法恢复分享，删除可能已开始。请检查“我的分享链接”。'**
  String get remoteHostedUndoFailed;

  /// No description provided for @remoteHostedCreatedUnsaved.
  ///
  /// In zh, this message translates to:
  /// **'链接已创建，可以复制使用，但尚未保存到本机。请保留链接，并到“我的分享链接”重试保存。'**
  String get remoteHostedCreatedUnsaved;

  /// No description provided for @remoteHostedStopFailed.
  ///
  /// In zh, this message translates to:
  /// **'未能停止分享，链接仍然有效。请重试。'**
  String get remoteHostedStopFailed;

  /// No description provided for @stateWorkspaceFilesHint.
  ///
  /// In zh, this message translates to:
  /// **'已上传到当前工作区的文件：'**
  String get stateWorkspaceFilesHint;

  /// No description provided for @stateRemoteUploadNameInvalid.
  ///
  /// In zh, this message translates to:
  /// **'文件名不受主机支持，请去掉特殊字符或缩短后再试'**
  String get stateRemoteUploadNameInvalid;

  /// No description provided for @stateRemoteUploadWorkspaceUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前对话没有可写的工作目录'**
  String get stateRemoteUploadWorkspaceUnavailable;

  /// No description provided for @stateRemoteUploadWorkspaceChanged.
  ///
  /// In zh, this message translates to:
  /// **'工作目录已变化，请确认后重新上传'**
  String get stateRemoteUploadWorkspaceChanged;

  /// No description provided for @stateRemoteUploadLimit.
  ///
  /// In zh, this message translates to:
  /// **'主机拒绝了上传，请检查文件大小或稍后重试'**
  String get stateRemoteUploadLimit;

  /// No description provided for @stateRemoteUploadUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'这台主机不支持文件上传，请更新主机上的 Remote 插件后重连'**
  String get stateRemoteUploadUnsupported;

  /// No description provided for @stateRemoteUploadTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'文件超过远程上传协议的大小上限'**
  String get stateRemoteUploadTooLarge;

  /// No description provided for @riskDontShowAgain.
  ///
  /// In zh, this message translates to:
  /// **'不再提示'**
  String get riskDontShowAgain;

  /// No description provided for @riskFullAccessAction.
  ///
  /// In zh, this message translates to:
  /// **'开启完全权限'**
  String get riskFullAccessAction;

  /// No description provided for @riskAutoReviewAction.
  ///
  /// In zh, this message translates to:
  /// **'开启自动审查'**
  String get riskAutoReviewAction;

  /// No description provided for @riskAllowForChatTitle.
  ///
  /// In zh, this message translates to:
  /// **'本对话都允许？'**
  String get riskAllowForChatTitle;

  /// No description provided for @riskAllowForChatBody.
  ///
  /// In zh, this message translates to:
  /// **'这个对话之后的命令和改动都直接放行，可在输入框上方随时关闭。'**
  String get riskAllowForChatBody;

  /// No description provided for @riskAllowForChatAction.
  ///
  /// In zh, this message translates to:
  /// **'全部允许'**
  String get riskAllowForChatAction;

  /// No description provided for @searchNeedsEngineField.
  ///
  /// In zh, this message translates to:
  /// **'当前主机提供时可用'**
  String get searchNeedsEngineField;

  /// No description provided for @searchNeedsAnimations.
  ///
  /// In zh, this message translates to:
  /// **'开启动画时可用'**
  String get searchNeedsAnimations;

  /// No description provided for @searchNeedsChat.
  ///
  /// In zh, this message translates to:
  /// **'打开对话时可用'**
  String get searchNeedsChat;

  /// No description provided for @searchKwTheme.
  ///
  /// In zh, this message translates to:
  /// **'外观,配色,颜色,主题色,强调色,图标'**
  String get searchKwTheme;

  /// No description provided for @searchKwModels.
  ///
  /// In zh, this message translates to:
  /// **'模型渠道,渠道,供应商,换模型,OpenRouter,ChatGPT,Claude'**
  String get searchKwModels;

  /// No description provided for @searchKwRemote.
  ///
  /// In zh, this message translates to:
  /// **'远程,SSH,电脑,服务器,DSH Remote,连接电脑'**
  String get searchKwRemote;

  /// No description provided for @searchKwPermission.
  ///
  /// In zh, this message translates to:
  /// **'权限,别问我,确认,审批,自动允许,只读,完全权限,自动执行命令'**
  String get searchKwPermission;

  /// No description provided for @searchKwAgentPresets.
  ///
  /// In zh, this message translates to:
  /// **'预设,模式,工作方式'**
  String get searchKwAgentPresets;

  /// No description provided for @searchKwLanguage.
  ///
  /// In zh, this message translates to:
  /// **'中文,英文,简体,English'**
  String get searchKwLanguage;

  /// No description provided for @searchKwTextSize.
  ///
  /// In zh, this message translates to:
  /// **'字号,字体,文字大小,大字,字体大小'**
  String get searchKwTextSize;

  /// No description provided for @searchKwFoldTurns.
  ///
  /// In zh, this message translates to:
  /// **'收起,折叠,过程,步骤'**
  String get searchKwFoldTurns;

  /// No description provided for @searchKwVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本号,关于'**
  String get searchKwVersion;

  /// No description provided for @searchKwLicenses.
  ///
  /// In zh, this message translates to:
  /// **'许可证,开源,License'**
  String get searchKwLicenses;

  /// No description provided for @searchKwDarkMode.
  ///
  /// In zh, this message translates to:
  /// **'深色,浅色,暗色,夜间,深色模式,跟随系统,外观'**
  String get searchKwDarkMode;

  /// No description provided for @searchKwAccent.
  ///
  /// In zh, this message translates to:
  /// **'颜色,主题色,强调色,壁纸,取色'**
  String get searchKwAccent;

  /// No description provided for @searchKwPermissionCurrent.
  ///
  /// In zh, this message translates to:
  /// **'本对话都允许,这个对话,当前权限'**
  String get searchKwPermissionCurrent;

  /// No description provided for @searchKwPermissionDefault.
  ///
  /// In zh, this message translates to:
  /// **'默认权限,只读,工作区内修改,完全权限,自动执行命令,别问我'**
  String get searchKwPermissionDefault;

  /// No description provided for @searchSettingsHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索设置'**
  String get searchSettingsHint;

  /// No description provided for @searchNoResults.
  ///
  /// In zh, this message translates to:
  /// **'没有找到相关设置'**
  String get searchNoResults;

  /// No description provided for @searchKwAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于,版本,更新,许可,dsh-go'**
  String get searchKwAbout;

  /// No description provided for @shellDeletePermanently.
  ///
  /// In zh, this message translates to:
  /// **'永久删除'**
  String get shellDeletePermanently;

  /// No description provided for @shellDeleteNoUndo.
  ///
  /// In zh, this message translates to:
  /// **'无法撤销，与归档不同'**
  String get shellDeleteNoUndo;

  /// No description provided for @shellDeleteChecking.
  ///
  /// In zh, this message translates to:
  /// **'正在检查此主机是否支持永久删除…'**
  String get shellDeleteChecking;

  /// No description provided for @shellDeleteUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'此主机不支持安全永久删除，仍可使用归档。'**
  String get shellDeleteUnsupported;

  /// No description provided for @shellDeleteUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'安全永久删除暂不可用，请重连或更新此主机；不会改为归档。'**
  String get shellDeleteUnavailable;

  /// No description provided for @shellDeleteChatConfirmation.
  ///
  /// In zh, this message translates to:
  /// **'永久删除「{title}」？'**
  String shellDeleteChatConfirmation(String title);

  /// No description provided for @shellDeleteChatsConfirmation.
  ///
  /// In zh, this message translates to:
  /// **'永久删除 {count} 个对话？'**
  String shellDeleteChatsConfirmation(int count);

  /// No description provided for @shellDeleteWarning.
  ///
  /// In zh, this message translates to:
  /// **'将从此主机永久删除所选对话记录，无法撤销，与归档不同。\n\n工作目录、生成的文件、分叉对话、共享附件和已发布的云端分享都会保留。云端分享需另行删除。子代理对话会随所选对话一起删除。运行中或有定时任务的对话会被主机拒绝。'**
  String get shellDeleteWarning;

  /// No description provided for @shellDeleteOwnerChanged.
  ///
  /// In zh, this message translates to:
  /// **'主机或连接已变化。请取消后重新发起删除，原确认不再有效。'**
  String get shellDeleteOwnerChanged;

  /// No description provided for @shellDeletingChats.
  ///
  /// In zh, this message translates to:
  /// **'正在删除对话…'**
  String get shellDeletingChats;

  /// No description provided for @shellChatsDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已永久删除 {count} 个对话'**
  String shellChatsDeleted(int count);

  /// No description provided for @shellDeletePartial.
  ///
  /// In zh, this message translates to:
  /// **'已删除 {deleted} 个，失败 {failed} 个'**
  String shellDeletePartial(int deleted, int failed);

  /// No description provided for @shellDeleteRunning.
  ///
  /// In zh, this message translates to:
  /// **'请先停止运行中的工作；主机还会检查活动任务和定时任务。'**
  String get shellDeleteRunning;

  /// No description provided for @shellDeleteRelated.
  ///
  /// In zh, this message translates to:
  /// **'此对话仍有关联的定时任务，主机为保护它们拒绝删除。'**
  String get shellDeleteRelated;

  /// No description provided for @shellDeleteWriterHeld.
  ///
  /// In zh, this message translates to:
  /// **'其他进程正在使用此对话，请先在该进程中关闭后重试。'**
  String get shellDeleteWriterHeld;

  /// No description provided for @shellDeleteNotFound.
  ///
  /// In zh, this message translates to:
  /// **'此主机上已没有这个对话，请刷新列表。'**
  String get shellDeleteNotFound;

  /// No description provided for @shellDeleteConnectionLost.
  ///
  /// In zh, this message translates to:
  /// **'连接已断开，删除结果未确认，请刷新对话列表后再操作。'**
  String get shellDeleteConnectionLost;

  /// No description provided for @shellDeleteArchivePending.
  ///
  /// In zh, this message translates to:
  /// **'此对话正在等待归档，请先完成或撤销归档。'**
  String get shellDeleteArchivePending;

  /// No description provided for @shellDeleteInventoryChanged.
  ///
  /// In zh, this message translates to:
  /// **'对话列表已变化，请刷新后重新选择。'**
  String get shellDeleteInventoryChanged;

  /// No description provided for @shellDeleteProtocolError.
  ///
  /// In zh, this message translates to:
  /// **'删除结果未确认，请刷新对话列表后再操作。'**
  String get shellDeleteProtocolError;

  /// No description provided for @shellDeleteNotAttempted.
  ///
  /// In zh, this message translates to:
  /// **'未执行，请核对对话列表后重试。'**
  String get shellDeleteNotAttempted;

  /// No description provided for @shellDeleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'主机无法确认删除结果，请刷新后再决定是否重试。'**
  String get shellDeleteFailed;

  /// No description provided for @shellSearchChats.
  ///
  /// In zh, this message translates to:
  /// **'搜索对话'**
  String get shellSearchChats;

  /// No description provided for @shellCollapseChatList.
  ///
  /// In zh, this message translates to:
  /// **'收起对话列表'**
  String get shellCollapseChatList;

  /// No description provided for @shellExpandChatList.
  ///
  /// In zh, this message translates to:
  /// **'展开对话列表'**
  String get shellExpandChatList;

  /// No description provided for @shellChatList.
  ///
  /// In zh, this message translates to:
  /// **'对话列表'**
  String get shellChatList;

  /// No description provided for @shellChatDetails.
  ///
  /// In zh, this message translates to:
  /// **'对话详情'**
  String get shellChatDetails;

  /// No description provided for @shellCollapseDetails.
  ///
  /// In zh, this message translates to:
  /// **'收起详情'**
  String get shellCollapseDetails;

  /// No description provided for @shellExpand.
  ///
  /// In zh, this message translates to:
  /// **'展开'**
  String get shellExpand;

  /// No description provided for @shellUndo.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get shellUndo;

  /// No description provided for @shellFolderDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除「{name}」'**
  String shellFolderDeleted(String name);

  /// No description provided for @shellMovedToFolder.
  ///
  /// In zh, this message translates to:
  /// **'已移到「{name}」'**
  String shellMovedToFolder(String name);

  /// No description provided for @shellMovedOutOfFolder.
  ///
  /// In zh, this message translates to:
  /// **'已移出文件夹'**
  String get shellMovedOutOfFolder;

  /// No description provided for @shellUnpinFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能取消置顶，稍后再试'**
  String get shellUnpinFailed;

  /// No description provided for @shellPinFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能置顶，稍后再试'**
  String get shellPinFailed;

  /// No description provided for @shellChatsUnpinned.
  ///
  /// In zh, this message translates to:
  /// **'已取消置顶 {count} 个对话'**
  String shellChatsUnpinned(int count);

  /// No description provided for @shellChatsPinned.
  ///
  /// In zh, this message translates to:
  /// **'已置顶 {count} 个对话'**
  String shellChatsPinned(int count);

  /// No description provided for @shellArchiveFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能归档，稍后再试'**
  String get shellArchiveFailed;

  /// No description provided for @shellChatsStoppedArchived.
  ///
  /// In zh, this message translates to:
  /// **'已停止并归档 {count} 个对话'**
  String shellChatsStoppedArchived(int count);

  /// No description provided for @shellChatsArchived.
  ///
  /// In zh, this message translates to:
  /// **'已归档 {count} 个对话'**
  String shellChatsArchived(int count);

  /// No description provided for @shellFilterLabel.
  ///
  /// In zh, this message translates to:
  /// **'筛选：{label}'**
  String shellFilterLabel(String label);

  /// No description provided for @shellFolders.
  ///
  /// In zh, this message translates to:
  /// **'文件夹'**
  String get shellFolders;

  /// No description provided for @shellNoRunningChats.
  ///
  /// In zh, this message translates to:
  /// **'没有运行中的对话'**
  String get shellNoRunningChats;

  /// No description provided for @shellNoPendingChats.
  ///
  /// In zh, this message translates to:
  /// **'没有待确认的对话'**
  String get shellNoPendingChats;

  /// No description provided for @shellNoUnreadChats.
  ///
  /// In zh, this message translates to:
  /// **'没有未读对话'**
  String get shellNoUnreadChats;

  /// No description provided for @shellNoChatsYet.
  ///
  /// In zh, this message translates to:
  /// **'还没有对话'**
  String get shellNoChatsYet;

  /// No description provided for @shellFolderLabel.
  ///
  /// In zh, this message translates to:
  /// **'文件夹「{name}」'**
  String shellFolderLabel(String name);

  /// No description provided for @shellFolderChatCount.
  ///
  /// In zh, this message translates to:
  /// **'文件夹「{name}」，{count} 个对话'**
  String shellFolderChatCount(String name, int count);

  /// No description provided for @shellSort.
  ///
  /// In zh, this message translates to:
  /// **'排序'**
  String get shellSort;

  /// No description provided for @shellRecentActivity.
  ///
  /// In zh, this message translates to:
  /// **'最近活动'**
  String get shellRecentActivity;

  /// No description provided for @shellCreatedTime.
  ///
  /// In zh, this message translates to:
  /// **'创建时间'**
  String get shellCreatedTime;

  /// No description provided for @shellNewFolder.
  ///
  /// In zh, this message translates to:
  /// **'新建文件夹'**
  String get shellNewFolder;

  /// No description provided for @shellManageFolders.
  ///
  /// In zh, this message translates to:
  /// **'管理文件夹'**
  String get shellManageFolders;

  /// No description provided for @shellMultiSelect.
  ///
  /// In zh, this message translates to:
  /// **'多选'**
  String get shellMultiSelect;

  /// No description provided for @shellFolderNameExists.
  ///
  /// In zh, this message translates to:
  /// **'已有同名文件夹'**
  String get shellFolderNameExists;

  /// No description provided for @shellEditFolder.
  ///
  /// In zh, this message translates to:
  /// **'编辑文件夹'**
  String get shellEditFolder;

  /// No description provided for @shellFolderMark.
  ///
  /// In zh, this message translates to:
  /// **'标记'**
  String get shellFolderMark;

  /// No description provided for @shellFolderColor.
  ///
  /// In zh, this message translates to:
  /// **'颜色 {number}'**
  String shellFolderColor(int number);

  /// No description provided for @shellMoveToFolder.
  ///
  /// In zh, this message translates to:
  /// **'移到文件夹'**
  String get shellMoveToFolder;

  /// No description provided for @shellMoveOutOfFolder.
  ///
  /// In zh, this message translates to:
  /// **'移出文件夹'**
  String get shellMoveOutOfFolder;

  /// No description provided for @shellDeleteFolder.
  ///
  /// In zh, this message translates to:
  /// **'删除文件夹'**
  String get shellDeleteFolder;

  /// No description provided for @shellDragToReorder.
  ///
  /// In zh, this message translates to:
  /// **'拖动排序'**
  String get shellDragToReorder;

  /// No description provided for @shellSelectChats.
  ///
  /// In zh, this message translates to:
  /// **'选择对话'**
  String get shellSelectChats;

  /// No description provided for @shellSelectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 个'**
  String shellSelectedCount(int count);

  /// No description provided for @shellDeselectAll.
  ///
  /// In zh, this message translates to:
  /// **'取消全选'**
  String get shellDeselectAll;

  /// No description provided for @shellSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get shellSelectAll;

  /// No description provided for @shellUnpin.
  ///
  /// In zh, this message translates to:
  /// **'取消置顶'**
  String get shellUnpin;

  /// No description provided for @shellArchive.
  ///
  /// In zh, this message translates to:
  /// **'归档'**
  String get shellArchive;

  /// No description provided for @shellCurrentlyRunning.
  ///
  /// In zh, this message translates to:
  /// **'正在运行'**
  String get shellCurrentlyRunning;

  /// No description provided for @shellUnread.
  ///
  /// In zh, this message translates to:
  /// **'未读'**
  String get shellUnread;

  /// No description provided for @shellPinned.
  ///
  /// In zh, this message translates to:
  /// **'已置顶'**
  String get shellPinned;

  /// No description provided for @shellEngineNotRunning.
  ///
  /// In zh, this message translates to:
  /// **'引擎未运行'**
  String get shellEngineNotRunning;

  /// No description provided for @shellHostNotConnected.
  ///
  /// In zh, this message translates to:
  /// **'还没连上「{name}」'**
  String shellHostNotConnected(String name);

  /// No description provided for @shellSearchAfterConnecting.
  ///
  /// In zh, this message translates to:
  /// **'连接后才能搜索'**
  String get shellSearchAfterConnecting;

  /// No description provided for @shellChatsLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'对话列表加载失败'**
  String get shellChatsLoadFailed;

  /// No description provided for @shellSearchHostChats.
  ///
  /// In zh, this message translates to:
  /// **'搜索「{name}」上的对话'**
  String shellSearchHostChats(String name);

  /// No description provided for @shellSearchTitlesHint.
  ///
  /// In zh, this message translates to:
  /// **'按标题查找，含已归档的对话'**
  String get shellSearchTitlesHint;

  /// No description provided for @shellSearchContentHint.
  ///
  /// In zh, this message translates to:
  /// **'按标题和内容查找，含已归档的对话'**
  String get shellSearchContentHint;

  /// No description provided for @shellLoadingChatsEllipsis.
  ///
  /// In zh, this message translates to:
  /// **'正在加载对话…'**
  String get shellLoadingChatsEllipsis;

  /// No description provided for @shellNoMatchingChats.
  ///
  /// In zh, this message translates to:
  /// **'没有相关对话'**
  String get shellNoMatchingChats;

  /// No description provided for @shellSearchDifferentKeywords.
  ///
  /// In zh, this message translates to:
  /// **'换个关键词，或用空格分开多个词'**
  String get shellSearchDifferentKeywords;

  /// No description provided for @shellArchived.
  ///
  /// In zh, this message translates to:
  /// **'已归档'**
  String get shellArchived;

  /// No description provided for @shellRestoreBeforeOpening.
  ///
  /// In zh, this message translates to:
  /// **'已归档的对话需先恢复，才能打开'**
  String get shellRestoreBeforeOpening;

  /// No description provided for @shellRestoreAndOpen.
  ///
  /// In zh, this message translates to:
  /// **'恢复并打开'**
  String get shellRestoreAndOpen;

  /// No description provided for @shellRestoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能恢复，稍后再试'**
  String get shellRestoreFailed;

  /// No description provided for @shellSearchingMessages.
  ///
  /// In zh, this message translates to:
  /// **'正在搜索消息内容…'**
  String get shellSearchingMessages;

  /// No description provided for @shellHostTitleSearchOnly.
  ///
  /// In zh, this message translates to:
  /// **'这台主机仅支持按标题搜索'**
  String get shellHostTitleSearchOnly;

  /// No description provided for @shellContentSearchFailed.
  ///
  /// In zh, this message translates to:
  /// **'内容搜索失败，仅显示标题匹配'**
  String get shellContentSearchFailed;

  /// No description provided for @shellContentSearchLimit.
  ///
  /// In zh, this message translates to:
  /// **'内容匹配仅列出最相关的 20 个对话'**
  String get shellContentSearchLimit;

  /// No description provided for @shellMoveToOtherFolder.
  ///
  /// In zh, this message translates to:
  /// **'移到其他文件夹'**
  String get shellMoveToOtherFolder;

  /// No description provided for @shellArchiveStopsTurn.
  ///
  /// In zh, this message translates to:
  /// **'进行中的一轮会停止'**
  String get shellArchiveStopsTurn;

  /// No description provided for @shellRenameFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能重命名，稍后再试'**
  String get shellRenameFailed;

  /// No description provided for @shellChatStoppedArchived.
  ///
  /// In zh, this message translates to:
  /// **'已停止并归档「{title}」'**
  String shellChatStoppedArchived(String title);

  /// No description provided for @shellChatArchived.
  ///
  /// In zh, this message translates to:
  /// **'已归档「{title}」'**
  String shellChatArchived(String title);

  /// No description provided for @shellRenameChat.
  ///
  /// In zh, this message translates to:
  /// **'重命名对话'**
  String get shellRenameChat;

  /// No description provided for @shellChatTitle.
  ///
  /// In zh, this message translates to:
  /// **'对话标题'**
  String get shellChatTitle;

  /// No description provided for @shellLoadingChats.
  ///
  /// In zh, this message translates to:
  /// **'正在加载对话'**
  String get shellLoadingChats;

  /// No description provided for @shellWorkspaceNoChats.
  ///
  /// In zh, this message translates to:
  /// **'这里还没有对话'**
  String get shellWorkspaceNoChats;

  /// No description provided for @shellWorkspaceNewChatsHint.
  ///
  /// In zh, this message translates to:
  /// **'新对话会放进这个工作区。旧对话不会自动移入，可在「全部对话」中找到。'**
  String get shellWorkspaceNewChatsHint;

  /// No description provided for @shellNewChatsHint.
  ///
  /// In zh, this message translates to:
  /// **'新对话会出现在这里'**
  String get shellNewChatsHint;

  /// No description provided for @shellHostUnreachable.
  ///
  /// In zh, this message translates to:
  /// **'连不上「{name}」'**
  String shellHostUnreachable(String name);

  /// No description provided for @shellHostReconnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在重新连接「{name}」…'**
  String shellHostReconnecting(String name);

  /// No description provided for @shellRetryNow.
  ///
  /// In zh, this message translates to:
  /// **'立即重试'**
  String get shellRetryNow;

  /// No description provided for @shellHostConnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接「{name}」…'**
  String shellHostConnecting(String name);

  /// No description provided for @shellHostChatsAfterConnecting.
  ///
  /// In zh, this message translates to:
  /// **'连接后显示这台主机上的对话'**
  String get shellHostChatsAfterConnecting;

  /// No description provided for @shellCurrentHostLabel.
  ///
  /// In zh, this message translates to:
  /// **'当前主机：{name}，{view}。切换主机'**
  String shellCurrentHostLabel(String name, String view);

  /// No description provided for @shellSemanticsSeparator.
  ///
  /// In zh, this message translates to:
  /// **'，'**
  String get shellSemanticsSeparator;

  /// No description provided for @shellChatsArchivedPartial.
  ///
  /// In zh, this message translates to:
  /// **'已归档 {count} 个对话，{failed} 个没能归档'**
  String shellChatsArchivedPartial(int count, int failed);

  /// No description provided for @shellPanelOverview.
  ///
  /// In zh, this message translates to:
  /// **'信息'**
  String get shellPanelOverview;

  /// No description provided for @shellPanelWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'工作区'**
  String get shellPanelWorkspace;

  /// No description provided for @shellPanelModel.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get shellPanelModel;

  /// No description provided for @shellPanelHost.
  ///
  /// In zh, this message translates to:
  /// **'主机'**
  String get shellPanelHost;

  /// No description provided for @shellPanelOpenFull.
  ///
  /// In zh, this message translates to:
  /// **'打开完整页面'**
  String get shellPanelOpenFull;

  /// No description provided for @shellQuickPanel.
  ///
  /// In zh, this message translates to:
  /// **'快捷入口'**
  String get shellQuickPanel;

  /// No description provided for @shellQuickPanelHint.
  ///
  /// In zh, this message translates to:
  /// **'在「{path}」里调整'**
  String shellQuickPanelHint(String path);

  /// No description provided for @stateStoragePermission.
  ///
  /// In zh, this message translates to:
  /// **'没有存储权限，存不进「下载」'**
  String get stateStoragePermission;

  /// No description provided for @stateBrowserOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能打开浏览器'**
  String get stateBrowserOpenFailed;

  /// No description provided for @stateFileOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开这个文件'**
  String get stateFileOpenFailed;

  /// No description provided for @stateLinkOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开这个链接'**
  String get stateLinkOpenFailed;

  /// No description provided for @stateRunCommand.
  ///
  /// In zh, this message translates to:
  /// **'运行命令'**
  String get stateRunCommand;

  /// No description provided for @stateWriteFile.
  ///
  /// In zh, this message translates to:
  /// **'写入文件'**
  String get stateWriteFile;

  /// No description provided for @stateEditFile.
  ///
  /// In zh, this message translates to:
  /// **'修改文件'**
  String get stateEditFile;

  /// No description provided for @stateOpenPage.
  ///
  /// In zh, this message translates to:
  /// **'打开网页'**
  String get stateOpenPage;

  /// No description provided for @stateWebSearch.
  ///
  /// In zh, this message translates to:
  /// **'联网搜索'**
  String get stateWebSearch;

  /// No description provided for @stateAlertQuestion.
  ///
  /// In zh, this message translates to:
  /// **'问你一个问题'**
  String get stateAlertQuestion;

  /// No description provided for @stateSizeSmall.
  ///
  /// In zh, this message translates to:
  /// **'小'**
  String get stateSizeSmall;

  /// No description provided for @stateSizeStandard.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get stateSizeStandard;

  /// No description provided for @stateSizeLarge.
  ///
  /// In zh, this message translates to:
  /// **'大'**
  String get stateSizeLarge;

  /// No description provided for @stateAgentError.
  ///
  /// In zh, this message translates to:
  /// **'出错'**
  String get stateAgentError;

  /// No description provided for @stateNotRunning.
  ///
  /// In zh, this message translates to:
  /// **'未运行'**
  String get stateNotRunning;

  /// No description provided for @stateAgentOneShot.
  ///
  /// In zh, this message translates to:
  /// **'一次性'**
  String get stateAgentOneShot;

  /// No description provided for @stateAgentContinuable.
  ///
  /// In zh, this message translates to:
  /// **'可继续'**
  String get stateAgentContinuable;

  /// No description provided for @stateAgentExternal.
  ///
  /// In zh, this message translates to:
  /// **'外部任务'**
  String get stateAgentExternal;

  /// No description provided for @stateSubagent.
  ///
  /// In zh, this message translates to:
  /// **'子代理'**
  String get stateSubagent;

  /// No description provided for @stateParentChat.
  ///
  /// In zh, this message translates to:
  /// **'上级对话'**
  String get stateParentChat;

  /// No description provided for @statePreparing.
  ///
  /// In zh, this message translates to:
  /// **'准备中'**
  String get statePreparing;

  /// No description provided for @stateAppDisclaimer.
  ///
  /// In zh, this message translates to:
  /// **'基于 DeepSeek Harness 构建 · 非 DeepSeek 官方应用'**
  String get stateAppDisclaimer;

  /// No description provided for @stateWallpaper.
  ///
  /// In zh, this message translates to:
  /// **'壁纸'**
  String get stateWallpaper;

  /// No description provided for @stateFileMissing.
  ///
  /// In zh, this message translates to:
  /// **'找不到这个文件了，可能已被删除或移走'**
  String get stateFileMissing;

  /// No description provided for @stateFileNoApp.
  ///
  /// In zh, this message translates to:
  /// **'手机上没有能打开这类文件的应用'**
  String get stateFileNoApp;

  /// No description provided for @stateFileConnectionLimit.
  ///
  /// In zh, this message translates to:
  /// **'文件太大，这个连接传不过来'**
  String get stateFileConnectionLimit;

  /// No description provided for @stateFileReadUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'这个连接不支持读取文件'**
  String get stateFileReadUnsupported;

  /// No description provided for @stateArtifactImage.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get stateArtifactImage;

  /// No description provided for @stateArtifactDocument.
  ///
  /// In zh, this message translates to:
  /// **'文档'**
  String get stateArtifactDocument;

  /// No description provided for @stateArtifactSheet.
  ///
  /// In zh, this message translates to:
  /// **'表格'**
  String get stateArtifactSheet;

  /// No description provided for @stateArtifactSlides.
  ///
  /// In zh, this message translates to:
  /// **'演示文稿'**
  String get stateArtifactSlides;

  /// No description provided for @stateArtifactArchive.
  ///
  /// In zh, this message translates to:
  /// **'压缩包'**
  String get stateArtifactArchive;

  /// No description provided for @stateArtifactAudio.
  ///
  /// In zh, this message translates to:
  /// **'音频'**
  String get stateArtifactAudio;

  /// No description provided for @stateArtifactVideo.
  ///
  /// In zh, this message translates to:
  /// **'视频'**
  String get stateArtifactVideo;

  /// No description provided for @stateArtifactWeb.
  ///
  /// In zh, this message translates to:
  /// **'网页'**
  String get stateArtifactWeb;

  /// No description provided for @stateArtifactText.
  ///
  /// In zh, this message translates to:
  /// **'文本'**
  String get stateArtifactText;

  /// No description provided for @stateArtifactFile.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get stateArtifactFile;

  /// No description provided for @statePrivateKeyTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'文件太大，不像是私钥'**
  String get statePrivateKeyTooLarge;

  /// No description provided for @stateChatAgentBusy.
  ///
  /// In zh, this message translates to:
  /// **'AI 正忙，稍后再试'**
  String get stateChatAgentBusy;

  /// No description provided for @stateChatWriterHeld.
  ///
  /// In zh, this message translates to:
  /// **'这个对话正在别处使用'**
  String get stateChatWriterHeld;

  /// No description provided for @stateChatModelUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'这个模型现在用不了'**
  String get stateChatModelUnavailable;

  /// No description provided for @stateChatAttachmentInvalid.
  ///
  /// In zh, this message translates to:
  /// **'这个附件发不了'**
  String get stateChatAttachmentInvalid;

  /// No description provided for @stateChatForkUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'这里不能分叉'**
  String get stateChatForkUnavailable;

  /// No description provided for @stateChatImagesTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'图片太大，少选几张再发'**
  String get stateChatImagesTooLarge;

  /// No description provided for @stateChatSyncInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'对话同步中断'**
  String get stateChatSyncInterrupted;

  /// No description provided for @stateChatSynchronizing.
  ///
  /// In zh, this message translates to:
  /// **'正在同步对话'**
  String get stateChatSynchronizing;

  /// No description provided for @stateChatSyncRetry.
  ///
  /// In zh, this message translates to:
  /// **'重新同步'**
  String get stateChatSyncRetry;

  /// No description provided for @stateChatSyncRequired.
  ///
  /// In zh, this message translates to:
  /// **'对话尚未同步，请重新同步后再试'**
  String get stateChatSyncRequired;

  /// No description provided for @stateChatAutoApproveFailed.
  ///
  /// In zh, this message translates to:
  /// **'自动允许失败'**
  String get stateChatAutoApproveFailed;

  /// No description provided for @stateCommandMissing.
  ///
  /// In zh, this message translates to:
  /// **'没有这个指令'**
  String get stateCommandMissing;

  /// No description provided for @stateCommandFailed.
  ///
  /// In zh, this message translates to:
  /// **'指令没有执行'**
  String get stateCommandFailed;

  /// No description provided for @stateChatStopSteered.
  ///
  /// In zh, this message translates to:
  /// **'没能停下本轮，已作为插话发送'**
  String get stateChatStopSteered;

  /// No description provided for @stateChatTextOnlyModel.
  ///
  /// In zh, this message translates to:
  /// **'当前模型未声明支持图片，已按文件发送。可换模型，或把自定义模型的输入类型设为「文本和图片」'**
  String get stateChatTextOnlyModel;

  /// No description provided for @stateAttachmentUploadFailed.
  ///
  /// In zh, this message translates to:
  /// **'附件上传失败'**
  String get stateAttachmentUploadFailed;

  /// No description provided for @stateChatImageModelRequired.
  ///
  /// In zh, this message translates to:
  /// **'当前模型未声明支持图片。请换模型，或把自定义模型的输入类型设为「文本和图片」再发'**
  String get stateChatImageModelRequired;

  /// No description provided for @stateSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'发送失败'**
  String get stateSendFailed;

  /// No description provided for @stateChatStopFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能停下，再试一次'**
  String get stateChatStopFailed;

  /// No description provided for @stateChatTurnEnded.
  ///
  /// In zh, this message translates to:
  /// **'这一轮已经结束，消息会作为新一轮发送'**
  String get stateChatTurnEnded;

  /// No description provided for @stateChatSteerFailed.
  ///
  /// In zh, this message translates to:
  /// **'插话失败'**
  String get stateChatSteerFailed;

  /// No description provided for @stateChatUndoTooLate.
  ///
  /// In zh, this message translates to:
  /// **'来不及了，AI 已经读到这条消息'**
  String get stateChatUndoTooLate;

  /// No description provided for @stateChatUndoFailed.
  ///
  /// In zh, this message translates to:
  /// **'撤回失败'**
  String get stateChatUndoFailed;

  /// No description provided for @stateChatApprovalFailed.
  ///
  /// In zh, this message translates to:
  /// **'审批提交失败'**
  String get stateChatApprovalFailed;

  /// No description provided for @stateChatAnswerFailed.
  ///
  /// In zh, this message translates to:
  /// **'回答提交失败'**
  String get stateChatAnswerFailed;

  /// No description provided for @stateChatModelSwitchFailed.
  ///
  /// In zh, this message translates to:
  /// **'切换模型失败'**
  String get stateChatModelSwitchFailed;

  /// No description provided for @stateChatHistoryFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载历史失败'**
  String get stateChatHistoryFailed;

  /// No description provided for @stateChatBranchLastReply.
  ///
  /// In zh, this message translates to:
  /// **'只能从已完成的一轮的最后一条回复分叉'**
  String get stateChatBranchLastReply;

  /// No description provided for @stateChatBranchFailed.
  ///
  /// In zh, this message translates to:
  /// **'分叉失败'**
  String get stateChatBranchFailed;

  /// No description provided for @stateChatEarlierHistoryFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取更早的记录失败'**
  String get stateChatEarlierHistoryFailed;

  /// No description provided for @stateChatNoEarlierHistory.
  ///
  /// In zh, this message translates to:
  /// **'这条消息之前没有能保留的记录，直接新建对话就好'**
  String get stateChatNoEarlierHistory;

  /// No description provided for @stateCommandNewDescription.
  ///
  /// In zh, this message translates to:
  /// **'开始一个新对话'**
  String get stateCommandNewDescription;

  /// No description provided for @stateModelLabel.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get stateModelLabel;

  /// No description provided for @stateCommandModelDescription.
  ///
  /// In zh, this message translates to:
  /// **'切换模型与思考深度'**
  String get stateCommandModelDescription;

  /// No description provided for @stateCommandExportLabel.
  ///
  /// In zh, this message translates to:
  /// **'导出日志'**
  String get stateCommandExportLabel;

  /// No description provided for @stateCommandExportDescription.
  ///
  /// In zh, this message translates to:
  /// **'把这个对话的完整记录打包成 ZIP，分享或存到「下载」'**
  String get stateCommandExportDescription;

  /// No description provided for @stateCompactLabel.
  ///
  /// In zh, this message translates to:
  /// **'压缩'**
  String get stateCompactLabel;

  /// No description provided for @stateCommandCompactDescription.
  ///
  /// In zh, this message translates to:
  /// **'压缩以上对话内容，腾出上下文'**
  String get stateCommandCompactDescription;

  /// No description provided for @statePermissionLabel.
  ///
  /// In zh, this message translates to:
  /// **'权限'**
  String get statePermissionLabel;

  /// No description provided for @stateCommandPermissionDescription.
  ///
  /// In zh, this message translates to:
  /// **'切换权限预设（沙箱模式与审批策略）'**
  String get stateCommandPermissionDescription;

  /// No description provided for @stateCommandPermissionHint.
  ///
  /// In zh, this message translates to:
  /// **'<预设名>'**
  String get stateCommandPermissionHint;

  /// No description provided for @statePlanLabel.
  ///
  /// In zh, this message translates to:
  /// **'计划'**
  String get statePlanLabel;

  /// No description provided for @stateCommandPlanDescription.
  ///
  /// In zh, this message translates to:
  /// **'进入或退出计划模式'**
  String get stateCommandPlanDescription;

  /// No description provided for @stateGoalLabel.
  ///
  /// In zh, this message translates to:
  /// **'目标'**
  String get stateGoalLabel;

  /// No description provided for @stateCommandGoalDescription.
  ///
  /// In zh, this message translates to:
  /// **'设置或查看长期任务目标'**
  String get stateCommandGoalDescription;

  /// No description provided for @stateFeedbackLabel.
  ///
  /// In zh, this message translates to:
  /// **'反馈'**
  String get stateFeedbackLabel;

  /// No description provided for @stateCommandFeedbackDescription.
  ///
  /// In zh, this message translates to:
  /// **'发送关于当前对话的反馈'**
  String get stateCommandFeedbackDescription;

  /// No description provided for @stateCommandFeedbackHint.
  ///
  /// In zh, this message translates to:
  /// **'<内容>'**
  String get stateCommandFeedbackHint;

  /// No description provided for @stateShareFileTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'有文件太大，未添加'**
  String get stateShareFileTooLarge;

  /// No description provided for @stateShareFileUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'有文件没能读取'**
  String get stateShareFileUnreadable;

  /// No description provided for @stateShareImagesOnly.
  ///
  /// In zh, this message translates to:
  /// **'当前主机只能发送图片'**
  String get stateShareImagesOnly;

  /// No description provided for @stateComposerInserted.
  ///
  /// In zh, this message translates to:
  /// **'已放进输入框'**
  String get stateComposerInserted;

  /// No description provided for @stateCordisPending.
  ///
  /// In zh, this message translates to:
  /// **'待确认'**
  String get stateCordisPending;

  /// No description provided for @stateDrawerAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get stateDrawerAll;

  /// No description provided for @stateDrawerUnread.
  ///
  /// In zh, this message translates to:
  /// **'未读'**
  String get stateDrawerUnread;

  /// No description provided for @stateDrawerToday.
  ///
  /// In zh, this message translates to:
  /// **'今天'**
  String get stateDrawerToday;

  /// No description provided for @stateDrawerThisWeek.
  ///
  /// In zh, this message translates to:
  /// **'本周'**
  String get stateDrawerThisWeek;

  /// No description provided for @stateDrawerEarlier.
  ///
  /// In zh, this message translates to:
  /// **'更早'**
  String get stateDrawerEarlier;

  /// No description provided for @stateEngineAuthFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能通过引擎的验证'**
  String get stateEngineAuthFailed;

  /// No description provided for @stateChatMissing.
  ///
  /// In zh, this message translates to:
  /// **'这个对话已经不在了'**
  String get stateChatMissing;

  /// No description provided for @stateChatFormatUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前引擎无法读取此对话的日志格式，请导出诊断包排查'**
  String get stateChatFormatUnsupported;

  /// No description provided for @stateEngineUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前引擎版本不支持'**
  String get stateEngineUnsupported;

  /// No description provided for @stateEngineServiceUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'所需的引擎服务未就绪，请查看引擎日志或导出诊断包'**
  String get stateEngineServiceUnavailable;

  /// No description provided for @stateEngineOperationUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'引擎当前无法执行此操作，请查看引擎日志'**
  String get stateEngineOperationUnavailable;

  /// No description provided for @stateSettingsRefreshed.
  ///
  /// In zh, this message translates to:
  /// **'刚在别处改过，已刷新'**
  String get stateSettingsRefreshed;

  /// No description provided for @stateCredentialFromEnvironment.
  ///
  /// In zh, this message translates to:
  /// **'引擎的启动环境已提供这个 Key，无法在这里修改'**
  String get stateCredentialFromEnvironment;

  /// No description provided for @stateSettingsFromFile.
  ///
  /// In zh, this message translates to:
  /// **'由配置文件固定'**
  String get stateSettingsFromFile;

  /// No description provided for @stateSettingsInteger.
  ///
  /// In zh, this message translates to:
  /// **'请填整数'**
  String get stateSettingsInteger;

  /// No description provided for @stateSettingsInvalidFormat.
  ///
  /// In zh, this message translates to:
  /// **'格式不对'**
  String get stateSettingsInvalidFormat;

  /// No description provided for @stateSettingsReadOnly.
  ///
  /// In zh, this message translates to:
  /// **'引擎设置是只读的'**
  String get stateSettingsReadOnly;

  /// No description provided for @statePluginDisabled.
  ///
  /// In zh, this message translates to:
  /// **'插件已停用'**
  String get statePluginDisabled;

  /// No description provided for @stateSettingsRestartRequired.
  ///
  /// In zh, this message translates to:
  /// **'这一项要重启引擎才能改'**
  String get stateSettingsRestartRequired;

  /// No description provided for @stateSettingsInvalidValue.
  ///
  /// In zh, this message translates to:
  /// **'值不合法'**
  String get stateSettingsInvalidValue;

  /// No description provided for @stateSettingsRejected.
  ///
  /// In zh, this message translates to:
  /// **'引擎没有接受这个值'**
  String get stateSettingsRejected;

  /// No description provided for @stateLoading.
  ///
  /// In zh, this message translates to:
  /// **'加载中'**
  String get stateLoading;

  /// No description provided for @stateGoalEmpty.
  ///
  /// In zh, this message translates to:
  /// **'目标不能为空'**
  String get stateGoalEmpty;

  /// No description provided for @stateGoalPauseFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能暂停'**
  String get stateGoalPauseFailed;

  /// No description provided for @stateGoalResumeFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能恢复'**
  String get stateGoalResumeFailed;

  /// No description provided for @stateGoalClearOffline.
  ///
  /// In zh, this message translates to:
  /// **'没能清除：没能连上引擎'**
  String get stateGoalClearOffline;

  /// No description provided for @stateGoalClearFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能清除'**
  String get stateGoalClearFailed;

  /// No description provided for @stateGoalStale.
  ///
  /// In zh, this message translates to:
  /// **'目标刚有变化，再试一次'**
  String get stateGoalStale;

  /// No description provided for @stateGoalMissing.
  ///
  /// In zh, this message translates to:
  /// **'目标已不在'**
  String get stateGoalMissing;

  /// No description provided for @stateGoalChatNotReady.
  ///
  /// In zh, this message translates to:
  /// **'对话未就绪，稍后再试'**
  String get stateGoalChatNotReady;

  /// No description provided for @stateGoalTurnsExhausted.
  ///
  /// In zh, this message translates to:
  /// **'轮次已用完'**
  String get stateGoalTurnsExhausted;

  /// No description provided for @stateGoalStateChanged.
  ///
  /// In zh, this message translates to:
  /// **'目标状态已变化'**
  String get stateGoalStateChanged;

  /// No description provided for @stateProviderOpenAi.
  ///
  /// In zh, this message translates to:
  /// **'OpenAI 兼容'**
  String get stateProviderOpenAi;

  /// No description provided for @stateProviderAnthropic.
  ///
  /// In zh, this message translates to:
  /// **'Anthropic 兼容'**
  String get stateProviderAnthropic;

  /// No description provided for @stateProviderUrlRequired.
  ///
  /// In zh, this message translates to:
  /// **'填写 Base URL'**
  String get stateProviderUrlRequired;

  /// No description provided for @stateProviderUrlInvalid.
  ///
  /// In zh, this message translates to:
  /// **'以 http:// 或 https:// 开头的完整地址'**
  String get stateProviderUrlInvalid;

  /// No description provided for @stateProviderUrlSuffix.
  ///
  /// In zh, this message translates to:
  /// **'去掉 ? 或 # 之后的部分'**
  String get stateProviderUrlSuffix;

  /// No description provided for @stateProviderKeyRequired.
  ///
  /// In zh, this message translates to:
  /// **'填写 API Key'**
  String get stateProviderKeyRequired;

  /// No description provided for @stateProviderKeyOnly.
  ///
  /// In zh, this message translates to:
  /// **'只粘贴 Key 本身，不带变量名'**
  String get stateProviderKeyOnly;

  /// No description provided for @stateProviderKeyQuotes.
  ///
  /// In zh, this message translates to:
  /// **'去掉两边的引号'**
  String get stateProviderKeyQuotes;

  /// No description provided for @stateProviderKeyInvalid.
  ///
  /// In zh, this message translates to:
  /// **'Key 含有无效字符'**
  String get stateProviderKeyInvalid;

  /// No description provided for @stateProviderModelRequired.
  ///
  /// In zh, this message translates to:
  /// **'填写模型 ID'**
  String get stateProviderModelRequired;

  /// No description provided for @stateProviderModelSpaces.
  ///
  /// In zh, this message translates to:
  /// **'模型 ID 不能有空格'**
  String get stateProviderModelSpaces;

  /// No description provided for @stateProviderAlreadyAdded.
  ///
  /// In zh, this message translates to:
  /// **'已经添加过'**
  String get stateProviderAlreadyAdded;

  /// No description provided for @stateProviderConflict.
  ///
  /// In zh, this message translates to:
  /// **'渠道刚被改过，返回后重试'**
  String get stateProviderConflict;

  /// No description provided for @stateProviderUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前引擎版本不支持这个操作'**
  String get stateProviderUnsupported;

  /// No description provided for @stateProviderKeyRejected.
  ///
  /// In zh, this message translates to:
  /// **'API Key 无效或没有权限'**
  String get stateProviderKeyRejected;

  /// No description provided for @stateProviderModelsMissing.
  ///
  /// In zh, this message translates to:
  /// **'找不到模型列表，检查 Base URL'**
  String get stateProviderModelsMissing;

  /// No description provided for @stateProviderRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'请求太频繁，稍后再试'**
  String get stateProviderRateLimited;

  /// No description provided for @stateProviderResponseTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'返回的内容过大'**
  String get stateProviderResponseTooLarge;

  /// No description provided for @stateProviderUnreachable.
  ///
  /// In zh, this message translates to:
  /// **'连不上这个地址，检查 Base URL 和网络'**
  String get stateProviderUnreachable;

  /// No description provided for @stateProviderModelsUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'没有读到模型列表，检查 Base URL'**
  String get stateProviderModelsUnreadable;

  /// No description provided for @stateProviderManualModels.
  ///
  /// In zh, this message translates to:
  /// **'这个协议不能获取模型，请手动添加'**
  String get stateProviderManualModels;

  /// No description provided for @stateProviderConfigRejected.
  ///
  /// In zh, this message translates to:
  /// **'引擎拒绝了这个配置，检查协议和模型'**
  String get stateProviderConfigRejected;

  /// No description provided for @stateProviderOffline.
  ///
  /// In zh, this message translates to:
  /// **'没有连上引擎'**
  String get stateProviderOffline;

  /// No description provided for @stateScheduleNotCreated.
  ///
  /// In zh, this message translates to:
  /// **'对话结束了，但没有建成任务'**
  String get stateScheduleNotCreated;

  /// No description provided for @stateScheduleChatFailed.
  ///
  /// In zh, this message translates to:
  /// **'对话出错了'**
  String get stateScheduleChatFailed;

  /// No description provided for @stateScheduleResultPending.
  ///
  /// In zh, this message translates to:
  /// **'还没等到结果'**
  String get stateScheduleResultPending;

  /// No description provided for @statePlanPending.
  ///
  /// In zh, this message translates to:
  /// **'计划待审'**
  String get statePlanPending;

  /// No description provided for @stateQuestionPending.
  ///
  /// In zh, this message translates to:
  /// **'待回答'**
  String get stateQuestionPending;

  /// No description provided for @stateExportRelayUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'经中转连接暂不支持导出'**
  String get stateExportRelayUnsupported;

  /// No description provided for @stateExportChatMissing.
  ///
  /// In zh, this message translates to:
  /// **'找不到这个对话了'**
  String get stateExportChatMissing;

  /// No description provided for @stateExportFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能导出'**
  String get stateExportFailed;

  /// No description provided for @stateSizeExtraLarge.
  ///
  /// In zh, this message translates to:
  /// **'特大'**
  String get stateSizeExtraLarge;

  /// No description provided for @stateTerminalLimit.
  ///
  /// In zh, this message translates to:
  /// **'终端数量已达上限'**
  String get stateTerminalLimit;

  /// No description provided for @stateTerminalStartFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能启动终端'**
  String get stateTerminalStartFailed;

  /// No description provided for @stateTerminalDisabledOnHost.
  ///
  /// In zh, this message translates to:
  /// **'这台电脑关掉了远程终端。在电脑上打开 Remote 设置里的「终端」，再回来重试'**
  String get stateTerminalDisabledOnHost;

  /// No description provided for @stateTileDuotone.
  ///
  /// In zh, this message translates to:
  /// **'扁平双色'**
  String get stateTileDuotone;

  /// No description provided for @stateTileGeometric.
  ///
  /// In zh, this message translates to:
  /// **'极简几何'**
  String get stateTileGeometric;

  /// No description provided for @stateTileGlassy.
  ///
  /// In zh, this message translates to:
  /// **'玻璃渐变'**
  String get stateTileGlassy;

  /// No description provided for @stateDefaultWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'默认工作区'**
  String get stateDefaultWorkspace;

  /// No description provided for @stateAlertUseTool.
  ///
  /// In zh, this message translates to:
  /// **'使用工具 {name}'**
  String stateAlertUseTool(String name);

  /// No description provided for @stateAlertApprovalAction.
  ///
  /// In zh, this message translates to:
  /// **'等你确认：{action}'**
  String stateAlertApprovalAction(String action);

  /// No description provided for @stateAlertApprovalReason.
  ///
  /// In zh, this message translates to:
  /// **'等你确认：{action} · {reason}'**
  String stateAlertApprovalReason(String action, String reason);

  /// No description provided for @stateAlertQuestions.
  ///
  /// In zh, this message translates to:
  /// **'问你：{question}（共 {count} 个）'**
  String stateAlertQuestions(String question, int count);

  /// No description provided for @stateAlertQuestionText.
  ///
  /// In zh, this message translates to:
  /// **'问你：{question}'**
  String stateAlertQuestionText(String question);

  /// No description provided for @stateAttachmentEmpty.
  ///
  /// In zh, this message translates to:
  /// **'「{name}」是空文件'**
  String stateAttachmentEmpty(String name);

  /// No description provided for @stateAttachmentImageLimit.
  ///
  /// In zh, this message translates to:
  /// **'图片「{name}」超过 20 MB'**
  String stateAttachmentImageLimit(String name);

  /// No description provided for @stateAttachmentFileLimit.
  ///
  /// In zh, this message translates to:
  /// **'文件「{name}」超过 200 MB'**
  String stateAttachmentFileLimit(String name);

  /// No description provided for @stateAttachmentTotalLimit.
  ///
  /// In zh, this message translates to:
  /// **'附件总大小超过 400 MB'**
  String get stateAttachmentTotalLimit;

  /// No description provided for @stateCommandPlanHint.
  ///
  /// In zh, this message translates to:
  /// **'[off | 要求]'**
  String get stateCommandPlanHint;

  /// No description provided for @stateCommandGoalHint.
  ///
  /// In zh, this message translates to:
  /// **'[目标 | clear | pause | resume]'**
  String get stateCommandGoalHint;

  /// No description provided for @stateShareReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能读取「{name}」'**
  String stateShareReadFailed(String name);

  /// No description provided for @stateShareAttachmentLimit.
  ///
  /// In zh, this message translates to:
  /// **'每条消息最多 {count} 个附件'**
  String stateShareAttachmentLimit(int count);

  /// No description provided for @stateShareNamedFileTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'「{name}」太大，未添加'**
  String stateShareNamedFileTooLarge(String name);

  /// No description provided for @stateShareTextTruncated.
  ///
  /// In zh, this message translates to:
  /// **'文字太长，只保留了前 {count} 字'**
  String stateShareTextTruncated(int count);

  /// No description provided for @stateSettingsMinimum.
  ///
  /// In zh, this message translates to:
  /// **'不能小于 {bound}'**
  String stateSettingsMinimum(String bound);

  /// No description provided for @stateSettingsMaximum.
  ///
  /// In zh, this message translates to:
  /// **'不能大于 {bound}'**
  String stateSettingsMaximum(String bound);

  /// No description provided for @stateSettingsMultiple.
  ///
  /// In zh, this message translates to:
  /// **'需是 {bound} 的倍数'**
  String stateSettingsMultiple(String bound);

  /// No description provided for @stateSettingsMinLength.
  ///
  /// In zh, this message translates to:
  /// **'至少 {count} 个字符'**
  String stateSettingsMinLength(int count);

  /// No description provided for @stateSettingsMaxLength.
  ///
  /// In zh, this message translates to:
  /// **'最多 {count} 个字符'**
  String stateSettingsMaxLength(int count);

  /// No description provided for @stateEngineHttpRejected.
  ///
  /// In zh, this message translates to:
  /// **'引擎拒绝了请求（{status}）'**
  String stateEngineHttpRejected(int status);

  /// No description provided for @stateGoalActionOffline.
  ///
  /// In zh, this message translates to:
  /// **'{action}：没能连上引擎'**
  String stateGoalActionOffline(String action);

  /// No description provided for @stateProviderServiceUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'服务暂时不可用（{status}）'**
  String stateProviderServiceUnavailable(int status);

  /// No description provided for @stateProviderServiceStatus.
  ///
  /// In zh, this message translates to:
  /// **'服务返回了 {status}'**
  String stateProviderServiceStatus(int status);

  /// No description provided for @stateProviderKeySaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'渠道已保存，Key 没有存上：{reason}'**
  String stateProviderKeySaveFailed(String reason);

  /// No description provided for @stateScheduleCreatePrompt.
  ///
  /// In zh, this message translates to:
  /// **'新建自动化任务「{title}」：{rule}。\n只调用一次 schedule_create，参数原样使用；现在不要执行任务内容。\n\n```json\n{args}\n```'**
  String stateScheduleCreatePrompt(String title, String rule, String args);

  /// No description provided for @stateActionReason.
  ///
  /// In zh, this message translates to:
  /// **'{action}：{reason}'**
  String stateActionReason(String action, String reason);

  /// No description provided for @stateProviderTokenCountInvalid.
  ///
  /// In zh, this message translates to:
  /// **'填写数字，如 128K'**
  String get stateProviderTokenCountInvalid;

  /// No description provided for @appSlogan.
  ///
  /// In zh, this message translates to:
  /// **'随时随刻，想go就Go！'**
  String get appSlogan;

  /// No description provided for @statePasteEmpty.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板中没有可粘贴的文本。'**
  String get statePasteEmpty;

  /// No description provided for @statePasteDenied.
  ///
  /// In zh, this message translates to:
  /// **'系统未授予粘贴权限，请重新点击粘贴按钮。'**
  String get statePasteDenied;

  /// No description provided for @statePasteBusy.
  ///
  /// In zh, this message translates to:
  /// **'粘贴窗口尚未结束或仍在关闭，请完成或取消后重试。'**
  String get statePasteBusy;

  /// No description provided for @statePasteFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法读取剪贴板，请重试或手动输入。'**
  String get statePasteFailed;

  /// No description provided for @systemActionsOpenedUi.
  ///
  /// In zh, this message translates to:
  /// **'已打开界面'**
  String get systemActionsOpenedUi;

  /// No description provided for @systemActionsResultUnknown.
  ///
  /// In zh, this message translates to:
  /// **'结果未知'**
  String get systemActionsResultUnknown;

  /// No description provided for @systemActionsNotSupported.
  ///
  /// In zh, this message translates to:
  /// **'不支持'**
  String get systemActionsNotSupported;

  /// No description provided for @systemActionsNotRun.
  ///
  /// In zh, this message translates to:
  /// **'没有执行'**
  String get systemActionsNotRun;

  /// No description provided for @systemActionsResultOpened.
  ///
  /// In zh, this message translates to:
  /// **'已打开界面，还没确认里面的事办完。'**
  String get systemActionsResultOpened;

  /// No description provided for @systemActionsResultContinued.
  ///
  /// In zh, this message translates to:
  /// **'你点了继续。这只说明你确认了，不代表其他应用里的操作完成了。'**
  String get systemActionsResultContinued;

  /// No description provided for @systemActionsResultNotified.
  ///
  /// In zh, this message translates to:
  /// **'通知已发出，不确定你有没有看到。'**
  String get systemActionsResultNotified;

  /// No description provided for @systemActionsResultReminder.
  ///
  /// In zh, this message translates to:
  /// **'已交给系统提醒，到点由系统响。引擎不会因此运行。'**
  String get systemActionsResultReminder;

  /// No description provided for @systemActionsResultClipboard.
  ///
  /// In zh, this message translates to:
  /// **'文字已写入剪贴板。'**
  String get systemActionsResultClipboard;

  /// No description provided for @systemActionsResultUnknownDetail.
  ///
  /// In zh, this message translates to:
  /// **'系统调用可能已经发出，结果未知。不会自动重试，请自己看一下实际状态。'**
  String get systemActionsResultUnknownDetail;

  /// No description provided for @systemActionsResultUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'鸿蒙版不支持这个动作，没有执行。'**
  String get systemActionsResultUnsupported;

  /// No description provided for @systemActionsResultOffScreen.
  ///
  /// In zh, this message translates to:
  /// **'DSH Go 不在屏幕上，没有执行。'**
  String get systemActionsResultOffScreen;

  /// No description provided for @systemActionsResultUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'系统操作没开或暂时连不上，没有执行。到「设置 → 系统操作」看看。'**
  String get systemActionsResultUnavailable;

  /// No description provided for @systemActionsResultStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止。'**
  String get systemActionsResultStopped;

  /// No description provided for @systemActionsResultTimeout.
  ///
  /// In zh, this message translates to:
  /// **'等待超时，没有结果。'**
  String get systemActionsResultTimeout;

  /// No description provided for @systemActionsResultNotRun.
  ///
  /// In zh, this message translates to:
  /// **'没有执行。'**
  String get systemActionsResultNotRun;

  /// No description provided for @viewArtifactSaved.
  ///
  /// In zh, this message translates to:
  /// **'已存到 {value}'**
  String viewArtifactSaved(String value);

  /// No description provided for @viewDownloadFolder.
  ///
  /// In zh, this message translates to:
  /// **'下载/'**
  String get viewDownloadFolder;

  /// No description provided for @viewArtifactNoPreview.
  ///
  /// In zh, this message translates to:
  /// **'无法预览'**
  String get viewArtifactNoPreview;

  /// No description provided for @viewArtifactNotText.
  ///
  /// In zh, this message translates to:
  /// **'不是文本文件'**
  String get viewArtifactNotText;

  /// No description provided for @viewArtifactLarge.
  ///
  /// In zh, this message translates to:
  /// **'文件较大'**
  String get viewArtifactLarge;

  /// No description provided for @viewArtifactMissing.
  ///
  /// In zh, this message translates to:
  /// **'文件已经不在了'**
  String get viewArtifactMissing;

  /// No description provided for @viewArtifactNotFile.
  ///
  /// In zh, this message translates to:
  /// **'这不是文件'**
  String get viewArtifactNotFile;

  /// No description provided for @viewArtifactOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能打开'**
  String get viewArtifactOpenFailed;

  /// No description provided for @viewArtifactMore.
  ///
  /// In zh, this message translates to:
  /// **'更多操作'**
  String get viewArtifactMore;

  /// No description provided for @viewWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'工作区'**
  String get viewWorkspace;

  /// No description provided for @viewArtifactEmpty.
  ///
  /// In zh, this message translates to:
  /// **'空文件'**
  String get viewArtifactEmpty;

  /// No description provided for @viewArtifactLines.
  ///
  /// In zh, this message translates to:
  /// **'文件较大，只显示前 {count} 行'**
  String viewArtifactLines(int count);

  /// No description provided for @viewArtifactRows.
  ///
  /// In zh, this message translates to:
  /// **'只显示前 {count} 行'**
  String viewArtifactRows(int count);

  /// No description provided for @viewArtifactColumns.
  ///
  /// In zh, this message translates to:
  /// **'只显示前 200 列'**
  String get viewArtifactColumns;

  /// No description provided for @viewArtifactWorksheet.
  ///
  /// In zh, this message translates to:
  /// **'工作表 {value}'**
  String viewArtifactWorksheet(int value);

  /// No description provided for @viewArtifactEmptySheet.
  ///
  /// In zh, this message translates to:
  /// **'空工作表'**
  String get viewArtifactEmptySheet;

  /// No description provided for @viewArtifactEmptyTable.
  ///
  /// In zh, this message translates to:
  /// **'空表格'**
  String get viewArtifactEmptyTable;

  /// No description provided for @viewArtifactConvertFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能转换'**
  String get viewArtifactConvertFailed;

  /// No description provided for @viewArtifactConverting.
  ///
  /// In zh, this message translates to:
  /// **'正在转换为 PDF 预览…'**
  String get viewArtifactConverting;

  /// No description provided for @viewArtifactImageFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法显示这张图片'**
  String get viewArtifactImageFailed;

  /// No description provided for @viewArtifactPhoneOpen.
  ///
  /// In zh, this message translates to:
  /// **'用手机上的应用打开'**
  String get viewArtifactPhoneOpen;

  /// No description provided for @viewArtifactPdfFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开这个 PDF，试试用其他应用打开'**
  String get viewArtifactPdfFailed;

  /// No description provided for @viewArtifactPages.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 页'**
  String viewArtifactPages(int count);

  /// No description provided for @viewArtifactPage.
  ///
  /// In zh, this message translates to:
  /// **'第 {value} 页'**
  String viewArtifactPage(int value);

  /// No description provided for @viewUiIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'视图没有生成完'**
  String get viewUiIncomplete;

  /// No description provided for @viewUiInvalid.
  ///
  /// In zh, this message translates to:
  /// **'这个视图格式有误'**
  String get viewUiInvalid;

  /// No description provided for @viewUiResend.
  ///
  /// In zh, this message translates to:
  /// **'让它重发'**
  String get viewUiResend;

  /// No description provided for @viewChartUnit.
  ///
  /// In zh, this message translates to:
  /// **'单位：{value}'**
  String viewChartUnit(String value);

  /// No description provided for @viewChartSeries.
  ///
  /// In zh, this message translates to:
  /// **'第 {value} 组'**
  String viewChartSeries(int value);

  /// No description provided for @viewChartTotal.
  ///
  /// In zh, this message translates to:
  /// **'合计'**
  String get viewChartTotal;

  /// No description provided for @viewChartBar.
  ///
  /// In zh, this message translates to:
  /// **'柱状图'**
  String get viewChartBar;

  /// No description provided for @viewChartHorizontalBar.
  ///
  /// In zh, this message translates to:
  /// **'横向柱状图'**
  String get viewChartHorizontalBar;

  /// No description provided for @viewChartLine.
  ///
  /// In zh, this message translates to:
  /// **'折线图'**
  String get viewChartLine;

  /// No description provided for @viewChartDonut.
  ///
  /// In zh, this message translates to:
  /// **'环形图'**
  String get viewChartDonut;

  /// No description provided for @viewUiResendMessage.
  ///
  /// In zh, this message translates to:
  /// **'上一个 dsh-ui 视图无法显示：{value}。请修正后重发。'**
  String viewUiResendMessage(Object value);

  /// No description provided for @viewUiBytesLimit.
  ///
  /// In zh, this message translates to:
  /// **'视图有 {first} 字节，超过上限 {second} 字节'**
  String viewUiBytesLimit(int first, int second);

  /// No description provided for @viewUiEmptyCode.
  ///
  /// In zh, this message translates to:
  /// **'代码块是空的'**
  String get viewUiEmptyCode;

  /// No description provided for @viewUiInvalidJson.
  ///
  /// In zh, this message translates to:
  /// **'不是合法的 JSON（{message}）'**
  String viewUiInvalidJson(String message);

  /// No description provided for @viewUiJsonRepaired.
  ///
  /// In zh, this message translates to:
  /// **'含注释或尾逗号，已忽略'**
  String get viewUiJsonRepaired;

  /// No description provided for @viewUiExpectedObject.
  ///
  /// In zh, this message translates to:
  /// **'应该是一个组件对象'**
  String get viewUiExpectedObject;

  /// No description provided for @viewUiDepthLimit.
  ///
  /// In zh, this message translates to:
  /// **'第 {first} 层，超过上限 {second} 层'**
  String viewUiDepthLimit(int first, int second);

  /// No description provided for @viewUiMissingType.
  ///
  /// In zh, this message translates to:
  /// **'缺少 type'**
  String get viewUiMissingType;

  /// No description provided for @viewUiUnknownComponent.
  ///
  /// In zh, this message translates to:
  /// **'未知组件 {value}'**
  String viewUiUnknownComponent(String value);

  /// No description provided for @viewUiAvailableTypes.
  ///
  /// In zh, this message translates to:
  /// **'{first}；可用：{second}'**
  String viewUiAvailableTypes(String first, String second);

  /// No description provided for @viewUiExpectedChildren.
  ///
  /// In zh, this message translates to:
  /// **'应该是 1 到 {limit} 个组件的数组'**
  String viewUiExpectedChildren(int limit);

  /// No description provided for @viewUiHiddenItems.
  ///
  /// In zh, this message translates to:
  /// **'已截断：还有 {count} 项没有显示'**
  String viewUiHiddenItems(int count);

  /// No description provided for @viewUiNodeLimit.
  ///
  /// In zh, this message translates to:
  /// **'超过 {first} 个组件，后 {second} 项已截断'**
  String viewUiNodeLimit(int first, int second);

  /// No description provided for @viewUiChildLimit.
  ///
  /// In zh, this message translates to:
  /// **'超过 {first} 项，后 {second} 项已截断'**
  String viewUiChildLimit(int first, int second);

  /// No description provided for @viewUiExpectedString.
  ///
  /// In zh, this message translates to:
  /// **'应该是字符串'**
  String get viewUiExpectedString;

  /// No description provided for @viewUiTextLimit.
  ///
  /// In zh, this message translates to:
  /// **'{first} 个字符，超过上限 {second}'**
  String viewUiTextLimit(int first, int second);

  /// No description provided for @viewUiTextTruncated.
  ///
  /// In zh, this message translates to:
  /// **'已截断：文字过长'**
  String get viewUiTextTruncated;

  /// No description provided for @viewUiExpectedFinite.
  ///
  /// In zh, this message translates to:
  /// **'应该是有限的数'**
  String get viewUiExpectedFinite;

  /// No description provided for @viewUiYes.
  ///
  /// In zh, this message translates to:
  /// **'是'**
  String get viewUiYes;

  /// No description provided for @viewUiNo.
  ///
  /// In zh, this message translates to:
  /// **'否'**
  String get viewUiNo;

  /// No description provided for @viewUiExpectedStringNumber.
  ///
  /// In zh, this message translates to:
  /// **'应该是字符串或数字'**
  String get viewUiExpectedStringNumber;

  /// No description provided for @viewUiUnknownTone.
  ///
  /// In zh, this message translates to:
  /// **'未知 tone {value}，已忽略；可用：good, warn, bad'**
  String viewUiUnknownTone(String value);

  /// No description provided for @viewUiUnknownChart.
  ///
  /// In zh, this message translates to:
  /// **'未知图表 {value}，按柱状图画；可用：bar, hbar, line, donut'**
  String viewUiUnknownChart(String value);

  /// No description provided for @viewUiExpectedCategories.
  ///
  /// In zh, this message translates to:
  /// **'应该是非空的标签数组'**
  String get viewUiExpectedCategories;

  /// No description provided for @viewUiCategoryLimit.
  ///
  /// In zh, this message translates to:
  /// **'{first} 个类别，超过上限 {second}'**
  String viewUiCategoryLimit(int first, int second);

  /// No description provided for @viewUiFirstPoints.
  ///
  /// In zh, this message translates to:
  /// **'只显示前 {limit} 个点'**
  String viewUiFirstPoints(int limit);

  /// No description provided for @viewUiExpectedSeries.
  ///
  /// In zh, this message translates to:
  /// **'应该是非空的数组，每项是 {shape}'**
  String viewUiExpectedSeries(String shape);

  /// No description provided for @viewUiSkippedSeries.
  ///
  /// In zh, this message translates to:
  /// **'应该是数字数组，这组已跳过'**
  String get viewUiSkippedSeries;

  /// No description provided for @viewUiValuesCategories.
  ///
  /// In zh, this message translates to:
  /// **'{first} 个值对 {second} 个类别，多的截掉、缺的留空'**
  String viewUiValuesCategories(int first, int second);

  /// No description provided for @viewUiNonFiniteValues.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个值不是有限的数，已留空'**
  String viewUiNonFiniteValues(int count);

  /// No description provided for @viewUiNoSeries.
  ///
  /// In zh, this message translates to:
  /// **'没有一组能画的数据'**
  String get viewUiNoSeries;

  /// No description provided for @viewUiDonutSeries.
  ///
  /// In zh, this message translates to:
  /// **'环形图只画一组数据，其余 {count} 组已忽略'**
  String viewUiDonutSeries(int count);

  /// No description provided for @viewUiFirstSeries.
  ///
  /// In zh, this message translates to:
  /// **'只画第一组数据'**
  String get viewUiFirstSeries;

  /// No description provided for @viewUiSeriesLimit.
  ///
  /// In zh, this message translates to:
  /// **'{first} 组数据，超过上限 {second}'**
  String viewUiSeriesLimit(int first, int second);

  /// No description provided for @viewUiFirstSeriesCount.
  ///
  /// In zh, this message translates to:
  /// **'只显示前 {limit} 组数据'**
  String viewUiFirstSeriesCount(int limit);

  /// No description provided for @viewUiNoFiniteValues.
  ///
  /// In zh, this message translates to:
  /// **'没有一个有限的数值'**
  String get viewUiNoFiniteValues;

  /// No description provided for @viewUiTruncated.
  ///
  /// In zh, this message translates to:
  /// **'已截断：{value}'**
  String viewUiTruncated(String value);

  /// No description provided for @viewUiExpectedCompare.
  ///
  /// In zh, this message translates to:
  /// **'应该是 2 到 {limit} 项的数组，每项是 {shape}'**
  String viewUiExpectedCompare(int limit, String shape);

  /// No description provided for @viewUiItemLimit.
  ///
  /// In zh, this message translates to:
  /// **'{first} 项，超过上限 {second}'**
  String viewUiItemLimit(int first, int second);

  /// No description provided for @viewUiFirstItems.
  ///
  /// In zh, this message translates to:
  /// **'只显示前 {limit} 项'**
  String viewUiFirstItems(int limit);

  /// No description provided for @viewUiSkippedCompare.
  ///
  /// In zh, this message translates to:
  /// **'应该是 {shape}，已跳过'**
  String viewUiSkippedCompare(String shape);

  /// No description provided for @viewUiSkippedItemLabel.
  ///
  /// In zh, this message translates to:
  /// **'应该是非空字符串，这项已跳过'**
  String get viewUiSkippedItemLabel;

  /// No description provided for @viewUiRowLimit.
  ///
  /// In zh, this message translates to:
  /// **'{first} 行，超过上限 {second}'**
  String viewUiRowLimit(int first, int second);

  /// No description provided for @viewUiSkippedRow.
  ///
  /// In zh, this message translates to:
  /// **'应该是 [名称, 值]，已跳过'**
  String get viewUiSkippedRow;

  /// No description provided for @viewUiNoItems.
  ///
  /// In zh, this message translates to:
  /// **'没有一项能画'**
  String get viewUiNoItems;

  /// No description provided for @viewUiFirstRows.
  ///
  /// In zh, this message translates to:
  /// **'每项只显示前 {limit} 行'**
  String viewUiFirstRows(int limit);

  /// No description provided for @viewUiExpectedSteps.
  ///
  /// In zh, this message translates to:
  /// **'应该是非空数组，每项是 {shape}'**
  String viewUiExpectedSteps(String shape);

  /// No description provided for @viewUiStepLimit.
  ///
  /// In zh, this message translates to:
  /// **'{first} 步，超过上限 {second}'**
  String viewUiStepLimit(int first, int second);

  /// No description provided for @viewUiFirstSteps.
  ///
  /// In zh, this message translates to:
  /// **'已截断：只显示前 {limit} 步'**
  String viewUiFirstSteps(int limit);

  /// No description provided for @viewUiSkippedStep.
  ///
  /// In zh, this message translates to:
  /// **'应该是 {shape}，已跳过'**
  String viewUiSkippedStep(String shape);

  /// No description provided for @viewUiUnknownStatus.
  ///
  /// In zh, this message translates to:
  /// **'未知状态 {value}，按 todo 画；可用：done, current, todo, failed'**
  String viewUiUnknownStatus(String value);

  /// No description provided for @viewUiNoSteps.
  ///
  /// In zh, this message translates to:
  /// **'没有一步能画'**
  String get viewUiNoSteps;

  /// No description provided for @viewUiUnknownCalloutTone.
  ///
  /// In zh, this message translates to:
  /// **'未知 tone {value}，按 info 画；可用：info, good, warn, bad'**
  String viewUiUnknownCalloutTone(String value);

  /// No description provided for @viewUiExpectedOptions.
  ///
  /// In zh, this message translates to:
  /// **'应该是 1 到 {limit} 个选项的数组，每项是 {shape}'**
  String viewUiExpectedOptions(int limit, String shape);

  /// No description provided for @viewUiOptionLimit.
  ///
  /// In zh, this message translates to:
  /// **'{first} 个选项，超过上限 {second}'**
  String viewUiOptionLimit(int first, int second);

  /// No description provided for @viewUiFirstOptions.
  ///
  /// In zh, this message translates to:
  /// **'已截断：只显示前 {limit} 个选项'**
  String viewUiFirstOptions(int limit);

  /// No description provided for @viewUiDuplicateLabel.
  ///
  /// In zh, this message translates to:
  /// **'重复的 label {value}，已跳过'**
  String viewUiDuplicateLabel(String value);

  /// No description provided for @viewUiNoOptions.
  ///
  /// In zh, this message translates to:
  /// **'没有一个能用的选项'**
  String get viewUiNoOptions;

  /// No description provided for @viewUiSummaryBody.
  ///
  /// In zh, this message translates to:
  /// **'[视图] {value}'**
  String viewUiSummaryBody(String value);

  /// No description provided for @viewUiSummaryTitleBody.
  ///
  /// In zh, this message translates to:
  /// **'[视图] {first}：{second}'**
  String viewUiSummaryTitleBody(String first, String second);

  /// No description provided for @viewUiSummaryInvalid.
  ///
  /// In zh, this message translates to:
  /// **'[视图]（格式有误，未能显示）'**
  String get viewUiSummaryInvalid;

  /// No description provided for @viewUiSummaryText.
  ///
  /// In zh, this message translates to:
  /// **'文字：{value}'**
  String viewUiSummaryText(String value);

  /// No description provided for @viewUiSummaryChart.
  ///
  /// In zh, this message translates to:
  /// **'图表：{summary}'**
  String viewUiSummaryChart(String summary);

  /// No description provided for @viewUiSummaryCompare.
  ///
  /// In zh, this message translates to:
  /// **'对比：{value}'**
  String viewUiSummaryCompare(String value);

  /// No description provided for @viewUiSummarySteps.
  ///
  /// In zh, this message translates to:
  /// **'步骤：{value}'**
  String viewUiSummarySteps(String value);

  /// No description provided for @viewUiSummaryCallout.
  ///
  /// In zh, this message translates to:
  /// **'提示：{value}'**
  String viewUiSummaryCallout(String value);

  /// No description provided for @viewUiSummaryOptions.
  ///
  /// In zh, this message translates to:
  /// **'选项：{value}'**
  String viewUiSummaryOptions(String value);

  /// No description provided for @viewUiSummaryConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认：{first}/{second}'**
  String viewUiSummaryConfirm(String first, String second);

  /// No description provided for @viewUiReplyChoice.
  ///
  /// In zh, this message translates to:
  /// **'选择：{value}'**
  String viewUiReplyChoice(String value);

  /// No description provided for @viewUiReplyConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认：{value}'**
  String viewUiReplyConfirm(String value);

  /// No description provided for @viewUiReplyCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消：{value}'**
  String viewUiReplyCancel(String value);

  /// No description provided for @viewUiReplyOther.
  ///
  /// In zh, this message translates to:
  /// **'其他：{value}'**
  String viewUiReplyOther(String value);

  /// No description provided for @viewUiFreeTextHint.
  ///
  /// In zh, this message translates to:
  /// **'其他（自己填）'**
  String get viewUiFreeTextHint;

  /// No description provided for @viewUiChosenOther.
  ///
  /// In zh, this message translates to:
  /// **'已填写：{value}'**
  String viewUiChosenOther(String value);

  /// No description provided for @viewUiChosen.
  ///
  /// In zh, this message translates to:
  /// **'已选择：{value}'**
  String viewUiChosen(String value);

  /// No description provided for @viewUiConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已确认'**
  String get viewUiConfirmed;

  /// No description provided for @viewUiConfirmedValue.
  ///
  /// In zh, this message translates to:
  /// **'已确认：{value}'**
  String viewUiConfirmedValue(String value);

  /// No description provided for @viewUiCancelledValue.
  ///
  /// In zh, this message translates to:
  /// **'已取消：{value}'**
  String viewUiCancelledValue(String value);

  /// No description provided for @viewUiReplied.
  ///
  /// In zh, this message translates to:
  /// **'已回复'**
  String get viewUiReplied;

  /// No description provided for @viewUiGenerating.
  ///
  /// In zh, this message translates to:
  /// **'正在生成视图'**
  String get viewUiGenerating;

  /// No description provided for @viewUiReplyAfterEnd.
  ///
  /// In zh, this message translates to:
  /// **'回复结束后可选'**
  String get viewUiReplyAfterEnd;

  /// No description provided for @viewUiExpired.
  ///
  /// In zh, this message translates to:
  /// **'已失效'**
  String get viewUiExpired;

  /// No description provided for @viewUiNotStarted.
  ///
  /// In zh, this message translates to:
  /// **'未开始'**
  String get viewUiNotStarted;

  /// No description provided for @viewUiMultiple.
  ///
  /// In zh, this message translates to:
  /// **'可多选'**
  String get viewUiMultiple;

  /// No description provided for @viewSuggestWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'看看工作区'**
  String get viewSuggestWorkspace;

  /// No description provided for @viewSuggestWorkspacePrompt.
  ///
  /// In zh, this message translates to:
  /// **'看看工作区里现在有哪些文件和项目，简单介绍一下。'**
  String get viewSuggestWorkspacePrompt;

  /// No description provided for @viewSuggestWordCount.
  ///
  /// In zh, this message translates to:
  /// **'写个小脚本'**
  String get viewSuggestWordCount;

  /// No description provided for @viewSuggestWordCountPrompt.
  ///
  /// In zh, this message translates to:
  /// **'写一个 Python 脚本：统计一个文本文件里出现最多的 20 个词，并运行一次给我看结果。'**
  String get viewSuggestWordCountPrompt;

  /// No description provided for @viewSuggestNode.
  ///
  /// In zh, this message translates to:
  /// **'新建项目'**
  String get viewSuggestNode;

  /// No description provided for @viewSuggestNodePrompt.
  ///
  /// In zh, this message translates to:
  /// **'在工作区新建一个 Node.js 项目，配好 TypeScript 和一个最小的单元测试。'**
  String get viewSuggestNodePrompt;

  /// No description provided for @viewSuggestGit.
  ///
  /// In zh, this message translates to:
  /// **'讲讲 Git'**
  String get viewSuggestGit;

  /// No description provided for @viewSuggestGitPrompt.
  ///
  /// In zh, this message translates to:
  /// **'用一个具体例子解释 git rebase 和 git merge 的区别，各自什么时候用。'**
  String get viewSuggestGitPrompt;

  /// No description provided for @viewSuggestWorkspaceHint.
  ///
  /// In zh, this message translates to:
  /// **'列出文件和项目'**
  String get viewSuggestWorkspaceHint;

  /// No description provided for @viewSuggestWordCountHint.
  ///
  /// In zh, this message translates to:
  /// **'统计词频并跑一次'**
  String get viewSuggestWordCountHint;

  /// No description provided for @viewSuggestNodeHint.
  ///
  /// In zh, this message translates to:
  /// **'Node.js 带测试'**
  String get viewSuggestNodeHint;

  /// No description provided for @viewSuggestGitHint.
  ///
  /// In zh, this message translates to:
  /// **'rebase 和 merge'**
  String get viewSuggestGitHint;

  /// No description provided for @viewTipNext.
  ///
  /// In zh, this message translates to:
  /// **'下一条小技巧'**
  String get viewTipNext;

  /// No description provided for @viewTipLabel.
  ///
  /// In zh, this message translates to:
  /// **'小技巧：{value}'**
  String viewTipLabel(String value);

  /// No description provided for @viewTipSteer.
  ///
  /// In zh, this message translates to:
  /// **'生成中长按发送键，可以插话、排队或打断'**
  String get viewTipSteer;

  /// No description provided for @viewTipMidRun.
  ///
  /// In zh, this message translates to:
  /// **'AI 干活时也能发消息，它下一步就会看到'**
  String get viewTipMidRun;

  /// No description provided for @viewTipSlash.
  ///
  /// In zh, this message translates to:
  /// **'输入 / 唤出指令：压缩上下文、切换模型等'**
  String get viewTipSlash;

  /// No description provided for @viewTipMention.
  ///
  /// In zh, this message translates to:
  /// **'输入 @ 可以引用工作区里的文件或别的对话'**
  String get viewTipMention;

  /// No description provided for @viewTipReplyMenu.
  ///
  /// In zh, this message translates to:
  /// **'长按 AI 的回复，可以复制、引用或重新生成'**
  String get viewTipReplyMenu;

  /// No description provided for @viewTipEditResend.
  ///
  /// In zh, this message translates to:
  /// **'长按自己的消息，可以改写后重发，原对话不动'**
  String get viewTipEditResend;

  /// No description provided for @viewTipQuote.
  ///
  /// In zh, this message translates to:
  /// **'选中回复里的一段，点「引用」就只追问那一段'**
  String get viewTipQuote;

  /// No description provided for @viewTipTitleDetails.
  ///
  /// In zh, this message translates to:
  /// **'点顶部的对话标题，能看改动、文件和终端'**
  String get viewTipTitleDetails;

  /// No description provided for @viewTipContextRing.
  ///
  /// In zh, this message translates to:
  /// **'发送键旁的小圆环是上下文用量，点开看详情'**
  String get viewTipContextRing;

  /// No description provided for @viewTipDrawerMenu.
  ///
  /// In zh, this message translates to:
  /// **'长按侧栏里的对话，可以置顶、改名或归档'**
  String get viewTipDrawerMenu;

  /// No description provided for @viewTipSearch.
  ///
  /// In zh, this message translates to:
  /// **'主机支持时，搜索对话还能搜到聊天内容，不只是标题'**
  String get viewTipSearch;

  /// No description provided for @viewTipSettingsSearch.
  ///
  /// In zh, this message translates to:
  /// **'长按侧栏的设置键，可以直接搜索设置项'**
  String get viewTipSettingsSearch;

  /// No description provided for @viewTipQuickPanel.
  ///
  /// In zh, this message translates to:
  /// **'在对话页向左滑，打开快捷入口'**
  String get viewTipQuickPanel;

  /// No description provided for @viewTipFolderNewChat.
  ///
  /// In zh, this message translates to:
  /// **'长按侧栏的文件夹，可以直接在里面开新对话'**
  String get viewTipFolderNewChat;

  /// No description provided for @viewTipSwitchHost.
  ///
  /// In zh, this message translates to:
  /// **'点侧栏底部的主机名，可以切到电脑上的 DSH'**
  String get viewTipSwitchHost;

  /// No description provided for @viewTipPasteImage.
  ///
  /// In zh, this message translates to:
  /// **'输入法里的截图和贴图，可以直接贴进输入框'**
  String get viewTipPasteImage;

  /// No description provided for @viewTipLauncher.
  ///
  /// In zh, this message translates to:
  /// **'长按桌面图标，可以直接语音提问或开新对话'**
  String get viewTipLauncher;

  /// No description provided for @viewTipPetBubble.
  ///
  /// In zh, this message translates to:
  /// **'宠物冒泡时点一下，就跳到等你的那个对话'**
  String get viewTipPetBubble;

  /// No description provided for @viewTipPetPlay.
  ///
  /// In zh, this message translates to:
  /// **'连点宠物三下会挠痒痒，长按可以换宠物'**
  String get viewTipPetPlay;

  /// No description provided for @viewTipActivityStrip.
  ///
  /// In zh, this message translates to:
  /// **'生成时点一下状态条，看这一轮的完整轨迹'**
  String get viewTipActivityStrip;

  /// No description provided for @viewTipImageZoom.
  ///
  /// In zh, this message translates to:
  /// **'看图时双击放大、双指缩放，长按可以保存'**
  String get viewTipImageZoom;

  /// No description provided for @viewTipQueuedRecall.
  ///
  /// In zh, this message translates to:
  /// **'排队中的消息可以撤回到输入框再改'**
  String get viewTipQueuedRecall;

  /// No description provided for @viewTipKeyboard.
  ///
  /// In zh, this message translates to:
  /// **'接了键盘：Ctrl+Enter 发送，连按两次 Esc 停止'**
  String get viewTipKeyboard;

  /// No description provided for @viewTipShareIn.
  ///
  /// In zh, this message translates to:
  /// **'在别的 App 里分享文字或图片给 DSH Go，会填进新对话'**
  String get viewTipShareIn;

  /// No description provided for @viewTipShareSelect.
  ///
  /// In zh, this message translates to:
  /// **'分享对话时长按再滑动，可以一次选中多条消息'**
  String get viewTipShareSelect;

  /// No description provided for @viewTipChartDrag.
  ///
  /// In zh, this message translates to:
  /// **'回复里的图表可以左右拖动，看每个点的数值'**
  String get viewTipChartDrag;

  /// No description provided for @viewTipCopyPath.
  ///
  /// In zh, this message translates to:
  /// **'改动卡里长按某个文件，可以复制它的路径'**
  String get viewTipCopyPath;

  /// No description provided for @viewTipCompanion.
  ///
  /// In zh, this message translates to:
  /// **'「伙伴小屋」藏在切换主机的面板里'**
  String get viewTipCompanion;

  /// No description provided for @viewTipAnswerInline.
  ///
  /// In zh, this message translates to:
  /// **'AI 向你提问时，直接在输入框里打字就是回答'**
  String get viewTipAnswerInline;

  /// No description provided for @viewTipWallpaper.
  ///
  /// In zh, this message translates to:
  /// **'壁纸可以拖动、缩放，还能调模糊和明暗'**
  String get viewTipWallpaper;

  /// No description provided for @viewTipModelHere.
  ///
  /// In zh, this message translates to:
  /// **'这里就能换模型、预设和权限，只对这次对话生效'**
  String get viewTipModelHere;

  /// No description provided for @viewNewChatFolder.
  ///
  /// In zh, this message translates to:
  /// **'文件夹'**
  String get viewNewChatFolder;

  /// No description provided for @viewNewChatPresetTitle.
  ///
  /// In zh, this message translates to:
  /// **'这次对话的预设'**
  String get viewNewChatPresetTitle;

  /// No description provided for @viewNewChatPermissionTitle.
  ///
  /// In zh, this message translates to:
  /// **'这次对话的权限'**
  String get viewNewChatPermissionTitle;

  /// No description provided for @viewNewChatDefault.
  ///
  /// In zh, this message translates to:
  /// **'默认'**
  String get viewNewChatDefault;

  /// No description provided for @viewNewChatUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'不可用'**
  String get viewNewChatUnavailable;

  /// No description provided for @viewNewChatChange.
  ///
  /// In zh, this message translates to:
  /// **'更改'**
  String get viewNewChatChange;

  /// No description provided for @viewNewChatModesFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能设置预设或权限，消息还没发出'**
  String get viewNewChatModesFailed;

  /// No description provided for @viewGreetingMorning.
  ///
  /// In zh, this message translates to:
  /// **'早上好'**
  String get viewGreetingMorning;

  /// No description provided for @viewGreetingNoon.
  ///
  /// In zh, this message translates to:
  /// **'中午好'**
  String get viewGreetingNoon;

  /// No description provided for @viewGreetingAfternoon.
  ///
  /// In zh, this message translates to:
  /// **'下午好'**
  String get viewGreetingAfternoon;

  /// No description provided for @viewGreetingEvening.
  ///
  /// In zh, this message translates to:
  /// **'晚上好'**
  String get viewGreetingEvening;

  /// No description provided for @viewGreetingNight.
  ///
  /// In zh, this message translates to:
  /// **'夜深了'**
  String get viewGreetingNight;

  /// No description provided for @viewEmptySubtitle.
  ///
  /// In zh, this message translates to:
  /// **'今天想做点什么？'**
  String get viewEmptySubtitle;

  /// No description provided for @viewEmptyStarting.
  ///
  /// In zh, this message translates to:
  /// **'正在启动引擎…'**
  String get viewEmptyStarting;

  /// No description provided for @viewEmptyConnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接引擎…'**
  String get viewEmptyConnecting;

  /// No description provided for @viewEmptyDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'引擎未连接'**
  String get viewEmptyDisconnected;

  /// No description provided for @viewEmptyReconnect.
  ///
  /// In zh, this message translates to:
  /// **'重新连接'**
  String get viewEmptyReconnect;

  /// No description provided for @viewEmptyWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'在「{value}」中'**
  String viewEmptyWorkspace(String value);

  /// No description provided for @viewEmptySwitchWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'切换工作区'**
  String get viewEmptySwitchWorkspace;

  /// No description provided for @viewEmptyHostDefaultDirectory.
  ///
  /// In zh, this message translates to:
  /// **'主机默认目录'**
  String get viewEmptyHostDefaultDirectory;

  /// No description provided for @viewScheduleTitle.
  ///
  /// In zh, this message translates to:
  /// **'自动化任务'**
  String get viewScheduleTitle;

  /// No description provided for @viewScheduleRefreshFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能刷新'**
  String get viewScheduleRefreshFailed;

  /// No description provided for @viewScheduleNone.
  ///
  /// In zh, this message translates to:
  /// **'没有进行中的任务'**
  String get viewScheduleNone;

  /// No description provided for @viewScheduleNext.
  ///
  /// In zh, this message translates to:
  /// **'下次 {value}'**
  String viewScheduleNext(String value);

  /// No description provided for @viewScheduleUntitled.
  ///
  /// In zh, this message translates to:
  /// **'未命名任务'**
  String get viewScheduleUntitled;

  /// No description provided for @viewScheduleSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能发送'**
  String get viewScheduleSendFailed;

  /// No description provided for @viewScheduleEnded.
  ///
  /// In zh, this message translates to:
  /// **'已结束'**
  String get viewScheduleEnded;

  /// No description provided for @viewScheduleUpcoming.
  ///
  /// In zh, this message translates to:
  /// **'接下来'**
  String get viewScheduleUpcoming;

  /// No description provided for @viewScheduleSending.
  ///
  /// In zh, this message translates to:
  /// **'发送中…'**
  String get viewScheduleSending;

  /// No description provided for @viewScheduleRunNow.
  ///
  /// In zh, this message translates to:
  /// **'立即运行'**
  String get viewScheduleRunNow;

  /// No description provided for @viewScheduleManage.
  ///
  /// In zh, this message translates to:
  /// **'管理'**
  String get viewScheduleManage;

  /// No description provided for @viewScheduleToday.
  ///
  /// In zh, this message translates to:
  /// **'今天 {value}'**
  String viewScheduleToday(String value);

  /// No description provided for @viewScheduleTomorrow.
  ///
  /// In zh, this message translates to:
  /// **'明天 {value}'**
  String viewScheduleTomorrow(String value);

  /// No description provided for @viewScheduleYesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天 {value}'**
  String viewScheduleYesterday(String value);

  /// No description provided for @viewScheduleWeekday.
  ///
  /// In zh, this message translates to:
  /// **'周{first} {second}'**
  String viewScheduleWeekday(String first, String second);

  /// No description provided for @viewScheduleDue.
  ///
  /// In zh, this message translates to:
  /// **'即将运行'**
  String get viewScheduleDue;

  /// No description provided for @viewScheduleDaysAhead.
  ///
  /// In zh, this message translates to:
  /// **'{count} 天后'**
  String viewScheduleDaysAhead(int count);

  /// No description provided for @viewScheduleDaysOverdue.
  ///
  /// In zh, this message translates to:
  /// **'已逾期 {count} 天'**
  String viewScheduleDaysOverdue(int count);

  /// No description provided for @viewScheduleSingleLabel.
  ///
  /// In zh, this message translates to:
  /// **'自动化任务：{title}'**
  String viewScheduleSingleLabel(String title);

  /// No description provided for @viewScheduleCountLabel.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个自动化任务'**
  String viewScheduleCountLabel(int count);

  /// No description provided for @viewModelSelect.
  ///
  /// In zh, this message translates to:
  /// **'选择模型'**
  String get viewModelSelect;

  /// No description provided for @viewModelThinkingOff.
  ///
  /// In zh, this message translates to:
  /// **'不思考'**
  String get viewModelThinkingOff;

  /// No description provided for @viewModelThinkingMinimal.
  ///
  /// In zh, this message translates to:
  /// **'极少'**
  String get viewModelThinkingMinimal;

  /// No description provided for @viewModelThinkingLow.
  ///
  /// In zh, this message translates to:
  /// **'低'**
  String get viewModelThinkingLow;

  /// No description provided for @viewModelThinkingMedium.
  ///
  /// In zh, this message translates to:
  /// **'中'**
  String get viewModelThinkingMedium;

  /// No description provided for @viewModelThinkingHigh.
  ///
  /// In zh, this message translates to:
  /// **'高'**
  String get viewModelThinkingHigh;

  /// No description provided for @viewModelThinkingMax.
  ///
  /// In zh, this message translates to:
  /// **'最高'**
  String get viewModelThinkingMax;

  /// No description provided for @viewModelLabel.
  ///
  /// In zh, this message translates to:
  /// **'模型：{value}'**
  String viewModelLabel(String value);

  /// No description provided for @viewModelEffortLabel.
  ///
  /// In zh, this message translates to:
  /// **'思考深度{value}'**
  String viewModelEffortLabel(String value);

  /// No description provided for @viewModelLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'模型列表加载失败'**
  String get viewModelLoadFailed;

  /// No description provided for @viewModelDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'未连接引擎'**
  String get viewModelDisconnected;

  /// No description provided for @viewModelConnectHint.
  ///
  /// In zh, this message translates to:
  /// **'连接后即可选择模型'**
  String get viewModelConnectHint;

  /// No description provided for @viewModelEffort.
  ///
  /// In zh, this message translates to:
  /// **'思考深度'**
  String get viewModelEffort;

  /// No description provided for @viewModelKeyRequired.
  ///
  /// In zh, this message translates to:
  /// **'主机尚未配置模型'**
  String get viewModelKeyRequired;

  /// No description provided for @viewModelProvidersHint.
  ///
  /// In zh, this message translates to:
  /// **'请在主机配置模型后重新打开此列表。'**
  String get viewModelProvidersHint;

  /// No description provided for @viewModelNone.
  ///
  /// In zh, this message translates to:
  /// **'暂无可用模型'**
  String get viewModelNone;

  /// No description provided for @viewModelKeyHint.
  ///
  /// In zh, this message translates to:
  /// **'请检查主机上的模型配置与凭据。'**
  String get viewModelKeyHint;

  /// No description provided for @viewContinuePrompt.
  ///
  /// In zh, this message translates to:
  /// **'接着附件里这段对话聊：'**
  String get viewContinuePrompt;

  /// No description provided for @viewContinueRange.
  ///
  /// In zh, this message translates to:
  /// **'第 {first}–{second} 轮，共 {third} 轮'**
  String viewContinueRange(int first, int second, int third);

  /// No description provided for @viewContinueHeader.
  ///
  /// In zh, this message translates to:
  /// **'> 分享的 DSH Go 对话 · {value}\n'**
  String viewContinueHeader(String value);

  /// No description provided for @viewContinueUser.
  ///
  /// In zh, this message translates to:
  /// **'\n## 用户\n\n'**
  String get viewContinueUser;

  /// No description provided for @viewImageCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 张图片'**
  String viewImageCount(int count);

  /// No description provided for @viewContinueAttachments.
  ///
  /// In zh, this message translates to:
  /// **'\n（附件：{value}）\n'**
  String viewContinueAttachments(String value);

  /// No description provided for @viewContinueAssistant.
  ///
  /// In zh, this message translates to:
  /// **'\n## 助手\n\n'**
  String get viewContinueAssistant;

  /// No description provided for @viewContinueInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'\n（回复被中断）\n'**
  String get viewContinueInterrupted;

  /// No description provided for @viewContinueFailed.
  ///
  /// In zh, this message translates to:
  /// **'（失败）'**
  String get viewContinueFailed;

  /// No description provided for @viewContinueDeclined.
  ///
  /// In zh, this message translates to:
  /// **'（被拒绝）'**
  String get viewContinueDeclined;

  /// No description provided for @viewContinueCancelled.
  ///
  /// In zh, this message translates to:
  /// **'（已取消）'**
  String get viewContinueCancelled;

  /// No description provided for @viewLinkWeek.
  ///
  /// In zh, this message translates to:
  /// **'7 天'**
  String get viewLinkWeek;

  /// No description provided for @viewLinkMonth.
  ///
  /// In zh, this message translates to:
  /// **'30 天'**
  String get viewLinkMonth;

  /// No description provided for @viewLinkForever.
  ///
  /// In zh, this message translates to:
  /// **'永久'**
  String get viewLinkForever;

  /// No description provided for @viewShareChat.
  ///
  /// In zh, this message translates to:
  /// **'对话'**
  String get viewShareChat;

  /// No description provided for @viewShareNoPermission.
  ///
  /// In zh, this message translates to:
  /// **'没有存储权限，没能保存'**
  String get viewShareNoPermission;

  /// No description provided for @viewShareOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能打开分享'**
  String get viewShareOpenFailed;

  /// No description provided for @viewShareLinkFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能生成链接，稍后再试'**
  String get viewShareLinkFailed;

  /// No description provided for @viewShareLinkText.
  ///
  /// In zh, this message translates to:
  /// **'「{first}」· DSH Go 对话\n{second}'**
  String viewShareLinkText(String first, String second);

  /// No description provided for @viewShareEmpty.
  ///
  /// In zh, this message translates to:
  /// **'这个对话还没有内容'**
  String get viewShareEmpty;

  /// No description provided for @viewShareMessageCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条消息'**
  String viewShareMessageCount(int count);

  /// No description provided for @viewShareToolCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 次工具调用'**
  String viewShareToolCount(int count);

  /// No description provided for @viewShareFileHint.
  ///
  /// In zh, this message translates to:
  /// **'在 DSH Go 里回放、接着聊'**
  String get viewShareFileHint;

  /// No description provided for @viewShareWebHint.
  ///
  /// In zh, this message translates to:
  /// **'任何浏览器都能打开，不用联网'**
  String get viewShareWebHint;

  /// No description provided for @viewShareMarkdownHint.
  ///
  /// In zh, this message translates to:
  /// **'纯文本，随处可读'**
  String get viewShareMarkdownHint;

  /// No description provided for @viewShareLinkHint.
  ///
  /// In zh, this message translates to:
  /// **'端到端加密，服务器看不到内容'**
  String get viewShareLinkHint;

  /// No description provided for @viewSharePreview.
  ///
  /// In zh, this message translates to:
  /// **'预览'**
  String get viewSharePreview;

  /// No description provided for @viewShareWhole.
  ///
  /// In zh, this message translates to:
  /// **'整段对话'**
  String get viewShareWhole;

  /// No description provided for @viewShareScopeReply.
  ///
  /// In zh, this message translates to:
  /// **'这条回复'**
  String get viewShareScopeReply;

  /// No description provided for @viewShareScopePicked.
  ///
  /// In zh, this message translates to:
  /// **'选中消息'**
  String get viewShareScopePicked;

  /// No description provided for @viewShareThinking.
  ///
  /// In zh, this message translates to:
  /// **'思考过程'**
  String get viewShareThinking;

  /// No description provided for @viewShareIncludeTools.
  ///
  /// In zh, this message translates to:
  /// **'工具调用'**
  String get viewShareIncludeTools;

  /// No description provided for @viewShareChatFile.
  ///
  /// In zh, this message translates to:
  /// **'对话文件'**
  String get viewShareChatFile;

  /// No description provided for @viewShareWebPage.
  ///
  /// In zh, this message translates to:
  /// **'网页'**
  String get viewShareWebPage;

  /// No description provided for @viewShareLink.
  ///
  /// In zh, this message translates to:
  /// **'链接'**
  String get viewShareLink;

  /// No description provided for @viewShareAsImage.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get viewShareAsImage;

  /// No description provided for @viewShareAsFile.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get viewShareAsFile;

  /// No description provided for @viewShareAsText.
  ///
  /// In zh, this message translates to:
  /// **'文字'**
  String get viewShareAsText;

  /// No description provided for @viewShareRedacted.
  ///
  /// In zh, this message translates to:
  /// **'密钥已隐藏'**
  String get viewShareRedacted;

  /// No description provided for @viewShareAdjust.
  ///
  /// In zh, this message translates to:
  /// **'调整'**
  String get viewShareAdjust;

  /// No description provided for @viewShareTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'超过 {value} MB，请缩小范围'**
  String viewShareTooLarge(int value);

  /// No description provided for @viewShareCreateLink.
  ///
  /// In zh, this message translates to:
  /// **'生成链接'**
  String get viewShareCreateLink;

  /// No description provided for @viewShareStop.
  ///
  /// In zh, this message translates to:
  /// **'停止分享'**
  String get viewShareStop;

  /// No description provided for @viewShareStopTitle.
  ///
  /// In zh, this message translates to:
  /// **'停止分享？'**
  String get viewShareStopTitle;

  /// No description provided for @viewShareStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止分享'**
  String get viewShareStopped;

  /// No description provided for @viewQrCode.
  ///
  /// In zh, this message translates to:
  /// **'二维码'**
  String get viewQrCode;

  /// No description provided for @viewShareTurn.
  ///
  /// In zh, this message translates to:
  /// **'第 {value} 轮'**
  String viewShareTurn(int value);

  /// No description provided for @viewReplayContinue.
  ///
  /// In zh, this message translates to:
  /// **'接着聊'**
  String get viewReplayContinue;

  /// No description provided for @viewReplayTurns.
  ///
  /// In zh, this message translates to:
  /// **'第 {first}–{second} 轮'**
  String viewReplayTurns(int first, int second);

  /// No description provided for @viewReplaySeconds.
  ///
  /// In zh, this message translates to:
  /// **'{count} 秒'**
  String viewReplaySeconds(int count);

  /// No description provided for @viewReplayMinutes.
  ///
  /// In zh, this message translates to:
  /// **'{count} 分钟'**
  String viewReplayMinutes(int count);

  /// No description provided for @viewReplayFull.
  ///
  /// In zh, this message translates to:
  /// **'全文'**
  String get viewReplayFull;

  /// No description provided for @viewReplayPause.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get viewReplayPause;

  /// No description provided for @viewReplayRestart.
  ///
  /// In zh, this message translates to:
  /// **'重新播放'**
  String get viewReplayRestart;

  /// No description provided for @viewReplayPlay.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get viewReplayPlay;

  /// No description provided for @viewReplaySpeed.
  ///
  /// In zh, this message translates to:
  /// **'倍速 {value}×'**
  String viewReplaySpeed(int value);

  /// No description provided for @viewTemplatePaper.
  ///
  /// In zh, this message translates to:
  /// **'纸张'**
  String get viewTemplatePaper;

  /// No description provided for @viewTemplateGlass.
  ///
  /// In zh, this message translates to:
  /// **'玻璃'**
  String get viewTemplateGlass;

  /// No description provided for @viewTemplateCard.
  ///
  /// In zh, this message translates to:
  /// **'卡片'**
  String get viewTemplateCard;

  /// No description provided for @viewShareProjectQr.
  ///
  /// In zh, this message translates to:
  /// **'项目主页二维码'**
  String get viewShareProjectQr;

  /// No description provided for @viewShareBrandLine.
  ///
  /// In zh, this message translates to:
  /// **'手机上的 DSH · 扫码获取'**
  String get viewShareBrandLine;

  /// No description provided for @viewShareBrandLineNoQr.
  ///
  /// In zh, this message translates to:
  /// **'手机上的 DSH'**
  String get viewShareBrandLineNoQr;

  /// No description provided for @viewShareSteps.
  ///
  /// In zh, this message translates to:
  /// **'{count} 步'**
  String viewShareSteps(int count);

  /// No description provided for @viewShareWebSearch.
  ///
  /// In zh, this message translates to:
  /// **'联网搜索'**
  String get viewShareWebSearch;

  /// No description provided for @viewShareOpenPage.
  ///
  /// In zh, this message translates to:
  /// **'打开网页'**
  String get viewShareOpenPage;

  /// No description provided for @viewShareRunCommand.
  ///
  /// In zh, this message translates to:
  /// **'运行命令'**
  String get viewShareRunCommand;

  /// No description provided for @viewShareReadFile.
  ///
  /// In zh, this message translates to:
  /// **'查看文件'**
  String get viewShareReadFile;

  /// No description provided for @viewShareEditFile.
  ///
  /// In zh, this message translates to:
  /// **'修改文件'**
  String get viewShareEditFile;

  /// No description provided for @viewShareSubagent.
  ///
  /// In zh, this message translates to:
  /// **'子代理'**
  String get viewShareSubagent;

  /// No description provided for @viewShareSkill.
  ///
  /// In zh, this message translates to:
  /// **'使用技能'**
  String get viewShareSkill;

  /// No description provided for @viewSharePresentFiles.
  ///
  /// In zh, this message translates to:
  /// **'交付文件'**
  String get viewSharePresentFiles;

  /// No description provided for @viewShareWorkflow.
  ///
  /// In zh, this message translates to:
  /// **'工作流'**
  String get viewShareWorkflow;

  /// No description provided for @viewSharePlugin.
  ///
  /// In zh, this message translates to:
  /// **'调用插件'**
  String get viewSharePlugin;

  /// No description provided for @viewShareImages.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get viewShareImages;

  /// No description provided for @viewSharePickMessages.
  ///
  /// In zh, this message translates to:
  /// **'选择消息'**
  String get viewSharePickMessages;

  /// No description provided for @viewShareDoneCount.
  ///
  /// In zh, this message translates to:
  /// **'完成（{count}）'**
  String viewShareDoneCount(int count);

  /// No description provided for @viewShareImageMarker.
  ///
  /// In zh, this message translates to:
  /// **'〔图片〕'**
  String get viewShareImageMarker;

  /// No description provided for @viewShareImagesMarker.
  ///
  /// In zh, this message translates to:
  /// **'〔{count} 张图片〕'**
  String viewShareImagesMarker(int count);

  /// No description provided for @viewShareYou.
  ///
  /// In zh, this message translates to:
  /// **'你'**
  String get viewShareYou;

  /// No description provided for @viewShareImageFailed.
  ///
  /// In zh, this message translates to:
  /// **'没能生成图片，请重试'**
  String get viewShareImageFailed;

  /// No description provided for @viewShareQuestion.
  ///
  /// In zh, this message translates to:
  /// **'提问'**
  String get viewShareQuestion;

  /// No description provided for @viewShareModelSteps.
  ///
  /// In zh, this message translates to:
  /// **'模型与过程'**
  String get viewShareModelSteps;

  /// No description provided for @viewShareImagePreview.
  ///
  /// In zh, this message translates to:
  /// **'分享图片预览'**
  String get viewShareImagePreview;

  /// No description provided for @viewShareSaveImage.
  ///
  /// In zh, this message translates to:
  /// **'保存图片'**
  String get viewShareSaveImage;

  /// No description provided for @viewScheduleHoursAhead.
  ///
  /// In zh, this message translates to:
  /// **'{count} 小时后'**
  String viewScheduleHoursAhead(int count);

  /// No description provided for @viewScheduleHoursOverdue.
  ///
  /// In zh, this message translates to:
  /// **'已逾期 {count} 小时'**
  String viewScheduleHoursOverdue(int count);

  /// No description provided for @viewScheduleMinutesAhead.
  ///
  /// In zh, this message translates to:
  /// **'{count} 分钟后'**
  String viewScheduleMinutesAhead(int count);

  /// No description provided for @viewScheduleMinutesOverdue.
  ///
  /// In zh, this message translates to:
  /// **'已逾期 {count} 分钟'**
  String viewScheduleMinutesOverdue(int count);

  /// No description provided for @viewScheduleSecondsAhead.
  ///
  /// In zh, this message translates to:
  /// **'{count} 秒后'**
  String viewScheduleSecondsAhead(int count);

  /// No description provided for @viewScheduleSecondsOverdue.
  ///
  /// In zh, this message translates to:
  /// **'已逾期 {count} 秒'**
  String viewScheduleSecondsOverdue(int count);

  /// No description provided for @viewScheduleDate.
  ///
  /// In zh, this message translates to:
  /// **'{date} {clock}'**
  String viewScheduleDate(String date, String clock);

  /// No description provided for @viewScheduleYearDate.
  ///
  /// In zh, this message translates to:
  /// **'{year}年{date} {clock}'**
  String viewScheduleYearDate(String year, String date, String clock);

  /// No description provided for @viewScheduleWeekdayName.
  ///
  /// In zh, this message translates to:
  /// **'{day, select, 1{一} 2{二} 3{三} 4{四} 5{五} 6{六} other{日}}'**
  String viewScheduleWeekdayName(String day);

  /// No description provided for @viewReplayDate.
  ///
  /// In zh, this message translates to:
  /// **'{month} 月 {day} 日'**
  String viewReplayDate(String month, int day);

  /// No description provided for @viewReplayHours.
  ///
  /// In zh, this message translates to:
  /// **'{count} 小时'**
  String viewReplayHours(int count);

  /// No description provided for @viewReplayHoursMinutes.
  ///
  /// In zh, this message translates to:
  /// **'{hours} 小时 {minutes} 分钟'**
  String viewReplayHoursMinutes(int hours, int minutes);

  /// No description provided for @viewUiHundredMillion.
  ///
  /// In zh, this message translates to:
  /// **'{value}亿'**
  String viewUiHundredMillion(String value);

  /// No description provided for @viewUiTenThousand.
  ///
  /// In zh, this message translates to:
  /// **'{value}万'**
  String viewUiTenThousand(String value);

  /// No description provided for @viewUiMillion.
  ///
  /// In zh, this message translates to:
  /// **'{value}M'**
  String viewUiMillion(String value);

  /// No description provided for @viewListSeparator.
  ///
  /// In zh, this message translates to:
  /// **'，'**
  String get viewListSeparator;

  /// No description provided for @viewAttachmentSeparator.
  ///
  /// In zh, this message translates to:
  /// **'、'**
  String get viewAttachmentSeparator;

  /// No description provided for @viewUiInvalidJsonOffset.
  ///
  /// In zh, this message translates to:
  /// **'不是合法的 JSON（{message}，第 {offset} 个字符附近）'**
  String viewUiInvalidJsonOffset(String message, int offset);

  /// No description provided for @viewUiUnavailableChart.
  ///
  /// In zh, this message translates to:
  /// **'图表无法显示'**
  String get viewUiUnavailableChart;

  /// No description provided for @viewUiUnavailableMetric.
  ///
  /// In zh, this message translates to:
  /// **'指标无法显示'**
  String get viewUiUnavailableMetric;

  /// No description provided for @viewUiUnavailableCompare.
  ///
  /// In zh, this message translates to:
  /// **'对比无法显示'**
  String get viewUiUnavailableCompare;

  /// No description provided for @viewUiUnavailableSteps.
  ///
  /// In zh, this message translates to:
  /// **'步骤无法显示'**
  String get viewUiUnavailableSteps;

  /// No description provided for @viewUiUnavailableCallout.
  ///
  /// In zh, this message translates to:
  /// **'提示无法显示'**
  String get viewUiUnavailableCallout;

  /// No description provided for @viewUiUnavailableOptions.
  ///
  /// In zh, this message translates to:
  /// **'选项无法显示'**
  String get viewUiUnavailableOptions;

  /// No description provided for @viewUiUnavailableConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认无法显示'**
  String get viewUiUnavailableConfirm;

  /// No description provided for @viewUiUnavailableText.
  ///
  /// In zh, this message translates to:
  /// **'文字无法显示'**
  String get viewUiUnavailableText;

  /// No description provided for @viewUiUnavailableGroup.
  ///
  /// In zh, this message translates to:
  /// **'这一组无法显示'**
  String get viewUiUnavailableGroup;

  /// No description provided for @viewUiUnavailablePart.
  ///
  /// In zh, this message translates to:
  /// **'这部分无法显示'**
  String get viewUiUnavailablePart;

  /// No description provided for @viewScheduleSingleNextLabel.
  ///
  /// In zh, this message translates to:
  /// **'自动化任务：{title}，下次{when}'**
  String viewScheduleSingleNextLabel(String title, String when);

  /// No description provided for @viewScheduleCountNextLabel.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个自动化任务，下次{when}'**
  String viewScheduleCountNextLabel(int count, String when);

  /// No description provided for @viewUiSkippedStepLabel.
  ///
  /// In zh, this message translates to:
  /// **'应该是字符串，这步已跳过'**
  String get viewUiSkippedStepLabel;

  /// No description provided for @viewLabeledValue.
  ///
  /// In zh, this message translates to:
  /// **'{label}：{value}'**
  String viewLabeledValue(String label, String value);

  /// No description provided for @viewDescribedValue.
  ///
  /// In zh, this message translates to:
  /// **'{label}，{description}'**
  String viewDescribedValue(String label, String description);

  /// No description provided for @viewSemicolonSeparator.
  ///
  /// In zh, this message translates to:
  /// **'；'**
  String get viewSemicolonSeparator;

  /// No description provided for @viewChartSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{kind}。{data}'**
  String viewChartSemantics(String kind, String data);

  /// No description provided for @viewMetricSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{label} {value}'**
  String viewMetricSemantics(String label, String value);

  /// No description provided for @viewMetricCaptionSemantics.
  ///
  /// In zh, this message translates to:
  /// **'{label} {value}，{caption}'**
  String viewMetricCaptionSemantics(String label, String value, String caption);

  /// No description provided for @viewScheduleZone.
  ///
  /// In zh, this message translates to:
  /// **'{rule}（{city} · {offset}）'**
  String viewScheduleZone(String rule, String city, String offset);

  /// No description provided for @viewContinueNotice.
  ///
  /// In zh, this message translates to:
  /// **'\n（{text}）\n'**
  String viewContinueNotice(String text);

  /// No description provided for @viewShareAltMarker.
  ///
  /// In zh, this message translates to:
  /// **'〔{alt}〕'**
  String viewShareAltMarker(String alt);

  /// No description provided for @viewModelThinkingXhigh.
  ///
  /// In zh, this message translates to:
  /// **'超高'**
  String get viewModelThinkingXhigh;

  /// No description provided for @viewUiDialectWebOnly.
  ///
  /// In zh, this message translates to:
  /// **'{kind} · 在网页版查看'**
  String viewUiDialectWebOnly(String kind);

  /// No description provided for @viewUiDialectKindInteractive.
  ///
  /// In zh, this message translates to:
  /// **'可交互内容'**
  String get viewUiDialectKindInteractive;

  /// No description provided for @viewUiDialectKindChart.
  ///
  /// In zh, this message translates to:
  /// **'图表'**
  String get viewUiDialectKindChart;

  /// No description provided for @viewUiDialectKindDiagram.
  ///
  /// In zh, this message translates to:
  /// **'示意图'**
  String get viewUiDialectKindDiagram;

  /// No description provided for @viewUiDialectKindImage.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get viewUiDialectKindImage;

  /// No description provided for @viewUiDialectKindAudio.
  ///
  /// In zh, this message translates to:
  /// **'音频'**
  String get viewUiDialectKindAudio;

  /// No description provided for @viewUiDialectKindVideo.
  ///
  /// In zh, this message translates to:
  /// **'视频'**
  String get viewUiDialectKindVideo;

  /// No description provided for @viewUiDialectKindScene.
  ///
  /// In zh, this message translates to:
  /// **'3D 场景'**
  String get viewUiDialectKindScene;

  /// No description provided for @viewUiDialectKindFiles.
  ///
  /// In zh, this message translates to:
  /// **'文件树'**
  String get viewUiDialectKindFiles;

  /// No description provided for @viewUiDialectKindMap.
  ///
  /// In zh, this message translates to:
  /// **'地图'**
  String get viewUiDialectKindMap;

  /// No description provided for @viewUiDialectKindOther.
  ///
  /// In zh, this message translates to:
  /// **'这部分'**
  String get viewUiDialectKindOther;

  /// No description provided for @viewUiDialectInvalid.
  ///
  /// In zh, this message translates to:
  /// **'这块内容在网页版查看'**
  String get viewUiDialectInvalid;

  /// No description provided for @viewUiDialectNote.
  ///
  /// In zh, this message translates to:
  /// **'在网页版查看'**
  String get viewUiDialectNote;

  /// No description provided for @wallpaperTitle.
  ///
  /// In zh, this message translates to:
  /// **'壁纸'**
  String get wallpaperTitle;

  /// No description provided for @wallpaperDefault.
  ///
  /// In zh, this message translates to:
  /// **'默认'**
  String get wallpaperDefault;

  /// No description provided for @wallpaperCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get wallpaperCustom;

  /// No description provided for @wallpaperFrame.
  ///
  /// In zh, this message translates to:
  /// **'调整位置'**
  String get wallpaperFrame;

  /// No description provided for @wallpaperBlur.
  ///
  /// In zh, this message translates to:
  /// **'模糊'**
  String get wallpaperBlur;

  /// No description provided for @wallpaperLighten.
  ///
  /// In zh, this message translates to:
  /// **'提亮'**
  String get wallpaperLighten;

  /// No description provided for @wallpaperDim.
  ///
  /// In zh, this message translates to:
  /// **'压暗'**
  String get wallpaperDim;

  /// No description provided for @wallpaperReplace.
  ///
  /// In zh, this message translates to:
  /// **'更换图片'**
  String get wallpaperReplace;

  /// No description provided for @wallpaperPreview.
  ///
  /// In zh, this message translates to:
  /// **'预览'**
  String get wallpaperPreview;

  /// No description provided for @wallpaperFooter.
  ///
  /// In zh, this message translates to:
  /// **'用于首页、对话和抽屉。提亮在浅色模式、压暗在深色模式下各自生效，文字始终清晰。PNG、JPEG、WebP，15 MB 以内'**
  String get wallpaperFooter;

  /// No description provided for @wallpaperChanged.
  ///
  /// In zh, this message translates to:
  /// **'壁纸已更换'**
  String get wallpaperChanged;

  /// No description provided for @wallpaperTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'图片超过 15 MB'**
  String get wallpaperTooLarge;

  /// No description provided for @wallpaperUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'支持 PNG、JPEG 和 WebP'**
  String get wallpaperUnsupported;

  /// No description provided for @wallpaperUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'无法读取这张图片'**
  String get wallpaperUnreadable;

  /// No description provided for @wallpaperUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'无法打开相册'**
  String get wallpaperUnavailable;

  /// No description provided for @wallpaperBroken.
  ///
  /// In zh, this message translates to:
  /// **'无法读取'**
  String get wallpaperBroken;

  /// No description provided for @wallpaperEditorHint.
  ///
  /// In zh, this message translates to:
  /// **'拖动、双指缩放'**
  String get wallpaperEditorHint;

  /// No description provided for @wallpaperEditorReset.
  ///
  /// In zh, this message translates to:
  /// **'复原'**
  String get wallpaperEditorReset;

  /// No description provided for @wallpaperSampleTitle.
  ///
  /// In zh, this message translates to:
  /// **'周末去海边'**
  String get wallpaperSampleTitle;

  /// No description provided for @wallpaperSampleStatus.
  ///
  /// In zh, this message translates to:
  /// **'刚刚'**
  String get wallpaperSampleStatus;

  /// No description provided for @wallpaperSampleQuestion.
  ///
  /// In zh, this message translates to:
  /// **'这周六适合去海边吗？'**
  String get wallpaperSampleQuestion;

  /// No description provided for @wallpaperSampleAnswer.
  ///
  /// In zh, this message translates to:
  /// **'适合。周六午后晴，风力 2 级，浪高不到半米，是这周最好的一天。'**
  String get wallpaperSampleAnswer;

  /// No description provided for @wallpaperSampleNote.
  ///
  /// In zh, this message translates to:
  /// **'傍晚降温明显，带一件薄外套。'**
  String get wallpaperSampleNote;

  /// No description provided for @wallpaperSampleTool.
  ///
  /// In zh, this message translates to:
  /// **'查了 3 个天气来源'**
  String get wallpaperSampleTool;

  /// No description provided for @searchKwWallpaper.
  ///
  /// In zh, this message translates to:
  /// **'背景,背景图,聊天背景,自定义背景,换背景,模糊,壁纸图片'**
  String get searchKwWallpaper;
}

class _L10nDelegate extends LocalizationsDelegate<L10n> {
  const _L10nDelegate();

  @override
  Future<L10n> load(Locale locale) {
    return SynchronousFuture<L10n>(lookupL10n(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_L10nDelegate old) => false;
}

L10n lookupL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return L10nEn();
    case 'zh':
      return L10nZh();
  }

  throw FlutterError(
    'L10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
