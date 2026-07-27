#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QString>
#include <QFile>
#include <QStandardPaths>
#include <QNetworkReply>
#include <QVariantList>
#include <QJsonArray>
#include <QNetworkAccessManager>
#include <QProcess>
#include <QTimer>
#include <functional>
#include <memory>

#include "BiliModels.h"

class VideoPartListModel;
class VideoListModel;
class CommentListModel;
class CommentReplyListModel;
class HotSearchModel;
class DynamicListModel;
class SearchResultModel;
class QStringListModel;
class FavoriteFolderModel;
class UpSeasonListModel;
class BiliNetwork;
class BiliCommentModule;
class BiliFavoriteModule;
class BiliFeedModule;
class BiliPlaybackModule;
class BiliSearchModule;
class BiliUpModule;
class BiliVideoModule;
class BiliViewerModule;
class BiliLoginModule;
class BiliHistoryModule;
class BiliSeasonModule;

class BiliController : public QObject {
  Q_OBJECT

  Q_PROPERTY(QObject *feed READ feed CONSTANT)
  Q_PROPERTY(QObject *comments READ comments CONSTANT)
  Q_PROPERTY(QObject *history READ history CONSTANT)
  Q_PROPERTY(QObject *search READ search CONSTANT)
  Q_PROPERTY(QObject *favorite READ favorite CONSTANT)
  Q_PROPERTY(QObject *auth READ auth CONSTANT)
  Q_PROPERTY(QObject *video READ video CONSTANT)
  Q_PROPERTY(QObject *playback READ playback CONSTANT)
  Q_PROPERTY(QObject *up READ up CONSTANT)
  Q_PROPERTY(QObject *season READ season CONSTANT)
  Q_PROPERTY(QObject *viewer READ viewer CONSTANT)

  // 视频详情
  Q_PROPERTY(QString videoTitle READ videoTitle NOTIFY videoDetailChanged)
  Q_PROPERTY(QString videoDesc READ videoDesc NOTIFY videoDetailChanged)
  Q_PROPERTY(QString videoPic READ videoPic NOTIFY videoDetailChanged)
  Q_PROPERTY(QString videoOwner READ videoOwner NOTIFY videoDetailChanged)
  Q_PROPERTY(
      QString videoOwnerFace READ videoOwnerFace NOTIFY videoDetailChanged)
  Q_PROPERTY(qint64 videoOwnerMid READ videoOwnerMid NOTIFY videoDetailChanged)
  Q_PROPERTY(QVariantList videoStaff READ videoStaff NOTIFY videoDetailChanged)
  Q_PROPERTY(QString videoViews READ videoViews NOTIFY videoDetailChanged)
  Q_PROPERTY(QString videoLikes READ videoLikes NOTIFY videoStatsChanged)
  Q_PROPERTY(QString videoCoins READ videoCoins NOTIFY videoStatsChanged)
  Q_PROPERTY(
      QString videoFavorites READ videoFavorites NOTIFY videoStatsChanged)
  Q_PROPERTY(QString videoDanmaku READ videoDanmaku NOTIFY videoDetailChanged)
  Q_PROPERTY(QString videoDuration READ videoDuration NOTIFY videoDetailChanged)
  Q_PROPERTY(QString playbackProgressText READ playbackProgressText NOTIFY playbackProgressChanged)
  Q_PROPERTY(int playbackProgressSeconds READ playbackProgressSeconds NOTIFY playbackProgressChanged)
  Q_PROPERTY(QString videoBvid READ videoBvid NOTIFY videoDetailChanged)
  Q_PROPERTY(qint64 videoCid READ videoCid NOTIFY videoDetailChanged)
  Q_PROPERTY(qint64 videoAid READ videoAid NOTIFY videoDetailChanged)
  Q_PROPERTY(QString videoPubDate READ videoPubDate NOTIFY videoDetailChanged)
  Q_PROPERTY(qint64 videoSeasonId READ videoSeasonId NOTIFY videoDetailChanged)
  Q_PROPERTY(QString videoSeasonTitle READ videoSeasonTitle NOTIFY videoDetailChanged)
  Q_PROPERTY(QString videoSeasonCover READ videoSeasonCover NOTIFY videoDetailChanged)
  Q_PROPERTY(qint64 videoSeasonMid READ videoSeasonMid NOTIFY videoDetailChanged)
  Q_PROPERTY(int videoSeasonTotal READ videoSeasonTotal NOTIFY videoDetailChanged)

  // 播放地址
  Q_PROPERTY(QString playUrl READ playUrl NOTIFY playUrlChanged)
  Q_PROPERTY(int playQuality READ playQuality NOTIFY playUrlChanged)
  Q_PROPERTY(QVariantList acceptQualities READ acceptQualities NOTIFY acceptQualitiesChanged)

  // 下载状态
  Q_PROPERTY(bool isDownloading READ isDownloading NOTIFY downloadStateChanged)
  Q_PROPERTY(double downloadProgress READ downloadProgress NOTIFY downloadStateChanged)
  Q_PROPERTY(QString downloadStatus READ downloadStatus NOTIFY downloadStateChanged)
  Q_PROPERTY(QString tempVideoPath READ tempVideoPath NOTIFY downloadStateChanged)
  Q_PROPERTY(QString tempAudioPath READ tempAudioPath NOTIFY downloadStateChanged)
  Q_PROPERTY(QString dashVideoUrl READ dashVideoUrl NOTIFY playUrlChanged)
  Q_PROPERTY(QString dashAudioUrl READ dashAudioUrl NOTIFY playUrlChanged)
  Q_PROPERTY(QVariantList subtitleList READ subtitleList NOTIFY subtitleListChanged)
  Q_PROPERTY(qint64 selectedSubtitleId READ selectedSubtitleId NOTIFY selectedSubtitleChanged)
  Q_PROPERTY(QString selectedSubtitleLabel READ selectedSubtitleLabel NOTIFY selectedSubtitleChanged)
  Q_PROPERTY(int subtitleFontSize READ subtitleFontSize NOTIFY subtitleStyleChanged)
  Q_PROPERTY(int subtitleMarginV READ subtitleMarginV NOTIFY subtitleStyleChanged)
  Q_PROPERTY(double subtitleSpacing READ subtitleSpacing NOTIFY subtitleStyleChanged)
  Q_PROPERTY(int subtitleWeight READ subtitleWeight NOTIFY subtitleStyleChanged)
  Q_PROPERTY(QString subtitleColorPreset READ subtitleColorPreset NOTIFY subtitleStyleChanged)
  Q_PROPERTY(bool subtitleOutlineEnabled READ subtitleOutlineEnabled NOTIFY subtitleStyleChanged)
  Q_PROPERTY(int subtitleOutlineWidth READ subtitleOutlineWidth NOTIFY subtitleStyleChanged)
  Q_PROPERTY(bool subtitleBackgroundEnabled READ subtitleBackgroundEnabled NOTIFY subtitleStyleChanged)
  Q_PROPERTY(double subtitleBackgroundOpacity READ subtitleBackgroundOpacity NOTIFY subtitleStyleChanged)
  Q_PROPERTY(bool videoCardOffscreenPlaceholderEnabled READ videoCardOffscreenPlaceholderEnabled NOTIFY preferenceSettingsChanged)
  Q_PROPERTY(bool videoDetailPreloadEnabled READ videoDetailPreloadEnabled NOTIFY preferenceSettingsChanged)
  Q_PROPERTY(bool defaultSubtitleEnabled READ defaultSubtitleEnabled NOTIFY preferenceSettingsChanged)

  // 登录状态
  Q_PROPERTY(bool loggedIn READ loggedIn NOTIFY loginStateChanged)

  // UP 主主页
  Q_PROPERTY(qint64 upUserMid READ upUserMid NOTIFY upUserChanged)
  Q_PROPERTY(QString upUserName READ upUserName NOTIFY upUserChanged)
  Q_PROPERTY(QString upUserFace READ upUserFace NOTIFY upUserChanged)
  Q_PROPERTY(int upUserLevel READ upUserLevel NOTIFY upUserChanged)
  Q_PROPERTY(int upUserFans READ upUserFans NOTIFY upUserChanged)
  Q_PROPERTY(int upUserFollowing READ upUserFollowing NOTIFY upUserChanged)
  Q_PROPERTY(QString upUserSign READ upUserSign NOTIFY upUserChanged)
  Q_PROPERTY(QString upOfficialLabel READ upOfficialLabel NOTIFY upUserChanged)
  Q_PROPERTY(QString upOfficialDesc READ upOfficialDesc NOTIFY upUserChanged)
  Q_PROPERTY(int upOfficialType READ upOfficialType NOTIFY upUserChanged)
  Q_PROPERTY(QString upVipLabel READ upVipLabel NOTIFY upUserChanged)
  Q_PROPERTY(bool upIsVip READ upIsVip NOTIFY upUserChanged)
  Q_PROPERTY(QString upNameplateName READ upNameplateName NOTIFY upUserChanged)
  Q_PROPERTY(QString upFansMedalName READ upFansMedalName NOTIFY upUserChanged)
  Q_PROPERTY(int upFansMedalLevel READ upFansMedalLevel NOTIFY upUserChanged)
  Q_PROPERTY(bool upIsFollowing READ upIsFollowing NOTIFY upFollowChanged)
  Q_PROPERTY(int upVideoTotal READ upVideoTotal NOTIFY upVideoTotalChanged)
  Q_PROPERTY(int upLastWatchedRank READ upLastWatchedRank NOTIFY upLastWatchedChanged)
  // UP 主合集筛选状态：当前选中的 season_id（0 表示“视频”全部投稿）
  Q_PROPERTY(qint64 upSelectedSeasonId READ upSelectedSeasonId NOTIFY upSelectedSeasonChanged)
  Q_PROPERTY(QString upSelectedSeasonName READ upSelectedSeasonName NOTIFY upSelectedSeasonChanged)
  Q_PROPERTY(bool upSelectedDynamic READ upSelectedDynamic NOTIFY upSelectedSeasonChanged)
  // 收藏/投币/点赞状态
  Q_PROPERTY(bool isFavorited READ isFavorited NOTIFY favoriteStatusChanged)
  Q_PROPERTY(bool isCoined READ isCoined NOTIFY coinStatusChanged)
  Q_PROPERTY(bool isLiked READ isLiked NOTIFY likeStatusChanged)
  Q_PROPERTY(bool isWatchLater READ isWatchLater NOTIFY watchLaterStatusChanged)
  Q_PROPERTY(QString userName READ userName NOTIFY loginStateChanged)
  Q_PROPERTY(QString userFace READ userFace NOTIFY loginStateChanged)
  Q_PROPERTY(QString qrcodeUrl READ qrcodeUrl NOTIFY qrcodeChanged)
  Q_PROPERTY(qint64 userId READ userId NOTIFY loginStateChanged)
  Q_PROPERTY(int userLevel READ userLevel NOTIFY loginStateChanged)
  Q_PROPERTY(int userExp READ userExp NOTIFY loginStateChanged)
  Q_PROPERTY(int userExpMin READ userExpMin NOTIFY loginStateChanged)
  Q_PROPERTY(int userExpNext READ userExpNext NOTIFY loginStateChanged)
  Q_PROPERTY(double userExpProgress READ userExpProgress NOTIFY loginStateChanged)
  Q_PROPERTY(double userCoins READ userCoins NOTIFY loginStateChanged)
  Q_PROPERTY(int userFans READ userFans NOTIFY loginStateChanged)
  Q_PROPERTY(int userFollowing READ userFollowing NOTIFY loginStateChanged)
  Q_PROPERTY(QString userSign READ userSign NOTIFY loginStateChanged)
  Q_PROPERTY(QString userVipLabel READ userVipLabel NOTIFY loginStateChanged)
  Q_PROPERTY(bool userIsVip READ userIsVip NOTIFY loginStateChanged)

  Q_PROPERTY(int seasonVideoTotal READ seasonVideoTotal NOTIFY seasonVideoTotalChanged)

  // 全局错误
  Q_PROPERTY(QString globalError READ globalError NOTIFY globalErrorChanged)
  Q_PROPERTY(bool isLoading READ isLoading NOTIFY isLoadingChanged)

public:
  explicit BiliController(QObject *parent = nullptr);
  ~BiliController();

  // Property getters
  QString videoTitle() const;
  QString videoDesc() const;
  QString videoPic() const;
  QString videoOwner() const;
  QString videoOwnerFace() const;
  qint64 videoOwnerMid() const;
  QVariantList videoStaff() const;
  QString videoViews() const;
  QString videoLikes() const;
  QString videoCoins() const;
  QString videoFavorites() const;
  QString videoDanmaku() const;
  QString videoDuration() const;
  QString playbackProgressText() const;
  int playbackProgressSeconds() const { return m_playbackProgressSeconds; }
  QString videoBvid() const;
  qint64 videoCid() const;
  qint64 videoAid() const;
  QString videoPubDate() const;
  qint64 videoSeasonId() const { return m_videoSeasonId; }
  QString videoSeasonTitle() const { return m_videoSeasonTitle; }
  QString videoSeasonCover() const { return m_videoSeasonCover; }
  qint64 videoSeasonMid() const { return m_videoSeasonMid; }
  int videoSeasonTotal() const { return m_videoSeasonTotal; }

  QString playUrl() const;
  int playQuality() const;
  QVariantList acceptQualities() const;
  QVector<int> acceptQualityValues() const { return m_acceptQualities; }

  bool isDownloading() const { return m_isDownloading; }
  double downloadProgress() const { return m_downloadProgress; }
  QString downloadStatus() const { return m_downloadStatus; }
  QString tempVideoPath() const { return m_tempVideoPath; }
  QString tempAudioPath() const { return m_tempAudioPath; }
  QString dashVideoUrl() const { return m_dashVideoUrl; }
  QString dashAudioUrl() const { return m_dashAudioUrl; }
  QVariantList subtitleList() const;
  QJsonArray subtitleItemValues() const { return m_subtitleItems; }
  qint64 selectedSubtitleId() const { return m_selectedSubtitleId; }
  QString selectedSubtitleLabel() const { return m_selectedSubtitleLabel; }
  int subtitleFontSize() const { return m_subtitleFontSize; }
  int subtitleMarginV() const { return m_subtitleMarginV; }
  double subtitleSpacing() const { return m_subtitleSpacing; }
  int subtitleWeight() const { return m_subtitleWeight; }
  QString subtitleColorPreset() const { return m_subtitleColorPreset; }
  bool subtitleOutlineEnabled() const { return m_subtitleOutlineEnabled; }
  int subtitleOutlineWidth() const { return m_subtitleOutlineWidth; }
  bool subtitleBackgroundEnabled() const { return m_subtitleBackgroundEnabled; }
  double subtitleBackgroundOpacity() const { return m_subtitleBackgroundOpacity; }
  bool videoCardOffscreenPlaceholderEnabled() const { return m_videoCardOffscreenPlaceholderEnabled; }
  bool videoDetailPreloadEnabled() const { return m_videoDetailPreloadEnabled; }
  bool defaultSubtitleEnabled() const { return m_defaultSubtitleEnabled; }

  bool loggedIn() const;
  qint64 upUserMid() const { return m_upUserMid; }
  QString upUserName() const { return m_upUserName; }
  QString upUserFace() const { return m_upUserFace; }
  int upUserLevel() const { return m_upUserLevel; }
  int upUserFans() const { return m_upUserFans; }
  int upUserFollowing() const { return m_upUserFollowing; }
  QString upUserSign() const { return m_upUserSign; }
  QString upOfficialLabel() const { return m_upOfficialLabel; }
  QString upOfficialDesc() const { return m_upOfficialDesc; }
  int upOfficialType() const { return m_upOfficialType; }
  QString upVipLabel() const { return m_upVipLabel; }
  bool upIsVip() const { return m_upIsVip; }
  QString upNameplateName() const { return m_upNameplateName; }
  QString upFansMedalName() const { return m_upFansMedalName; }
  int upFansMedalLevel() const { return m_upFansMedalLevel; }
  bool upIsFollowing() const { return m_upIsFollowing; }
  int upVideoTotal() const { return m_upVideoTotal; }
  int upLastWatchedRank() const;
  qint64 upSelectedSeasonId() const { return m_upSelectedSeasonId; }
  QString upSelectedSeasonName() const { return m_upSelectedSeasonName; }
  bool upSelectedDynamic() const { return m_upSelectedDynamic; }
  bool isFavorited() const { return m_isFavorited; }
  bool isCoined() const { return m_isCoined; }
  bool isLiked() const { return m_isLiked; }
  bool isWatchLater() const { return m_isWatchLater; }
  QString userName() const;
  QString userFace() const;
  QString qrcodeUrl() const;
  qint64 userId() const;
  int userLevel() const;
  int userExp() const;
  int userExpMin() const;
  int userExpNext() const;
  double userExpProgress() const;
  double userCoins() const;
  int userFans() const;
  int userFollowing() const;
  QString userSign() const;
  QString userVipLabel() const;
  bool userIsVip() const;

  int seasonVideoTotal() const { return m_seasonVideoTotal; }
  QString globalError() const;
  bool isLoading() const;
  QObject *feed() const;
  QObject *comments() const;
  QObject *history() const;
  QObject *search() const;
  QObject *favorite() const;
  BiliFavoriteModule *favoriteModule() const { return m_favoriteModule.get(); }
  BiliSearchModule *searchModule() const { return m_searchModule.get(); }
  QObject *auth() const;
  QObject *video() const;
  QObject *playback() const;
  QObject *up() const;
  QObject *season() const;
  QObject *viewer() const;
  BiliNetwork *network() const { return m_network; }
  VideoListModel *popularListModel() const { return m_popularModel; }
  VideoListModel *rankingListModel() const { return m_rankingModel; }
  HotSearchModel *hotSearchListModel() const { return m_hotSearchModel; }
  DynamicListModel *dynamicListModel() const { return m_dynamicModel; }
  DynamicListModel *upDynamicListModel() const { return m_upDynamicModel; }
  SearchResultModel *searchListModel() const { return m_searchModel; }
  QStringListModel *searchHistoryListModel() const { return m_searchHistoryModel; }
  CommentListModel *commentListModel() const { return m_commentModel; }
  CommentReplyListModel *commentReplyListModel() const { return m_commentReplyModel; }
  VideoListModel *recentHistoryListModel() const { return m_recentHistoryModel; }
  VideoListModel *watchLaterListModel() const { return m_watchLaterModel; }
  void clearLocalLoginState();
  void setIsLoading(bool loading);
  void setFavoriteState(bool favorited);
  void setCoinState(bool coined);
  void setLikeState(bool liked);
  void setWatchLaterState(bool watchLater);
  void clearPlayResult();
  void setPlayResult(const QString &playUrl, int playQuality,
                     const QString &dashVideoUrl,
                     const QString &dashAudioUrl);
  void clearAcceptQualities();
  void setAcceptQualities(const QVector<int> &qualities);
  void clearSubtitleItems();
  void setSubtitleItems(const QJsonArray &items);
  void clearSelectedSubtitle();
  void setSelectedSubtitle(qint64 subtitleId, const QString &label);
  bool applyDefaultSubtitleSelection();
  QString currentSubtitleRequestKey() const;
  QString selectedSubtitleAssUrl() const;
  void apiGet(const QString &path, const QMap<QString, QString> &params,
              std::function<void(const QJsonObject &)> onSuccess,
              std::function<void(int, const QString &)> onError = nullptr,
              bool withLoading = false);

  // ====== Q_INVOKABLE API 方法 ======

  // 短信登录与二维码登录通过 controller.auth.* 暴露

  Q_INVOKABLE void clearError();

  // 取消所有网络请求
  Q_INVOKABLE void cancelAll();

signals:
  void videoDetailChanged();
  void videoStatsChanged();
  void playbackProgressChanged();
  void playUrlChanged();
  void acceptQualitiesChanged();
  void subtitleListChanged();
  void selectedSubtitleChanged();
  void subtitleStyleChanged();
  void preferenceSettingsChanged();
  void loginStateChanged();
  void qrcodeChanged();
  void globalErrorChanged();
  void isLoadingChanged();
  void upUserChanged();
  void upFollowChanged();
  void upVideoTotalChanged();
  void upLastWatchedChanged();
  void upSelectedSeasonChanged();
  void seasonVideoTotalChanged();

  void toastMessage(const QString &message);
  void qrcodeLoginSuccess();
  void qrcodeNeedRefresh();
  void playbackReady(const QString &url);
  void downloadStateChanged();
  void favoriteStatusChanged();
  void coinStatusChanged();
  void likeStatusChanged();
  void watchLaterStatusChanged();
  void commentImageReadyForViewer(const QString &localPath);

private:
  friend class BiliFavoriteModule;
  friend class BiliPlaybackModule;
  friend class BiliUpModule;
  friend class BiliVideoModule;
  friend class BiliLoginModule;
  friend class BiliSeasonModule;

  void fetchUserInfo(qint64 mid);
  void setGlobalError(const QString &error);
  void setUpVideoTotal(int total);
  void setSeasonVideoTotal(int total);
  void loadLoginStatus();
  void saveLoginStatus();

  // 安全辅助：检查 this 是否仍然有效的回调包装
  template <typename Func> auto safeCallback(Func &&func);

  BiliNetwork *m_network;
  std::unique_ptr<BiliCommentModule> m_commentModule;
  std::unique_ptr<BiliFavoriteModule> m_favoriteModule;
  std::unique_ptr<BiliFeedModule> m_feedModule;
  std::unique_ptr<BiliPlaybackModule> m_playbackModule;
  std::unique_ptr<BiliSearchModule> m_searchModule;
  std::unique_ptr<BiliUpModule> m_upModule;
  std::unique_ptr<BiliVideoModule> m_videoModule;
  std::unique_ptr<BiliViewerModule> m_viewerModule;
  std::unique_ptr<BiliLoginModule> m_loginModule;
  std::unique_ptr<BiliHistoryModule> m_historyModule;
  std::unique_ptr<BiliSeasonModule> m_seasonModule;

  VideoItem m_currentVideo;
  qint64 m_playbackProgressCid = 0;
  int m_playbackProgressSeconds = 0;
  qint64 m_videoSeasonId = 0;
  QString m_videoSeasonTitle;
  QString m_videoSeasonCover;
  qint64 m_videoSeasonMid = 0;
  int m_videoSeasonTotal = 0;

  struct VideoDetailSnapshot {
    VideoItem video;
    qint64 playbackProgressCid = 0;
    int playbackProgressSeconds = 0;
    qint64 seasonId = 0;
    QString seasonTitle;
    QString seasonCover;
    qint64 seasonMid = 0;
    int seasonTotal = 0;
    QVector<VideoPartItem> parts;
    QVector<int> acceptQualities;
    bool isFavorited = false;
    bool isCoined = false;
    bool isLiked = false;
    bool isWatchLater = false;
    QJsonArray subtitleItems;
    qint64 selectedSubtitleId = 0;
    QString selectedSubtitleLabel;
    bool subtitleSelectionOverridden = false;
    bool valid = false;
  };

  QHash<QString, VideoDetailSnapshot> m_videoDetailSnapshots;
  QSet<QString> m_videoDetailPreloadingBvids;

  QString m_playUrl;
  int m_playQuality;
  QVector<int> m_acceptQualities;

  // 下载状态
  bool m_isDownloading;
  double m_downloadProgress;
  QString m_downloadStatus;
  QString m_tempVideoPath;
  QString m_tempAudioPath;
  QString m_tempSubtitlePath;
  QString m_dashVideoUrl;
  QString m_dashAudioUrl;
  QJsonArray m_subtitleItems;
  QString m_subtitleItemsKey;
  QString m_subtitleItemsLoadingKey;
  qint64 m_selectedSubtitleId = 0;
  QString m_selectedSubtitleLabel;
  int m_subtitleFontSize = 10;
  int m_subtitleMarginV = 10;
  double m_subtitleSpacing = 2.0;
  int m_subtitleWeight = 700;
  QString m_subtitleColorPreset = "white";
  bool m_subtitleOutlineEnabled = false;
  int m_subtitleOutlineWidth = 1;
  bool m_subtitleBackgroundEnabled = false;
  double m_subtitleBackgroundOpacity = 0.5;
  bool m_videoCardOffscreenPlaceholderEnabled = false;
  bool m_videoDetailPreloadEnabled = false;
  bool m_defaultSubtitleEnabled = false;
  bool m_subtitleSelectionOverridden = false;
  QPointer<QNetworkReply> m_downloadReply;
  QPointer<QProcess> m_externalPlayerProcess;

  bool m_loggedIn;
  bool m_isFavorited;
  bool m_isCoined;
  bool m_isLiked;
  bool m_isWatchLater;
  QString m_userName;
  QString m_userFace;
  QString m_qrcodeUrl;
  QString m_qrcodeKey;
  qint64 m_loginInfoUpdatedAtMs = 0;
  qint64 m_userInfoUpdatedAtMs = 0;
  bool m_loginInfoRefreshPending = false;
  bool m_userInfoRefreshPending = false;
  // ====== 短信登录（bili-login 服务） ======
  // bili-login 二进制进程（可为空：startDetached 场景）
  QPointer<QProcess> m_smsLoginProcess;
  QPointer<QTimer> m_smsPollTimer;
  QNetworkAccessManager *m_smsNam = nullptr;
  bool m_smsPolling = false;
  bool m_smsImporting = false;
  QString m_smsLastError;

  // 用户详细信息
  qint64 m_userId;
  int m_userLevel;
  int m_userExp;
  int m_userExpMin;
  int m_userExpNext;
  double m_userCoins;
  int m_userFans;
  int m_userFollowing;
  QString m_userSign;
  QString m_userVipLabel;
  bool m_userIsVip;

  QString m_globalError;
  bool m_isLoading;

  // 加载计数器（多个异步请求同时进行时正确管理 isLoading）
  int m_loadingCount;

  VideoListModel *m_popularModel;
  VideoListModel *m_rankingModel;
  SearchResultModel *m_searchModel;
  SearchResultModel *m_upSearchModel;
  CommentListModel *m_commentModel;
  CommentReplyListModel *m_commentReplyModel;
  HotSearchModel *m_hotSearchModel;
  DynamicListModel *m_dynamicModel;
  DynamicListModel *m_upDynamicModel;
  VideoPartListModel *m_videoPartModel;
  QStringListModel *m_searchHistoryModel;

  FavoriteFolderModel *m_favoriteFolderModel;
  VideoListModel *m_favoriteItemModel;
  VideoListModel *m_recentHistoryModel;
  VideoListModel *m_watchLaterModel;
  VideoListModel *m_upVideoModel;
  VideoListModel *m_seasonVideoModel;
  VideoListModel *m_relatedVideoModel;
  UpSeasonListModel *m_upSeasonModel = nullptr;

  // UP 主主页数据
  qint64 m_upUserMid = 0;
  QString m_upUserName;
  QString m_upUserFace;
  int m_upUserLevel = 0;
  int m_upUserFans = 0;
  int m_upUserFollowing = 0;
  QString m_upUserSign;
  QString m_upOfficialLabel;
  QString m_upOfficialDesc;
  int m_upOfficialType = -1;
  QString m_upVipLabel;
  bool m_upIsVip = false;
  QString m_upNameplateName;
  QString m_upFansMedalName;
  int m_upFansMedalLevel = 0;
  bool m_upIsFollowing = false;
  int m_upVideoTotal = 0;
  // 投稿分页/游标等状态已下沉到 BiliUpModule
  // UP 主合集筛选状态
  qint64 m_upSelectedSeasonId = 0;
  QString m_upSelectedSeasonName;
  bool m_upSelectedIsSeries = false;
  bool m_upSelectedDynamic = false;
  int m_upSeasonVideoPage = 1;
  bool m_upSeasonVideoHasMore = true;
  // 合集浏览分页状态已下沉到 BiliSeasonModule，这里只留 seasonVideoTotal
  int m_seasonVideoTotal = 0;
  QString m_videoDetailLoadingBvid;
  QString m_relatedVideoBvid;
  QString m_relatedVideoLoadingBvid;
  QString m_playUrlLoadingKey;
  QString m_acceptQualitiesLoadingKey;

  struct DashResult {
    QString videoUrl;
    QString audioUrl;
    int finalQuality = 0;
  };

  void updateAcceptQualities(const QJsonObject &data);
  DashResult pickDashUrls(const QJsonObject &data, int requestedQuality) const;
  QString pickMp4Url(const QJsonObject &data) const;

  void startDownloadTask(const QString &videoUrl, const QString &audioUrl,
                         const QString &videoPath, const QString &audioPath,
                         int finalQuality, bool playAfter,
                         const QString &successToastPrefix = QString(),
                         const QString &errorToastPrefix = QStringLiteral("下载失败："),
                         const QString &subtitleUrl = QString(),
                         const QString &subtitlePath = QString());

  // 标记对象是否正在销毁
  bool m_destroying;
};
