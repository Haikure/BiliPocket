#include "BiliController.h"
#include "BiliModels.h"
#include "BiliNetwork.h"
#include "modules/comment/BiliCommentModule.h"
#include "modules/favorite/BiliFavoriteModule.h"
#include "modules/feed/BiliFeedModule.h"
#include "modules/history/BiliHistoryModule.h"
#include "modules/login/BiliLoginModule.h"
#include "modules/playback/BiliPlaybackModule.h"
#include "modules/search/BiliSearchModule.h"
#include "modules/season/BiliSeasonModule.h"
#include "modules/up/BiliUpModule.h"
#include "modules/video/BiliVideoModule.h"
#include "modules/viewer/BiliViewerModule.h"

#include <QVariantMap>

#include <QDateTime>
#include <QSettings>
#include <QStringListModel>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QDebug>
#include <QNetworkReply>
#include <QTcpSocket>

namespace {

bool isChineseSubtitleItem(const QJsonObject &item) {
  const QString lan = item.value("lan").toString().toLower();
  const QString lanDoc = item.value("lan_doc").toString().toLower();
  const QString combined = lan + " " + lanDoc;
  return combined.contains("中文") || combined.contains("简体") ||
         combined.contains("繁体") || combined.contains("zh") ||
         combined.contains("chinese");
}

qint64 subtitleItemId(const QJsonObject &item) {
  qint64 id = item.value("id").toVariant().toLongLong();
  if (id <= 0) {
    id = item.value("subtitle_id").toVariant().toLongLong();
  }
  if (id <= 0) {
    id = item.value("id_str").toString().toLongLong();
  }
  return id;
}

bool hasSubtitleUrl(const QJsonObject &item) {
  QString url = item.value("subtitle_url").toString().trimmed();
  if (url.isEmpty()) {
    url = item.value("url").toString().trimmed();
  }
  return !url.isEmpty();
}

QString subtitleItemUrl(const QJsonObject &item) {
  QString url = item.value("subtitle_url").toString().trimmed();
  if (url.isEmpty()) {
    url = item.value("url").toString().trimmed();
  }
  return url;
}

QString subtitleItemLabel(const QJsonObject &item, int index) {
  QString label = item.value("lan_doc").toString().trimmed();
  if (label.isEmpty()) {
    label = item.value("lan").toString().trimmed();
  }
  if (label.isEmpty()) {
    label = QString("字幕%1").arg(index + 1);
  }
  return label;
}

} // namespace

BiliController::BiliController(QObject *parent)
    : QObject(parent), m_network(BiliNetwork::instance()),
      m_commentModule(std::make_unique<BiliCommentModule>(this)),
      m_favoriteModule(std::make_unique<BiliFavoriteModule>(this)),
      m_feedModule(std::make_unique<BiliFeedModule>(this)),
      m_playbackModule(std::make_unique<BiliPlaybackModule>(this)),
      m_searchModule(std::make_unique<BiliSearchModule>(this)),
      m_upModule(std::make_unique<BiliUpModule>(this)),
      m_videoModule(std::make_unique<BiliVideoModule>(this)),
      m_viewerModule(std::make_unique<BiliViewerModule>(this)),
      m_loginModule(std::make_unique<BiliLoginModule>(this)),
      m_historyModule(std::make_unique<BiliHistoryModule>(this)),
      m_seasonModule(std::make_unique<BiliSeasonModule>(this)),
      m_playQuality(64), m_isDownloading(false),
      m_downloadProgress(0), m_loggedIn(false), m_isFavorited(false), m_isCoined(false), m_isLiked(false), m_isWatchLater(false),
      m_userName(""), m_userFace(""), m_qrcodeUrl(""), m_qrcodeKey(""),
      m_userId(0), m_userLevel(0), m_userExp(0), m_userExpMin(0), m_userExpNext(0), m_userCoins(0), m_userFans(0),
      m_userFollowing(0), m_userSign(""), m_userVipLabel(""),
      m_userIsVip(false), m_globalError(""),
      m_isLoading(false), m_loadingCount(0),
      m_popularModel(new VideoListModel(this)),
      m_rankingModel(new VideoListModel(this)),
      m_searchModel(new SearchResultModel(this)),
      m_upSearchModel(new SearchResultModel(this)),
      m_commentModel(new CommentListModel(this)),
      m_commentReplyModel(new CommentReplyListModel(this)),
      m_hotSearchModel(new HotSearchModel(this)),
      m_dynamicModel(new DynamicListModel(this)),
      m_upDynamicModel(new DynamicListModel(this)),
      m_videoPartModel(new VideoPartListModel(this)),
      m_searchHistoryModel(new QStringListModel(this)),
      m_favoriteFolderModel(new FavoriteFolderModel(this)),
      m_favoriteItemModel(new VideoListModel(this)),
      m_recentHistoryModel(new VideoListModel(this)),
      m_watchLaterModel(new VideoListModel(this)),
      m_upVideoModel(new VideoListModel(this)),
      m_seasonVideoModel(new VideoListModel(this)),
      m_relatedVideoModel(new VideoListModel(this)),
      m_upSeasonModel(new UpSeasonListModel(this)),
      m_destroying(false) {
  connect(m_network, &BiliNetwork::networkError, this,
          [this](const QString &msg) {
            if (!m_destroying)
              setGlobalError(msg);
          });

  // 默认可用清晰度
  m_acceptQualities = {16, 32, 64};

  loadLoginStatus();
  m_searchModule->loadSearchHistory();
  // 加载字幕样式设置
  QSettings settings("BiliPocket", "BiliPlugin");
  m_subtitleFontSize = settings.value("subtitleFontSize", m_subtitleFontSize).toInt();
  m_subtitleMarginV = settings.value("subtitleMarginV", m_subtitleMarginV).toInt();
  m_subtitleSpacing = settings.value("subtitleSpacing", m_subtitleSpacing).toDouble();
  m_subtitleWeight = settings.value("subtitleWeight",
                                    settings.value("subtitleBold", m_subtitleWeight)).toInt();
  m_subtitleColorPreset = settings.value("subtitleColorPreset", m_subtitleColorPreset).toString();
  m_subtitleOutlineEnabled = settings.value("subtitleOutlineEnabled", m_subtitleOutlineEnabled).toBool();
  m_subtitleOutlineWidth = settings.value("subtitleOutlineWidth", m_subtitleOutlineWidth).toInt();
  m_subtitleBackgroundEnabled = settings.value("subtitleBackgroundEnabled", m_subtitleBackgroundEnabled).toBool();
  m_subtitleBackgroundOpacity = settings.value("subtitleBackgroundOpacity", m_subtitleBackgroundOpacity).toDouble();
  m_videoCardOffscreenPlaceholderEnabled = settings.value("videoCardOffscreenPlaceholderEnabled", m_videoCardOffscreenPlaceholderEnabled).toBool();
  m_videoDetailPreloadEnabled = settings.value("videoDetailPreloadEnabled", m_videoDetailPreloadEnabled).toBool();
  m_defaultSubtitleEnabled = settings.value("defaultSubtitleEnabled", m_defaultSubtitleEnabled).toBool();
}

BiliController::~BiliController() {
  m_destroying = true;

  // 停止短信登录轮询与进程
  if (m_loginModule) m_loginModule->stopSmsLogin();

  // 取消所有正在进行的请求，防止回调访问已销毁的对象
  if (m_network) {
    m_network->cancelAllRequests();
  }
}

// ====== 加载状态管理（引用计数） ======

void BiliController::setIsLoading(bool loading) {
  if (loading) {
    m_loadingCount++;
  } else {
    m_loadingCount = qMax(0, m_loadingCount - 1);
  }

  bool newLoading = m_loadingCount > 0;
  if (m_isLoading != newLoading) {
    m_isLoading = newLoading;
    emit isLoadingChanged();
  }
}

// ====== Properties ======

QString BiliController::videoTitle() const { return m_currentVideo.title; }
QString BiliController::videoDesc() const { return m_currentVideo.desc; }
QString BiliController::videoPic() const { return m_currentVideo.pic; }
QString BiliController::videoOwner() const { return m_currentVideo.ownerName; }
QString BiliController::videoOwnerFace() const {
  return m_currentVideo.ownerFace;
}
qint64 BiliController::videoOwnerMid() const {
  return m_currentVideo.ownerMid;
}
QVariantList BiliController::videoStaff() const {
  QVariantList list;
  auto appendStaff = [&list](qint64 mid, const QString &name, const QString &face,
                             const QString &title) {
    if (mid <= 0 || name.isEmpty()) return;
    QVariantMap item;
    item["mid"] = mid;
    item["name"] = name;
    item["face"] = face;
    item["title"] = title;
    list.append(item);
  };

  if (!m_currentVideo.staff.isEmpty()) {
    for (const VideoStaffItem &staff : m_currentVideo.staff) {
      appendStaff(staff.mid, staff.name, staff.face, staff.title);
    }
  } else {
    appendStaff(m_currentVideo.ownerMid, m_currentVideo.ownerName,
                m_currentVideo.ownerFace, QString());
  }
  return list;
}
QString BiliController::videoViews() const {
  return VideoListModel::formatCount(m_currentVideo.views);
}
QString BiliController::videoLikes() const {
  return VideoListModel::formatCount(m_currentVideo.likes);
}
QString BiliController::videoCoins() const {
  return VideoListModel::formatCount(m_currentVideo.coins);
}
QString BiliController::videoFavorites() const {
  return VideoListModel::formatCount(m_currentVideo.favorites);
}
QString BiliController::videoDanmaku() const {
  return VideoListModel::formatCount(m_currentVideo.danmaku);
}
QString BiliController::videoDuration() const {
  return VideoListModel::formatDuration(m_currentVideo.duration);
}
QString BiliController::playbackProgressText() const {
  int progress = 0;
  if (m_playbackProgressCid > 0 && m_playbackProgressCid == m_currentVideo.cid && m_playbackProgressSeconds > 0) {
    progress = m_playbackProgressSeconds;
  }
  return QString("%1 / %2").arg(VideoListModel::formatDuration(progress), VideoListModel::formatDuration(m_currentVideo.duration));
}
QString BiliController::videoBvid() const { return m_currentVideo.bvid; }
qint64 BiliController::videoCid() const { return m_currentVideo.cid; }
qint64 BiliController::videoAid() const { return m_currentVideo.aid; }
QString BiliController::videoPubDate() const {
  if (m_currentVideo.pubdate <= 0) return "未知日期";
  QDateTime dt = QDateTime::fromSecsSinceEpoch(m_currentVideo.pubdate);
  return dt.toString("yyyy-MM-dd HH:mm");
}

QString BiliController::playUrl() const { return m_playUrl; }
int BiliController::playQuality() const { return m_playQuality; }

QVariantList BiliController::subtitleList() const {
  QVariantList list;
  for (const QJsonValue &v : m_subtitleItems) {
    if (v.isObject()) {
      const QJsonObject item = v.toObject();
      QVariantMap map = item.toVariantMap();
      map["subtitleId"] = subtitleItemId(item);
      list << map;
    }
  }
  return list;
}

QVariantList BiliController::acceptQualities() const {
  QVariantList list;
  for (int q : m_acceptQualities) {
    list << q;
  }
  return list;
}

bool BiliController::loggedIn() const { return m_loggedIn; }
QString BiliController::userName() const { return m_userName; }
QString BiliController::userFace() const { return m_userFace; }
QString BiliController::qrcodeUrl() const { return m_qrcodeUrl; }
qint64 BiliController::userId() const { return m_userId; }
int BiliController::userLevel() const { return m_userLevel; }
int BiliController::userExp() const { return m_userExp; }
int BiliController::userExpMin() const { return m_userExpMin; }
int BiliController::userExpNext() const { return m_userExpNext; }
double BiliController::userExpProgress() const {
  if (m_userExpNext > 0 && m_userExp >= 0) {
    double progress = m_userExp * 1.0 / m_userExpNext;
    return qBound(0.0, progress, 1.0);
  }
  return 0.0;
}
double BiliController::userCoins() const { return m_userCoins; }
int BiliController::userFans() const { return m_userFans; }
int BiliController::userFollowing() const { return m_userFollowing; }
QString BiliController::userSign() const { return m_userSign; }
QString BiliController::userVipLabel() const { return m_userVipLabel; }
bool BiliController::userIsVip() const { return m_userIsVip; }

QString BiliController::globalError() const { return m_globalError; }
bool BiliController::isLoading() const { return m_isLoading; }

void BiliController::setGlobalError(const QString &error) {
  if (m_globalError != error) {
    m_globalError = error;
    emit globalErrorChanged();
  }
}

void BiliController::setFavoriteState(bool favorited) {
  if (m_isFavorited == favorited) return;
  m_isFavorited = favorited;
  emit favoriteStatusChanged();
}

void BiliController::setCoinState(bool coined) {
  if (m_isCoined == coined) return;
  m_isCoined = coined;
  emit coinStatusChanged();
}

void BiliController::setLikeState(bool liked) {
  if (m_isLiked == liked) return;
  m_isLiked = liked;
  emit likeStatusChanged();
}

void BiliController::setWatchLaterState(bool watchLater) {
  if (m_isWatchLater == watchLater) return;
  m_isWatchLater = watchLater;
  emit watchLaterStatusChanged();
}

void BiliController::clearPlayResult() {
  if (m_playUrl.isEmpty() && m_dashVideoUrl.isEmpty() &&
      m_dashAudioUrl.isEmpty()) return;
  m_playUrl.clear();
  m_dashVideoUrl.clear();
  m_dashAudioUrl.clear();
  emit playUrlChanged();
}

void BiliController::setPlayResult(const QString &playUrl, int playQuality,
                                   const QString &dashVideoUrl,
                                   const QString &dashAudioUrl) {
  if (m_playUrl == playUrl && m_playQuality == playQuality &&
      m_dashVideoUrl == dashVideoUrl && m_dashAudioUrl == dashAudioUrl) {
    return;
  }
  m_playUrl = playUrl;
  m_playQuality = playQuality;
  m_dashVideoUrl = dashVideoUrl;
  m_dashAudioUrl = dashAudioUrl;
  emit playUrlChanged();
}

void BiliController::clearAcceptQualities() {
  if (m_acceptQualities.isEmpty()) return;
  m_acceptQualities.clear();
  emit acceptQualitiesChanged();
}

void BiliController::setAcceptQualities(const QVector<int> &qualities) {
  if (qualities.isEmpty() || m_acceptQualities == qualities) return;
  m_acceptQualities = qualities;
  emit acceptQualitiesChanged();
}

void BiliController::clearSubtitleItems() {
  m_subtitleItemsKey.clear();
  m_subtitleItemsLoadingKey.clear();
  setSubtitleItems(QJsonArray());
}

void BiliController::setSubtitleItems(const QJsonArray &items) {
  if (m_subtitleItems == items) return;
  m_subtitleItems = items;
  emit subtitleListChanged();
  applyDefaultSubtitleSelection();
}

void BiliController::clearSelectedSubtitle() {
  setSelectedSubtitle(0, QString());
  m_subtitleSelectionOverridden = false;
}

void BiliController::setSelectedSubtitle(qint64 subtitleId,
                                         const QString &label) {
  if (m_selectedSubtitleId == subtitleId && m_selectedSubtitleLabel == label) return;
  m_selectedSubtitleId = subtitleId;
  m_selectedSubtitleLabel = label;
  emit selectedSubtitleChanged();
}

bool BiliController::applyDefaultSubtitleSelection() {
  if (!m_defaultSubtitleEnabled || m_subtitleSelectionOverridden ||
      m_selectedSubtitleId > 0 || m_subtitleItems.isEmpty()) {
    return false;
  }

  for (int i = 0; i < m_subtitleItems.size(); ++i) {
    const QJsonObject item = m_subtitleItems.at(i).toObject();
    if (!isChineseSubtitleItem(item) || !hasSubtitleUrl(item)) {
      continue;
    }
    const qint64 subtitleId = subtitleItemId(item);
    if (subtitleId <= 0) {
      continue;
    }
    setSelectedSubtitle(subtitleId, subtitleItemLabel(item, i));
    return true;
  }
  return false;
}

QString BiliController::currentSubtitleRequestKey() const {
  if (m_currentVideo.aid <= 0 || m_currentVideo.cid <= 0) {
    return QString();
  }
  return QString("%1:%2:%3")
      .arg(m_currentVideo.bvid)
      .arg(m_currentVideo.aid)
      .arg(m_currentVideo.cid);
}

QString BiliController::selectedSubtitleAssUrl() const {
  if (m_selectedSubtitleId <= 0) {
    return QString();
  }

  QUrl subtitleUrl(m_network->apiBase() + "/video/subtitle/ass/file");
  QUrlQuery query;
  query.addQueryItem("aid", QString::number(m_currentVideo.aid));
  query.addQueryItem("cid", QString::number(m_currentVideo.cid));
  query.addQueryItem("bvid", m_currentVideo.bvid);
  query.addQueryItem("sid", QString::number(m_selectedSubtitleId));
  for (const QJsonValue &value : m_subtitleItems) {
    const QJsonObject item = value.toObject();
    if (subtitleItemId(item) == m_selectedSubtitleId) {
      const QString url = subtitleItemUrl(item);
      if (!url.isEmpty()) {
        query.addQueryItem("subtitle_url", url);
      }
      break;
    }
  }
  query.addQueryItem("font_size", QString::number(m_subtitleFontSize));
  query.addQueryItem("margin_v", QString::number(m_subtitleMarginV));
  query.addQueryItem("spacing", QString::number(m_subtitleSpacing, 'f', 2));
  query.addQueryItem("weight", QString::number(m_subtitleWeight));
  query.addQueryItem("color_preset", m_subtitleColorPreset);
  query.addQueryItem("outline_enabled", m_subtitleOutlineEnabled ? "1" : "0");
  query.addQueryItem("outline_width", QString::number(m_subtitleOutlineWidth));
  query.addQueryItem("background_enabled", m_subtitleBackgroundEnabled ? "1" : "0");
  query.addQueryItem("background_opacity", QString::number(m_subtitleBackgroundOpacity, 'f', 2));
  subtitleUrl.setQuery(query);
  return subtitleUrl.toString();
}

// ====== Models ======

QObject *BiliController::feed() const { return m_feedModule.get(); }
QObject *BiliController::comments() const { return m_commentModule.get(); }
QObject *BiliController::history() const { return m_historyModule.get(); }
QObject *BiliController::search() const { return m_searchModule.get(); }
QObject *BiliController::favorite() const { return m_favoriteModule.get(); }
QObject *BiliController::auth() const { return m_loginModule.get(); }
QObject *BiliController::video() const { return m_videoModule.get(); }
QObject *BiliController::playback() const { return m_playbackModule.get(); }
QObject *BiliController::up() const { return m_upModule.get(); }
QObject *BiliController::season() const { return m_seasonModule.get(); }
QObject *BiliController::viewer() const { return m_viewerModule.get(); }

void BiliController::clearError() { setGlobalError(""); }

void BiliController::cancelAll() {
  // 先落定状态再 abort：abort() 会同步触发 onError，避免取消被误报为失败

  // 立即重置前端可见加载状态，避免取消后卡在 loading UI
  m_loadingCount = 0;
  m_videoDetailLoadingBvid.clear();
  m_videoDetailPreloadingBvids.clear();
  m_playUrlLoadingKey.clear();
  m_acceptQualitiesLoadingKey.clear();
  m_favoriteModule->resetLoadingState();
  m_commentModule->resetReplyState();
  if (m_isLoading) {
    m_isLoading = false;
    emit isLoadingChanged();
  }

  // 重置各模型加载状态，避免它们因 abort 后未恢复而阻塞后续操作
  if (m_popularModel) m_popularModel->setLoading(false);
  if (m_rankingModel) m_rankingModel->setLoading(false);
  if (m_searchModel) m_searchModel->setLoading(false);
  if (m_commentModel) m_commentModel->setLoading(false);
  if (m_commentReplyModel) m_commentReplyModel->setLoading(false);
  if (m_hotSearchModel) m_hotSearchModel->setLoading(false);
  if (m_dynamicModel) m_dynamicModel->setLoading(false);
  if (m_upDynamicModel) m_upDynamicModel->setLoading(false);
  if (m_favoriteFolderModel) m_favoriteFolderModel->setLoading(false);
  if (m_favoriteItemModel) m_favoriteItemModel->setLoading(false);
  if (m_recentHistoryModel) m_recentHistoryModel->setLoading(false);
  if (m_watchLaterModel) m_watchLaterModel->setLoading(false);
  if (m_upVideoModel) m_upVideoModel->setLoading(false);
  if (m_seasonVideoModel) m_seasonVideoModel->setLoading(false);
  if (m_upSeasonModel) m_upSeasonModel->setLoading(false);

  // 下载中也允许中止显示状态
  if (m_isDownloading) {
    m_isDownloading = false;
    m_downloadProgress = 0;
    m_downloadStatus.clear();
    emit downloadStateChanged();
  }

  if (m_network) {
    m_network->cancelAllRequests();
  }

  emit toastMessage("已取消当前请求");
}


// ====== 登录状态持久化 ======

void BiliController::loadLoginStatus() {
  // 登录状态由 Go 服务器统一维护，这里只做一次后台校验
  QTimer::singleShot(0, this, [this]() { m_loginModule->checkLoginStatus(); });
}

void BiliController::saveLoginStatus() {
  // Cookie 由 Go 服务器统一处理，客户端不再持久化
}

void BiliController::clearLocalLoginState() {
  m_loggedIn = false;
  m_userName = "";
  m_userFace = "";
  m_userId = 0;
  m_userLevel = 0;
  m_userExp = 0;
  m_userExpMin = 0;
  m_userExpNext = 0;
  m_userCoins = 0;
  m_userFans = 0;
  m_userFollowing = 0;
  m_userSign = "";
  m_userVipLabel = "";
  m_userIsVip = false;
  m_qrcodeUrl = "";
  m_qrcodeKey = "";
  m_loginInfoUpdatedAtMs = 0;
  m_userInfoUpdatedAtMs = 0;
  m_loginInfoRefreshPending = false;
  m_userInfoRefreshPending = false;
  emit qrcodeChanged();
  setFavoriteState(false);
  setCoinState(false);
  setLikeState(false);
  setWatchLaterState(false);
  emit loginStateChanged();
}

// ====== QML API delegates ======

void BiliController::fetchUserInfo(qint64 mid) { m_loginModule->fetchUserInfo(mid); }

void BiliController::setSeasonVideoTotal(int total) {
  total = qMax(0, total);
  if (m_seasonVideoTotal == total) return;
  m_seasonVideoTotal = total;
  emit seasonVideoTotalChanged();
}

void BiliController::setUpVideoTotal(int total) {
  total = qMax(0, total);
  if (m_upVideoTotal == total) return;
  m_upVideoTotal = total;
  emit upVideoTotalChanged();
}

// 状态在 BiliUpModule，这里只转调
int BiliController::upLastWatchedRank() const {
  return m_upModule->lastWatchedRank();
}

#include "BiliController.h"
#include "BiliImageProvider.h"
#include "BiliModels.h"
#include "BiliNetwork.h"

#include <QDir>
#include <QFile>
#include <QMutex>
#include <QMutexLocker>
#include <QProcess>
#include <QThread>
#include <QtQml>
#include <functional>
#include <memory>
#include <signal.h>

static QQmlEngine *s_engine = nullptr;

extern "C" {

// 全局变量
static BiliImageProvider *s_imageProvider = nullptr;
static QMutex s_providerMutex;
static QProcess *s_apiServerProcess = nullptr;
static const QString API_SERVER_PATH =
    "/userdisk/PenMods/plugins/bili_plugin/";
static const QString API_SERVER_EXEC = "server"; // Go 编译的可执行文件名

} // extern "C"

namespace {

// terminate 后由 finished -> deleteLater 回收；3 秒后外部 shell 兜底 SIGKILL
void detachAndStopProcess(QProcess *proc) {
  if (!proc) return;
  proc->disconnect();
  if (proc->state() == QProcess::NotRunning) {
    proc->deleteLater();
    return;
  }
  const qint64 pid = proc->processId();
  QObject::connect(proc,
                   QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                   proc, &QObject::deleteLater);
  proc->terminate();
  if (pid > 0) {
    QProcess::startDetached(
        "sh", QStringList()
                  << "-c"
                  << QString("sleep 3; kill -9 %1 2>/dev/null").arg(pid));
  }
}

// 异步启动：端口探测 -> 可用则复用，否则清理旧进程 -> 启动 -> 就绪轮询
class BiliApiServerManager : public QObject {
public:
  using DoneCallback = std::function<void(bool)>;

  explicit BiliApiServerManager(QObject *parent = nullptr) : QObject(parent) {}

  void start(bool forceRestart, DoneCallback done) {
    if (m_busy) {
      // 调用方在调用前普遍已经关闸（setApiServerReady(false)），这里丢掉 done
      // 就等于把闸门焊死，所以排队等本轮结束一起回调，而不是直接丢弃
      qWarning() << "BiliPlugin: API server bring-up already in progress, "
                    "queueing callback";
      if (done) m_queuedDones.append(std::move(done));
      return;
    }
    m_busy = true;
    m_launched = false;
    m_portWaitCount = 0;
    m_done = std::move(done);
    const int attempt = ++m_attempt;

    // 看门狗：整个流程必须收敛。需覆盖"等端口释放 + 就绪轮询"的总时长
    QTimer::singleShot(WATCHDOG_MS, this, [this, attempt]() {
      if (m_busy && m_attempt == attempt) {
        qWarning() << "BiliPlugin: API server bring-up watchdog timeout";
        finish(false);
      }
    });

    if (forceRestart) {
      QProcess *owned = s_apiServerProcess;
      s_apiServerProcess = nullptr;
      detachAndStopProcess(owned);
      killExistingThenLaunch();
      return;
    }

    // 已有可用服务则直接复用，避免 kill 旧进程中断请求
    probeAlive([this](bool alive) {
      if (alive) {
        qDebug() << "BiliPlugin: API server already running, reuse it";
        finish(true);
        return;
      }
      killExistingThenLaunch();
    });
  }

private:
  void probeAlive(std::function<void(bool)> callback) {
    auto *socket = new QTcpSocket(this);
    auto reported = std::make_shared<bool>(false);
    auto report = [socket, reported, callback](bool ok) {
      if (*reported) return;
      *reported = true;
      socket->abort();
      socket->deleteLater();
      callback(ok);
    };
    connect(socket, &QAbstractSocket::connected, this,
            [report]() { report(true); });
    connect(socket, &QAbstractSocket::errorOccurred, this,
            [report](QAbstractSocket::SocketError) { report(false); });
    QTimer::singleShot(400, socket, [report]() { report(false); });
    socket->connectToHost("127.0.0.1", 8000);
  }

  // 查找并结束旧的 API 服务进程
  void killExistingThenLaunch() {
    // API_SERVER_PATH 已带尾斜杠，再拼 "/" 会得到 //server，
    // pgrep -f 拿这个串去匹配就漏掉以单斜杠路径启动的进程
    const QString execPath = API_SERVER_PATH + API_SERVER_EXEC;

    auto *pgrep = new QProcess(this);
    auto handled = std::make_shared<bool>(false);
    connect(pgrep,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this, pgrep, handled](int exitCode, QProcess::ExitStatus) {
              if (*handled) return;
              *handled = true;

              QVector<int> pidNums;
              if (exitCode == 0) {
                const QString output =
                    QString::fromLocal8Bit(pgrep->readAllStandardOutput())
                        .trimmed();
                const QStringList pids =
                    output.split('\n', Qt::SkipEmptyParts);
                for (const QString &pid : pids) {
                  bool ok = false;
                  const int pidNum = pid.toInt(&ok);
                  if (ok && pidNum > 0) pidNums.append(pidNum);
                }
              }
              pgrep->deleteLater();

              if (pidNums.isEmpty()) {
                waitPortFreeThenLaunch();
                return;
              }

              for (int pidNum : pidNums) {
                kill(pidNum, SIGTERM);
              }

              // 强杀仍存活的进程，再等端口真正释放
              QTimer::singleShot(500, this, [this, pidNums]() {
                for (int pidNum : pidNums) {
                  if (kill(pidNum, 0) == 0) {
                    qWarning() << "BiliPlugin: Force killing PID:" << pidNum;
                    kill(pidNum, SIGKILL);
                  }
                }
                waitPortFreeThenLaunch();
              });
            });
    connect(pgrep, &QProcess::errorOccurred, this,
            [this, pgrep, handled](QProcess::ProcessError) {
              if (*handled) return;
              *handled = true;
              pgrep->deleteLater();
              // pgrep 不可用时跳过残留清理，但仍要等端口释放：forceRestart 已经
              // SIGTERM 了自己启动的那个进程，它还在优雅关闭中占着 8000
              waitPortFreeThenLaunch();
            });
    pgrep->start("pgrep", QStringList() << "-f" << execPath);
  }

  // go 端收到 SIGTERM 后走优雅关闭（Shutdown 上限 10s），期间端口仍被占用。
  // 固定延时赌不赢：新进程会撞 address already in use 然后立刻 os.Exit(1)。
  void waitPortFreeThenLaunch() {
    if (++m_portWaitCount > PORT_WAIT_MAX) {
      qWarning() << "BiliPlugin: Port 8000 still busy, launching anyway";
      launchServer();
      return;
    }
    probeAlive([this](bool alive) {
      if (!alive) {
        launchServer();
        return;
      }
      QTimer::singleShot(PORT_WAIT_INTERVAL_MS, this,
                         [this]() { waitPortFreeThenLaunch(); });
    });
  }

  void launchServer() {
    qDebug() << "BiliPlugin: Starting API server...";

    const QString execPath = API_SERVER_PATH + API_SERVER_EXEC;
    if (!QFile::exists(execPath)) {
      qWarning() << "BiliPlugin: API server executable not found:" << execPath;
      finish(false);
      return;
    }

    QFile serverFile(execPath);
    if (!(serverFile.permissions() & QFile::ExeUser)) {
      serverFile.setPermissions(serverFile.permissions() | QFile::ExeUser |
                                QFile::ExeGroup | QFile::ExeOther);
    }

    s_apiServerProcess = new QProcess();
    s_apiServerProcess->setWorkingDirectory(API_SERVER_PATH);
    m_launched = true;

    QObject::connect(
        s_apiServerProcess, &QProcess::readyReadStandardOutput, []() {
          if (s_apiServerProcess) {
            qDebug() << "API Server:"
                     << s_apiServerProcess->readAllStandardOutput().constData();
          }
        });

    QObject::connect(
        s_apiServerProcess, &QProcess::readyReadStandardError, []() {
          if (s_apiServerProcess) {
            qWarning() << "API Server Error:"
                       << s_apiServerProcess->readAllStandardError().constData();
          }
        });

    QObject::connect(
        s_apiServerProcess,
        QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
        [](int exitCode, QProcess::ExitStatus exitStatus) {
          qWarning() << "BiliPlugin: API server exited with code" << exitCode
                     << ", status:"
                     << (exitStatus == QProcess::NormalExit ? "normal"
                                                            : "crashed");
        });

    connect(s_apiServerProcess, &QProcess::started, this, [this]() {
      // 等待服务器就绪：短轮询代替固定 sleep
      m_pollCount = 0;
      pollReadyOnce();
    });
    connect(s_apiServerProcess, &QProcess::errorOccurred, this,
            [this](QProcess::ProcessError error) {
              if (error == QProcess::FailedToStart) {
                qWarning() << "BiliPlugin: Failed to start API server:"
                           << (s_apiServerProcess
                                   ? s_apiServerProcess->errorString()
                                   : QString());
                finish(false);
              }
            });

    // 直接启动 Go 可执行文件
    s_apiServerProcess->start(execPath, QStringList());
  }

  void pollReadyOnce() {
    if (!s_apiServerProcess ||
        s_apiServerProcess->state() != QProcess::Running) {
      qWarning() << "BiliPlugin: API server failed to stay running";
      finish(false);
      return;
    }
    probeAlive([this](bool alive) {
      if (alive) {
        qDebug() << "BiliPlugin: API server started successfully, PID:"
                 << (s_apiServerProcess ? s_apiServerProcess->processId() : -1);
        finish(true);
        return;
      }
      if (++m_pollCount >= READY_POLL_MAX) {
        qWarning() << "BiliPlugin: API server failed to become ready";
        finish(false);
        return;
      }
      QTimer::singleShot(READY_POLL_INTERVAL_MS, this,
                         [this]() { pollReadyOnce(); });
    });
  }

  void finish(bool ok) {
    if (!m_busy) return;
    m_busy = false;
    if (!ok && m_launched && s_apiServerProcess) {
      // 不再杀掉本次启动的进程：go 端在 ListenAndServe 之前还有一段带网络请求
      // 的初始化，探测超时不等于启动失败，杀掉反而让它彻底起不来
      qWarning() << "BiliPlugin: API server not ready in time, keep it running";
    }
    m_launched = false;
    DoneCallback done = std::move(m_done);
    m_done = nullptr;
    QVector<DoneCallback> queued;
    queued.swap(m_queuedDones);
    if (done) done(ok);
    for (DoneCallback &cb : queued) {
      if (cb) cb(ok);
    }
  }

  // 看门狗需覆盖：等端口释放(最长 10s) + 就绪轮询(最长 30s) + 进程启动开销
  static constexpr int WATCHDOG_MS = 45000;
  // 就绪轮询：端口没监听时 errorOccurred 立即返回，每轮实际只消耗间隔时间，
  // 所以上限要按 次数 × 间隔 估算 —— 200 × 150ms = 30s
  static constexpr int READY_POLL_MAX = 200;
  static constexpr int READY_POLL_INTERVAL_MS = 150;
  // 等旧进程释放端口：go 的优雅关闭上限 10s
  static constexpr int PORT_WAIT_MAX = 40;
  static constexpr int PORT_WAIT_INTERVAL_MS = 250;

  bool m_busy = false;
  bool m_launched = false;
  int m_attempt = 0;
  int m_pollCount = 0;
  int m_portWaitCount = 0;
  DoneCallback m_done;
  QVector<DoneCallback> m_queuedDones;
};

BiliApiServerManager *s_serverManager = nullptr;

BiliApiServerManager *serverManager() {
  if (!s_serverManager) {
    s_serverManager = new BiliApiServerManager();
  }
  return s_serverManager;
}

} // namespace

// 供控制器调用的 API Server 控制函数
void bili_startApiServerAsync(std::function<void(bool)> onFinished) {
  serverManager()->start(false, std::move(onFinished));
}

void bili_restartApiServerAsync(std::function<void(bool)> onFinished) {
  serverManager()->start(true, std::move(onFinished));
}

// 同步拉起：不依赖事件循环。用于 init_plugin（宿主可能在无 dispatcher
// 的加载线程里调插件入口；纯 QTimer/QTcpSocket 异步链会永久卡住，
// 表现为 Go 不启动 + ready 闸门一直关着、一个请求都不发）。
bool bili_startApiServerSync() {
  qDebug() << "BiliPlugin: Starting API server (sync)...";

  auto probeOnce = []() -> bool {
    QTcpSocket socket;
    socket.connectToHost(QStringLiteral("127.0.0.1"), 8000);
    return socket.waitForConnected(300);
  };

  if (probeOnce()) {
    qDebug() << "BiliPlugin: API server already running, reuse it";
    return true;
  }

  // 清理残留进程（路径不要拼出双斜杠，否则 pgrep -f 匹配失败）
  const QString execPath = API_SERVER_PATH + API_SERVER_EXEC;
  {
    QProcess pgrepProcess;
    pgrepProcess.start(QStringLiteral("pgrep"),
                       QStringList() << QStringLiteral("-f") << execPath);
    pgrepProcess.waitForFinished(2000);
    if (pgrepProcess.exitCode() == 0) {
      const QString output =
          QString::fromLocal8Bit(pgrepProcess.readAllStandardOutput()).trimmed();
      const QStringList pids = output.split('\n', Qt::SkipEmptyParts);
      for (const QString &pid : pids) {
        bool ok = false;
        const int pidNum = pid.toInt(&ok);
        if (ok && pidNum > 0) {
          qDebug() << "BiliPlugin: Killing existing process PID:" << pidNum;
          kill(pidNum, SIGTERM);
        }
      }
      QThread::msleep(500);
      for (const QString &pid : pids) {
        bool ok = false;
        const int pidNum = pid.toInt(&ok);
        if (ok && pidNum > 0 && kill(pidNum, 0) == 0) {
          qWarning() << "BiliPlugin: Force killing PID:" << pidNum;
          kill(pidNum, SIGKILL);
        }
      }
    }
  }

  // go 优雅关闭可能占着端口，轮询等待释放
  for (int i = 0; i < 40; ++i) {
    if (!probeOnce())
      break;
    QThread::msleep(250);
  }

  if (!QFile::exists(execPath)) {
    qWarning() << "BiliPlugin: API server executable not found:" << execPath;
    return false;
  }

  QFile serverFile(execPath);
  if (!(serverFile.permissions() & QFile::ExeUser)) {
    serverFile.setPermissions(serverFile.permissions() | QFile::ExeUser |
                              QFile::ExeGroup | QFile::ExeOther);
  }

  // 若上次异步路径留下了已死的 QProcess 对象，先丢掉
  if (s_apiServerProcess) {
    s_apiServerProcess->disconnect();
    s_apiServerProcess->deleteLater();
    s_apiServerProcess = nullptr;
  }

  s_apiServerProcess = new QProcess();
  s_apiServerProcess->setWorkingDirectory(API_SERVER_PATH);

  QObject::connect(
      s_apiServerProcess, &QProcess::readyReadStandardOutput, []() {
        if (s_apiServerProcess) {
          qDebug() << "API Server:"
                   << s_apiServerProcess->readAllStandardOutput().constData();
        }
      });
  QObject::connect(
      s_apiServerProcess, &QProcess::readyReadStandardError, []() {
        if (s_apiServerProcess) {
          qWarning() << "API Server Error:"
                     << s_apiServerProcess->readAllStandardError().constData();
        }
      });
  QObject::connect(
      s_apiServerProcess,
      QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
      [](int exitCode, QProcess::ExitStatus exitStatus) {
        qWarning() << "BiliPlugin: API server exited with code" << exitCode
                   << ", status:"
                   << (exitStatus == QProcess::NormalExit ? "normal"
                                                          : "crashed");
      });

  s_apiServerProcess->start(execPath, QStringList());
  if (!s_apiServerProcess->waitForStarted(5000)) {
    qWarning() << "BiliPlugin: Failed to start API server:"
               << s_apiServerProcess->errorString();
    delete s_apiServerProcess;
    s_apiServerProcess = nullptr;
    return false;
  }

  // 端口探测：go 端现在先 Listen 再 Init，通常很快可连。
  // 给足时间覆盖进程启动抖动；不要因为探测超时就杀掉子进程。
  bool ready = false;
  for (int i = 0; i < 50; ++i) { // 50 * 100ms = 5s
    if (probeOnce()) {
      ready = true;
      break;
    }
    if (s_apiServerProcess->state() != QProcess::Running) {
      qWarning() << "BiliPlugin: API server exited during bring-up";
      delete s_apiServerProcess;
      s_apiServerProcess = nullptr;
      return false;
    }
    QThread::msleep(100);
  }

  if (!ready) {
    qWarning() << "BiliPlugin: API server started but port 8000 not ready yet;"
               << "keeping process, requests may retry";
  } else {
    qDebug() << "BiliPlugin: API server started successfully, PID:"
             << s_apiServerProcess->processId();
  }
  return s_apiServerProcess->state() == QProcess::Running;
}

void bili_stopApiServer() {
  qDebug() << "BiliPlugin: Stopping API server...";

  if (!s_apiServerProcess) {
    // 当前插件没有持有本次启动的 server 进程，可能是复用了已有服务；不要误杀。
    qDebug() << "BiliPlugin: No owned API server process, skip stop";
    return;
  }

  // 只停止当前插件启动的进程，不再 pgrep 全局清理，避免杀掉可复用服务
  QProcess *proc = s_apiServerProcess;
  s_apiServerProcess = nullptr;
  detachAndStopProcess(proc);

  qDebug() << "BiliPlugin: API server stop requested (async)";
}

extern "C" {

void init_plugin() {
  qDebug() << "BiliPlugin: Initializing...";

  qmlRegisterType<BiliController>("BiliPlugin", 1, 0, "BiliController");
  qmlRegisterType<VideoListModel>("BiliPlugin", 1, 0, "VideoListModel");
  qmlRegisterType<CommentListModel>("BiliPlugin", 1, 0, "CommentListModel");
  qmlRegisterType<HotSearchModel>("BiliPlugin", 1, 0, "HotSearchModel");
  qmlRegisterType<DynamicListModel>("BiliPlugin", 1, 0, "DynamicListModel");
  qmlRegisterType<SearchResultModel>("BiliPlugin", 1, 0, "SearchResultModel");
  qmlRegisterType<VideoPartListModel>("BiliPlugin", 1, 0, "VideoPartListModel");
  qmlRegisterType<FavoriteFolderModel>("BiliPlugin", 1, 0, "FavoriteFolderModel");
  qmlRegisterType<UpSeasonListModel>("BiliPlugin", 1, 0, "UpSeasonListModel");

  // 同步拉起 Go（见 bili_startApiServerSync 注释）。
  // 这里绝不能碰 BiliNetwork：
  // 1) m_apiServerReady 默认 true，同步启动返回时端口已可连，init 阶段无需关闸；
  // 2) 宿主常在无事件循环的加载线程调 init_plugin——若在这里
  //    BiliNetwork::instance()，会把 QNAM 单例钉在错误线程，之后主线程
  //    get() 发得出去也收不到 finished（表现同样是"根本不发请求"）。
  // 异步关闸只留给 UI 线程上的 restartGoServer。
  if (!bili_startApiServerSync()) {
    qWarning() << "BiliPlugin: Warning - API server failed to start";
  }

  qDebug() << "BiliPlugin: Registered successfully!";
}

void attach_engine(QQmlEngine *engine) {
  QMutexLocker locker(&s_providerMutex);

  s_engine = engine;

  if (s_engine) {
    QString pluginPath = "/userdisk/PenMods/plugins/bili_plugin/qml";
    engine->addImportPath(pluginPath);

    QString playerPath = "/userdisk/PenMods/plugins/bili_plugin/";
    engine->addImportPath(playerPath);

    // 在引擎/GUI 线程首次触及 BiliNetwork，保证 QNAM 线程亲和正确
    BiliNetwork *network = BiliNetwork::instance();
    // 插件热重载后若上次 destroy 关过闸又丢了回调，这里兜底放行
    network->setApiServerReady(true);
    s_imageProvider = new BiliImageProvider(network);

    s_engine->addImageProvider("bili", s_imageProvider);

    qDebug() << "BiliPlugin: Engine attached, ImageProvider registered";
  }
}

void destroy_plugin() {
  qDebug() << "BiliPlugin: Destroying...";

  // 删除 manager 会连带丢弃其挂起的回调与定时器
  delete s_serverManager;
  s_serverManager = nullptr;

  // 先停止 API 服务器
  bili_stopApiServer();

  {
    QMutexLocker locker(&s_providerMutex);
    s_imageProvider = nullptr;
  }

  // 恢复 ready 标记，让后续请求快速失败而不是继续排队
  BiliNetwork *network = BiliNetwork::instance();
  if (network) {
    network->cancelAllRequests();
    network->setApiServerReady(true);
  }

  s_engine = nullptr;

  qDebug() << "BiliPlugin: Destroyed successfully";
}

} // extern "C"
