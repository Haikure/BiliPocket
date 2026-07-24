#include "modules/video/BiliVideoModule.h"
#include "BiliController.h"
#include "BiliJsonUtils.h"
#include "BiliModels.h"
#include "BiliNetwork.h"
#include "modules/comment/BiliCommentModule.h"
#include "modules/history/BiliHistoryModule.h"
#include "modules/login/BiliLoginModule.h"
#include "modules/playback/BiliPlaybackModule.h"
#include "modules/season/BiliSeasonModule.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QProcess>
#include <QRegExp>
#include <QRegularExpression>
#include <QSettings>
#include <QStandardPaths>
#include <QStringListModel>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QtGlobal>
#include <algorithm>
#include <functional>

namespace {

QString normalizeBvid(const QString &bvid) {
  if (bvid.size() < 2)
    return bvid;
  QString normalized = bvid;
  normalized[0] = QLatin1Char('B');
  normalized[1] = QLatin1Char('V');
  return normalized;
}

QString avToBvid(qulonglong aid) {
  static constexpr qulonglong XOR_CODE = 23442827791579ULL;
  static constexpr qulonglong MAX_AID = 1ULL << 51;
  static constexpr int BASE = 58;
  static const QString alphabet =
      QStringLiteral("FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf");

  QChar bytes[12] = {
      QLatin1Char('B'), QLatin1Char('V'), QLatin1Char('1'), QLatin1Char('0'),
      QLatin1Char('0'), QLatin1Char('0'), QLatin1Char('0'), QLatin1Char('0'),
      QLatin1Char('0'), QLatin1Char('0'), QLatin1Char('0'), QLatin1Char('0')};

  qulonglong tmp = (MAX_AID | aid) ^ XOR_CODE;
  int bvIndex = 11;
  while (tmp > 0 && bvIndex >= 0) {
    bytes[bvIndex] = alphabet.at(static_cast<int>(tmp % BASE));
    tmp /= BASE;
    --bvIndex;
  }

  std::swap(bytes[3], bytes[9]);
  std::swap(bytes[4], bytes[7]);
  return QString(bytes, 12);
}

QString extractBvid(const QString &text) {
  static const QRegularExpression bvidRe(
      QStringLiteral("\\b[Bb][Vv]1[1-9A-HJ-NP-Za-km-z]{9}\\b"));
  const QRegularExpressionMatch match = bvidRe.match(text);
  if (!match.hasMatch())
    return QString();
  return normalizeBvid(match.captured(0));
}

QString extractAvAsBvid(const QString &text) {
  static const QRegularExpression avRe(
      QStringLiteral("(?:^|[^A-Za-z0-9])av(\\d{1,20})(?=$|[^A-Za-z0-9])"),
      QRegularExpression::CaseInsensitiveOption);
  const QRegularExpressionMatch match = avRe.match(text);
  if (!match.hasMatch())
    return QString();

  bool ok = false;
  const qulonglong aid = match.captured(1).toULongLong(&ok);
  if (!ok || aid == 0)
    return QString();
  return avToBvid(aid);
}

QString extractVideoBvid(const QString &text) {
  QString bvid = extractBvid(text);
  if (!bvid.isEmpty())
    return bvid;
  return extractAvAsBvid(text);
}

int currentPlaybackDuration(qint64 currentCid, int fallbackDuration,
                            VideoPartListModel *partModel) {
  if (!partModel || partModel->count() <= 0 || currentCid <= 0)
    return fallbackDuration;

  for (int i = 0; i < partModel->count(); ++i) {
    QModelIndex idx = partModel->index(i, 0);
    qint64 cid = partModel->data(idx, VideoPartListModel::CidRole).toLongLong();
    if (cid != currentCid)
      continue;

    int partDuration = partModel->data(idx, VideoPartListModel::DurationRole).toInt();
    return partDuration > 0 ? partDuration : fallbackDuration;
  }

  return fallbackDuration;
}

struct PlaybackProgressState {
  qint64 progressCid = 0;
  int progressSeconds = 0;
  int heartbeatPlayedTime = 0;
};

struct ParsedVideoDetailSnapshotData {
  VideoItem video;
  qint64 seasonId = 0;
  QString seasonTitle;
  QString seasonCover;
  qint64 seasonMid = 0;
  int seasonTotal = 0;
  QVector<VideoPartItem> parts;
  bool valid = false;
};

PlaybackProgressState resolvePlaybackProgressState(const QJsonObject &data,
                                                   qint64 currentCid,
                                                   int currentDuration) {
  PlaybackProgressState state;
  state.progressCid = currentCid;

  int normalizedPlayedTime = 0;
  bool playedTimeOk = false;
  int lastPlayTime = BiliJson::intValue(data.value("last_play_time"), &playedTimeOk);
  if (playedTimeOk && lastPlayTime >= -1) {
    if (lastPlayTime > 0 && currentDuration > 0 && lastPlayTime > currentDuration) {
      int lastPlaySeconds = qRound(lastPlayTime / 1000.0);
      if (lastPlaySeconds <= currentDuration) {
        lastPlayTime = lastPlaySeconds;
      }
    }
    if (lastPlayTime == -1 || currentDuration <= 0 || lastPlayTime <= currentDuration) {
      normalizedPlayedTime = lastPlayTime;
    }
  }

  qint64 lastPlayCid = data.value("last_play_cid").toVariant().toLongLong();
  if (lastPlayCid > 0) {
    state.progressCid = lastPlayCid;
  }
  state.progressSeconds = qMax(0, normalizedPlayedTime);

  if (state.progressCid != currentCid)
    return state;

  if (normalizedPlayedTime == -1) {
    state.heartbeatPlayedTime = -1;
  } else if (normalizedPlayedTime > 0) {
    if (currentDuration > 0 && normalizedPlayedTime >= currentDuration) {
      state.heartbeatPlayedTime = -1;
    } else {
      state.heartbeatPlayedTime = normalizedPlayedTime;
    }
  }
  return state;
}

ParsedVideoDetailSnapshotData parseVideoDetailSnapshotData(const QJsonObject &data) {
  ParsedVideoDetailSnapshotData parsed;
  VideoItem parsedVideo = VideoListModel::parseVideoItem(data);
  parsedVideo.aid = data.value("aid").toVariant().toLongLong();

  const QJsonObject ugcSeason = data.value("ugc_season").toObject();
  parsed.seasonId = ugcSeason.value("id").toVariant().toLongLong();
  if (parsed.seasonId > 0) {
    parsed.seasonTitle = ugcSeason.value("title").toString();
    parsed.seasonCover = ugcSeason.value("cover").toString();
    if (parsed.seasonCover.isEmpty()) {
      parsed.seasonCover = parsedVideo.pic;
    }
    parsed.seasonMid = ugcSeason.value("mid").toVariant().toLongLong();
    if (parsed.seasonMid <= 0) {
      parsed.seasonMid = parsedVideo.ownerMid;
    }
    bool totalKnown = false;
    int total = BiliJson::intValue(ugcSeason.value("ep_count"), &totalKnown);
    if (!totalKnown || total <= 0) {
      total = 0;
      const QJsonArray sections = ugcSeason.value("sections").toArray();
      for (const QJsonValue &sectionValue : sections) {
        total += sectionValue.toObject().value("episodes").toArray().size();
      }
    }
    parsed.seasonTotal = qMax(0, total);
  }

  const QJsonArray pages = data.value("pages").toArray();
  if (pages.count() > 1) {
    parsed.parts.reserve(pages.size());
    for (const QJsonValue &v : pages) {
      if (v.isObject()) {
        parsed.parts.append(VideoPartListModel::parseVideoPartItem(v.toObject()));
      }
    }
  }
  if (!pages.isEmpty() && parsedVideo.cid == 0) {
    const QJsonObject firstPage = pages.first().toObject();
    parsedVideo.cid = firstPage.value("cid").toVariant().toLongLong();
  }

  parsed.video = parsedVideo;
  parsed.valid = !parsed.video.bvid.isEmpty() && !parsed.video.title.isEmpty();
  return parsed;
}

} // namespace

BiliVideoModule::BiliVideoModule(BiliController *controller)
    : QObject(controller), m_controller(controller) {}

QObject *BiliVideoModule::videoPartModel() { return m_controller->m_videoPartModel; }

void BiliVideoModule::resolveVideoLink(const QString &link) {
  const QString trimmed = link.trimmed();
  if (trimmed.isEmpty())
    return;

  const QString directBvid = extractVideoBvid(trimmed);
  if (!directBvid.isEmpty()) {
    emit videoLinkResolved(directBvid);
    return;
  }

  QUrl url = QUrl::fromUserInput(trimmed);
  if (!url.isValid() || url.host().isEmpty()) {
    emit m_controller->toastMessage(QStringLiteral("无法识别视频链接"));
    return;
  }

  const QString host = url.host().toLower();
  if (host == QStringLiteral("b23.tv") || host == QStringLiteral("www.b23.tv")) {
    if (url.scheme().isEmpty())
      url.setScheme(QStringLiteral("https"));
    resolveShortVideoLink(url, false);
    return;
  }

  emit m_controller->toastMessage(QStringLiteral("无法识别视频链接"));
}

void BiliVideoModule::resolveShortVideoLink(const QUrl &url, bool useGet) {
  if (!url.isValid())
    return;

  QNetworkAccessManager *nam = new QNetworkAccessManager(this);
  nam->setTransferTimeout(8000);

  QNetworkRequest request(url);
  request.setRawHeader("User-Agent",
                       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
  request.setRawHeader("Referer", "https://www.bilibili.com");
  request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                       QNetworkRequest::NoLessSafeRedirectPolicy);
  request.setMaximumRedirectsAllowed(5);

  QNetworkReply *reply = useGet ? nam->get(request) : nam->head(request);
  if (!reply) {
    nam->deleteLater();
    emit m_controller->toastMessage(QStringLiteral("无法解析短链"));
    return;
  }

  QPointer<QNetworkReply> safeReply(reply);
  QTimer *timer = new QTimer(nam);
  timer->setSingleShot(true);
  connect(timer, &QTimer::timeout, nam, [safeReply]() {
    if (safeReply && safeReply->isRunning())
      safeReply->abort();
  });
  timer->start(8000);

  connect(reply, &QNetworkReply::finished, this,
          [this, reply, nam, timer, url, useGet]() {
            timer->stop();

            QUrl finalUrl = reply->url();
            const QVariant redirectTarget =
                reply->attribute(QNetworkRequest::RedirectionTargetAttribute);
            if (redirectTarget.isValid()) {
              finalUrl = finalUrl.resolved(redirectTarget.toUrl());
            }

            const QString resolvedBvid = extractVideoBvid(finalUrl.toString());
            const bool hadError = reply->error() != QNetworkReply::NoError;
            reply->deleteLater();
            nam->deleteLater();

            if (!resolvedBvid.isEmpty()) {
              emit videoLinkResolved(resolvedBvid);
              return;
            }

            if (!useGet) {
              resolveShortVideoLink(url, true);
              return;
            }

            if (hadError) {
              emit m_controller->toastMessage(QStringLiteral("短链解析失败"));
            } else {
              emit m_controller->toastMessage(QStringLiteral("短链不是视频链接"));
            }
          });
}

void BiliVideoModule::scheduleVideoDetailPreload(const QString &bvid, qint64 aid, qint64 cid) {
  if (!m_controller || !m_controller->m_videoDetailPreloadEnabled ||
      bvid.isEmpty() || aid <= 0 || cid <= 0) {
    return;
  }

  QPointer<BiliController> self(m_controller);
  auto isCurrentVideo = [self, bvid, aid, cid]() {
    return self && self->m_videoDetailPreloadEnabled &&
           self->m_currentVideo.bvid == bvid &&
           self->m_currentVideo.aid == aid &&
           self->m_currentVideo.cid == cid;
  };

  QTimer::singleShot(0, m_controller, [self, isCurrentVideo]() {
    if (!isCurrentVideo() || !self->m_commentModule) return;
    self->m_commentModule->fetchComments(1, true);
  });

  QTimer::singleShot(20, m_controller, [self, isCurrentVideo]() {
    if (!isCurrentVideo() || !self->m_playbackModule) return;
    self->m_playbackModule->fetchSubtitleList(true);
  });

  QTimer::singleShot(40, m_controller, [self, isCurrentVideo]() {
    if (!isCurrentVideo() || !self->m_seasonModule) return;
    self->m_seasonModule->fetchRelatedVideos();
  });
}

void BiliVideoModule::captureCurrentVideoDetail() {
  if (!m_controller)
    return;
  const QString bvid = m_controller->m_currentVideo.bvid;
  if (bvid.isEmpty() || m_controller->m_currentVideo.title.isEmpty())
    return;

  BiliController::VideoDetailSnapshot snapshot;
  snapshot.video = m_controller->m_currentVideo;
  snapshot.playbackProgressCid = m_controller->m_playbackProgressCid;
  snapshot.playbackProgressSeconds = m_controller->m_playbackProgressSeconds;
  snapshot.seasonId = m_controller->m_videoSeasonId;
  snapshot.seasonTitle = m_controller->m_videoSeasonTitle;
  snapshot.seasonCover = m_controller->m_videoSeasonCover;
  snapshot.seasonMid = m_controller->m_videoSeasonMid;
  snapshot.seasonTotal = m_controller->m_videoSeasonTotal;
  snapshot.parts = m_controller->m_videoPartModel ? m_controller->m_videoPartModel->items()
                                                  : QVector<VideoPartItem>();
  snapshot.acceptQualities = m_controller->acceptQualityValues();
  snapshot.isFavorited = m_controller->isFavorited();
  snapshot.isCoined = m_controller->isCoined();
  snapshot.isLiked = m_controller->isLiked();
  snapshot.isWatchLater = m_controller->isWatchLater();
  snapshot.subtitleItems = m_controller->subtitleItemValues();
  snapshot.selectedSubtitleId = m_controller->selectedSubtitleId();
  snapshot.selectedSubtitleLabel = m_controller->selectedSubtitleLabel();
  snapshot.subtitleSelectionOverridden = m_controller->m_subtitleSelectionOverridden;
  snapshot.valid = true;

  m_controller->m_videoDetailSnapshots.insert(bvid, snapshot);
}

bool BiliVideoModule::restoreCachedVideoDetail(const QString &bvid) {
  if (!m_controller || bvid.isEmpty())
    return false;

  const auto it = m_controller->m_videoDetailSnapshots.constFind(bvid);
  if (it == m_controller->m_videoDetailSnapshots.constEnd() || !it->valid)
    return false;

  if (!m_controller->m_videoDetailLoadingBvid.isEmpty()) {
    m_controller->m_videoDetailLoadingBvid.clear();
    m_controller->setIsLoading(false);
  }
  if (!m_controller->m_acceptQualitiesLoadingKey.isEmpty()) {
    m_controller->m_acceptQualitiesLoadingKey.clear();
    m_controller->setIsLoading(false);
  }

  const BiliController::VideoDetailSnapshot snapshot = it.value();
  const QString oldBvid = m_controller->m_currentVideo.bvid;
  if (oldBvid != snapshot.video.bvid && m_controller->m_commentModule) {
    m_controller->m_commentModule->resetForVideoChange();
  }
  m_controller->m_currentVideo = snapshot.video;
  m_controller->m_playbackProgressCid = snapshot.playbackProgressCid;
  m_controller->m_playbackProgressSeconds = snapshot.playbackProgressSeconds;
  m_controller->m_videoSeasonId = snapshot.seasonId;
  m_controller->m_videoSeasonTitle = snapshot.seasonTitle;
  m_controller->m_videoSeasonCover = snapshot.seasonCover;
  m_controller->m_videoSeasonMid = snapshot.seasonMid;
  m_controller->m_videoSeasonTotal = snapshot.seasonTotal;
  if (m_controller->m_videoPartModel) {
    if (snapshot.parts.isEmpty()) {
      m_controller->m_videoPartModel->clear();
    } else {
      m_controller->m_videoPartModel->setItems(snapshot.parts);
    }
  }
  if (snapshot.acceptQualities.isEmpty()) {
    m_controller->clearAcceptQualities();
  } else {
    m_controller->setAcceptQualities(snapshot.acceptQualities);
  }
  m_controller->setFavoriteState(snapshot.isFavorited);
  m_controller->setCoinState(snapshot.isCoined);
  m_controller->setLikeState(snapshot.isLiked);
  m_controller->setWatchLaterState(snapshot.isWatchLater);
  m_controller->m_subtitleSelectionOverridden = snapshot.subtitleSelectionOverridden;
  m_controller->setSelectedSubtitle(snapshot.selectedSubtitleId,
                                    snapshot.selectedSubtitleLabel);
  m_controller->setSubtitleItems(snapshot.subtitleItems);
  m_controller->applyDefaultSubtitleSelection();

  emit m_controller->videoDetailChanged();
  emit m_controller->videoStatsChanged();
  emit m_controller->playbackProgressChanged();
  scheduleVideoDetailPreload(m_controller->m_currentVideo.bvid,
                             m_controller->m_currentVideo.aid,
                             m_controller->m_currentVideo.cid);
  return true;
}

void BiliVideoModule::dropCachedVideoDetail(const QString &bvid) {
  if (!m_controller || bvid.isEmpty())
    return;

  m_controller->m_videoDetailSnapshots.remove(bvid);
  m_controller->m_videoDetailPreloadingBvids.remove(bvid);
  if (m_controller->m_videoDetailLoadingBvid == bvid) {
    m_controller->m_videoDetailLoadingBvid.clear();
    m_controller->setIsLoading(false);
  }
  if (!m_controller->m_acceptQualitiesLoadingKey.isEmpty() &&
      m_controller->m_acceptQualitiesLoadingKey.startsWith(bvid + QLatin1Char(':'))) {
    m_controller->m_acceptQualitiesLoadingKey.clear();
    m_controller->setIsLoading(false);
  }
  if (m_controller->m_currentVideo.bvid != bvid)
    return;

  if (m_controller->m_commentModule) {
    m_controller->m_commentModule->resetForVideoChange();
  }
  m_controller->m_currentVideo = VideoItem();
  m_controller->m_playbackProgressCid = 0;
  m_controller->m_playbackProgressSeconds = 0;
  m_controller->m_videoSeasonId = 0;
  m_controller->m_videoSeasonTitle.clear();
  m_controller->m_videoSeasonCover.clear();
  m_controller->m_videoSeasonMid = 0;
  m_controller->m_videoSeasonTotal = 0;
  if (m_controller->m_videoPartModel) {
    m_controller->m_videoPartModel->clear();
  }
  if (m_controller->m_relatedVideoModel) {
    m_controller->m_relatedVideoModel->clear();
    m_controller->m_relatedVideoModel->setHasMore(false);
    m_controller->m_relatedVideoModel->setLoading(false);
    m_controller->m_relatedVideoModel->setErrorMessage("");
  }
  m_controller->m_relatedVideoBvid.clear();
  m_controller->m_relatedVideoLoadingBvid.clear();
  m_controller->setFavoriteState(false);
  m_controller->setCoinState(false);
  m_controller->setLikeState(false);
  m_controller->setWatchLaterState(false);
  m_controller->clearAcceptQualities();
  m_controller->clearSubtitleItems();
  m_controller->clearSelectedSubtitle();

  emit m_controller->videoDetailChanged();
  emit m_controller->videoStatsChanged();
  emit m_controller->playbackProgressChanged();
}

// ====== API: 视频详情 ======

void BiliVideoModule::refreshCurrentPlaybackProgress() {
  if (!m_controller->m_loggedIn)
    return;
  if (m_controller->m_currentVideo.aid <= 0 || m_controller->m_currentVideo.cid <= 0 || m_controller->m_currentVideo.bvid.isEmpty())
    return;

  const qint64 aid = m_controller->m_currentVideo.aid;
  const qint64 currentCid = m_controller->m_currentVideo.cid;
  const QString bvid = m_controller->m_currentVideo.bvid;
  const int currentDuration = currentPlaybackDuration(
      currentCid, m_controller->m_currentVideo.duration, m_controller->m_videoPartModel);

  QMap<QString, QString> params;
  params["aid"] = QString::number(aid);
  params["cid"] = QString::number(currentCid);
  params["bvid"] = bvid;

  QPointer<BiliController> self(m_controller);
  m_controller->m_network->get(
      "/video/player/info", params,
      [self, currentCid, currentDuration](const QJsonObject &data) {
        if (!self || self->m_currentVideo.cid != currentCid)
          return;

        PlaybackProgressState state =
            resolvePlaybackProgressState(data, currentCid, currentDuration);
        self->m_playbackProgressCid = state.progressCid;
        self->m_playbackProgressSeconds = state.progressSeconds;
        emit self->playbackProgressChanged();
      },
      [](int, const QString &) {});
}

void BiliVideoModule::reportCurrentVideoAsRecentViewIfNeeded() {
  if (!m_controller->m_loggedIn)
    return;
  if (m_controller->m_currentVideo.aid <= 0 || m_controller->m_currentVideo.cid <= 0 || m_controller->m_currentVideo.bvid.isEmpty())
    return;

  const qint64 aid = m_controller->m_currentVideo.aid;
  const qint64 currentCid = m_controller->m_currentVideo.cid;
  const QString bvid = m_controller->m_currentVideo.bvid;
  const int currentDuration = currentPlaybackDuration(
      currentCid, m_controller->m_currentVideo.duration, m_controller->m_videoPartModel);
  QString reportKey = bvid + "#" + QString::number(currentCid);
  if (m_controller->m_lastRecentViewReportKey == reportKey) {
    refreshCurrentPlaybackProgress();
    return;
  }
  m_controller->m_lastRecentViewReportKey = reportKey;

  QMap<QString, QString> playerInfoParams;
  playerInfoParams["aid"] = QString::number(aid);
  playerInfoParams["cid"] = QString::number(currentCid);
  playerInfoParams["bvid"] = bvid;

  QPointer<BiliController> self(m_controller);
  m_controller->m_network->get(
      "/video/player/info", playerInfoParams,
      [self, reportKey, aid, currentCid, bvid, currentDuration](const QJsonObject &data) {
        if (!self)
          return;

        PlaybackProgressState state =
            resolvePlaybackProgressState(data, currentCid, currentDuration);
        self->m_playbackProgressCid = state.progressCid;
        self->m_playbackProgressSeconds = state.progressSeconds;
        emit self->playbackProgressChanged();

        QMap<QString, QString> params;
        params["aid"] = QString::number(aid);
        params["cid"] = QString::number(currentCid);
        params["bvid"] = bvid;
        params["played_time"] = QString::number(state.heartbeatPlayedTime);

        self->m_network->get(
            "/player/heartbeat", params,
            [self](const QJsonObject &) {
              if (!self)
                return;
            },
            [self, reportKey](int, const QString &) {
              if (!self)
                return;
              if (self->m_lastRecentViewReportKey == reportKey) {
                self->m_lastRecentViewReportKey.clear();
              }
            });
      },
      [self, reportKey](int, const QString &) {
        if (!self)
          return;
        if (self->m_lastRecentViewReportKey == reportKey) {
          self->m_lastRecentViewReportKey.clear();
        }
      });
}

void BiliVideoModule::preloadVideoDetail(const QString &bvid) {
  if (!m_controller || !m_controller->m_videoDetailPreloadEnabled)
    return;

  const QString requestedBvid = normalizeBvid(bvid.trimmed());
  if (!requestedBvid.startsWith("BV") || requestedBvid.length() < 10)
    return;
  if (m_controller->m_currentVideo.bvid == requestedBvid &&
      !m_controller->m_currentVideo.title.isEmpty()) {
    return;
  }
  const auto cached = m_controller->m_videoDetailSnapshots.constFind(requestedBvid);
  if (cached != m_controller->m_videoDetailSnapshots.constEnd() && cached->valid)
    return;
  if (m_controller->m_videoDetailPreloadingBvids.contains(requestedBvid))
    return;

  m_controller->m_videoDetailPreloadingBvids.insert(requestedBvid);

  QMap<QString, QString> params;
  params["bvid"] = requestedBvid;

  QPointer<BiliController> self(m_controller);
  m_controller->m_network->get(
      "/video/info", params,
      [self, requestedBvid](const QJsonObject &data) {
        if (!self)
          return;
        if (!self->m_videoDetailPreloadingBvids.remove(requestedBvid))
          return;
        const auto cached = self->m_videoDetailSnapshots.constFind(requestedBvid);
        if (cached != self->m_videoDetailSnapshots.constEnd() && cached->valid)
          return;

        const ParsedVideoDetailSnapshotData parsed =
            parseVideoDetailSnapshotData(data);
        if (!parsed.valid || parsed.video.bvid != requestedBvid)
          return;

        BiliController::VideoDetailSnapshot snapshot;
        snapshot.video = parsed.video;
        snapshot.seasonId = parsed.seasonId;
        snapshot.seasonTitle = parsed.seasonTitle;
        snapshot.seasonCover = parsed.seasonCover;
        snapshot.seasonMid = parsed.seasonMid;
        snapshot.seasonTotal = parsed.seasonTotal;
        snapshot.parts = parsed.parts;
        snapshot.valid = true;
        self->m_videoDetailSnapshots.insert(requestedBvid, snapshot);
      },
      [self, requestedBvid](int, const QString &) {
        if (!self)
          return;
        self->m_videoDetailPreloadingBvids.remove(requestedBvid);
      });
}

void BiliVideoModule::fetchVideoDetail(const QString &bvid) {
  if (bvid.isEmpty()) {
    emit m_controller->toastMessage("视频 ID 为空");
    return;
  }
  if (m_controller->m_videoDetailLoadingBvid == bvid) {
    return;
  }

  bool sameVideoRefresh = (m_controller->m_currentVideo.bvid == bvid && !bvid.isEmpty());
  // 同视频刷新时保存当前选中的 cid，避免 refreshDetail 解析后被重置到第一页
  const qint64 prevCid = sameVideoRefresh ? m_controller->m_currentVideo.cid : 0;

  // 仅在切换到新视频时重置收藏/投币/点赞/字幕状态，避免同视频刷新闪动
  if (!sameVideoRefresh) {
    if (m_controller->m_playbackProgressCid != 0 || m_controller->m_playbackProgressSeconds != 0) {
      m_controller->m_playbackProgressCid = 0;
      m_controller->m_playbackProgressSeconds = 0;
      emit m_controller->playbackProgressChanged();
    }
    m_controller->setFavoriteState(false);
    m_controller->setCoinState(false);
    m_controller->setLikeState(false);
    m_controller->setWatchLaterState(false);

    // 切换视频时重置字幕选择与列表
    m_controller->clearSelectedSubtitle();
    m_controller->clearSubtitleItems();
  }

  // BV号格式校验
  if (!bvid.startsWith("BV") || bvid.length() < 10) {
    emit m_controller->toastMessage("无效的视频 ID");
    return;
  }

  if (!sameVideoRefresh && m_controller->m_relatedVideoModel) {
    m_controller->m_relatedVideoModel->clear();
    m_controller->m_relatedVideoModel->setHasMore(false);
    m_controller->m_relatedVideoModel->setLoading(false);
    m_controller->m_relatedVideoModel->setErrorMessage("");
    m_controller->m_relatedVideoBvid.clear();
    m_controller->m_relatedVideoLoadingBvid.clear();
  }

  const QString requestedBvid = bvid;
  if (!m_controller->m_videoDetailLoadingBvid.isEmpty() &&
      m_controller->m_videoDetailLoadingBvid != requestedBvid) {
    m_controller->m_videoDetailLoadingBvid.clear();
    m_controller->setIsLoading(false);
  }
  m_controller->setIsLoading(true);
  m_controller->m_videoDetailLoadingBvid = requestedBvid;

  QMap<QString, QString> params;
  params["bvid"] = bvid;

  QPointer<BiliController> self(m_controller);

  m_controller->m_network->get(
      "/video/info", params,
      [self, requestedBvid, sameVideoRefresh, prevCid](const QJsonObject &data) {
        if (!self)
          return;
        if (self->m_videoDetailLoadingBvid != requestedBvid)
          return;

        self->m_videoDetailLoadingBvid.clear();
        const QString oldBvid = self->m_currentVideo.bvid;
        VideoItem parsedVideo = VideoListModel::parseVideoItem(data);
        parsedVideo.aid = data.value("aid").toVariant().toLongLong();
        if (oldBvid != parsedVideo.bvid && self->m_commentModule) {
          self->m_commentModule->resetForVideoChange();
        }
        self->m_currentVideo = parsedVideo;

        self->m_videoSeasonId = 0;
        self->m_videoSeasonTitle.clear();
        self->m_videoSeasonCover.clear();
        self->m_videoSeasonMid = 0;
        self->m_videoSeasonTotal = 0;
        QJsonObject ugcSeason = data.value("ugc_season").toObject();
        qint64 seasonId = ugcSeason.value("id").toVariant().toLongLong();
        if (seasonId > 0) {
          self->m_videoSeasonId = seasonId;
          self->m_videoSeasonTitle = ugcSeason.value("title").toString();
          self->m_videoSeasonCover = ugcSeason.value("cover").toString();
          if (self->m_videoSeasonCover.isEmpty()) {
            self->m_videoSeasonCover = self->m_currentVideo.pic;
          }
          self->m_videoSeasonMid = ugcSeason.value("mid").toVariant().toLongLong();
          if (self->m_videoSeasonMid <= 0) {
            self->m_videoSeasonMid = self->m_currentVideo.ownerMid;
          }
          bool totalKnown = false;
          int total = BiliJson::intValue(ugcSeason.value("ep_count"), &totalKnown);
          if (!totalKnown || total <= 0) {
            total = 0;
            QJsonArray sections = ugcSeason.value("sections").toArray();
            for (const QJsonValue &sectionValue : sections) {
              total += sectionValue.toObject().value("episodes").toArray().size();
            }
          }
          self->m_videoSeasonTotal = qMax(0, total);
        }

        QJsonArray pages = data.value("pages").toArray();

        // 解析分P列表（先更新模型，后决定 cid）
        if (pages.count() > 1) { // 只有多于1P时才显示列表
          QVector<VideoPartItem> parts;
          parts.reserve(pages.size());
          for (const QJsonValue &v : pages) {
            if (v.isObject()) {
              parts.append(VideoPartListModel::parseVideoPartItem(v.toObject()));
            }
          }
          self->m_videoPartModel->setItems(parts);
        } else {
          self->m_videoPartModel->clear();
        }

        // 决定当前 cid：
        // - 同视频刷新：优先保留 prevCid（若它存在于 pages 中）
        // - 否则：若解析不到 cid，则退回到第一页 cid
        if (!pages.isEmpty()) {
          if (sameVideoRefresh && prevCid > 0) {
            bool found = false;
            for (const QJsonValue &v : pages) {
              QJsonObject p = v.toObject();
              qint64 cid = p.value("cid").toVariant().toLongLong();
              if (cid > 0 && cid == prevCid) {
                found = true;
                break;
              }
            }
            if (found) {
              self->m_currentVideo.cid = prevCid;
            }
          }

          if (self->m_currentVideo.cid == 0) {
            QJsonObject firstPage = pages.first().toObject();
            self->m_currentVideo.cid = firstPage.value("cid").toVariant().toLongLong();
          }
        }

        if (self->m_videoModule) {
          self->m_videoModule->captureCurrentVideoDetail();
        }

        emit self->videoDetailChanged();
        emit self->videoStatsChanged();
        emit self->playbackProgressChanged();
        self->setIsLoading(false);
        if (self->m_videoModule) {
          self->m_videoModule->scheduleVideoDetailPreload(
              self->m_currentVideo.bvid, self->m_currentVideo.aid,
              self->m_currentVideo.cid);
        }
      },
      [self, requestedBvid](int code, const QString &msg) {
        if (!self)
          return;
        if (self->m_videoDetailLoadingBvid != requestedBvid)
          return;

        self->m_videoDetailLoadingBvid.clear();
        self->setIsLoading(false);
        self->m_videoPartModel->clear();
        if (code == QNetworkReply::OperationCanceledError)
          return;
        emit self->toastMessage(QString("获取视频信息失败：%1").arg(msg));
      });
}
