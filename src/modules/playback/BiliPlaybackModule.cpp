#include "modules/playback/BiliPlaybackModule.h"
#include "BiliController.h"
#include "BiliJsonUtils.h"
#include "BiliModels.h"
#include "BiliNetwork.h"
#include "modules/history/BiliHistoryModule.h"
#include "modules/login/BiliLoginModule.h"
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
#include <QSettings>
#include <QStandardPaths>
#include <QStringListModel>
#include <QTimer>
#include <QUrl>
#include <QtGlobal>
#include <algorithm>
#include <functional>
#include <utility>

namespace {

struct CurrentPartPlaybackInfo {
  int index = 1;
  int count = 1;
  int duration = 0;
};

CurrentPartPlaybackInfo currentPartPlaybackInfo(qint64 currentCid, int fallbackDuration,
                                                VideoPartListModel *partModel) {
  CurrentPartPlaybackInfo info;
  info.duration = fallbackDuration;
  if (!partModel || partModel->count() <= 0) return info;

  info.count = qMax(1, partModel->count());
  for (int i = 0; i < partModel->count(); ++i) {
    QModelIndex idx = partModel->index(i, 0);
    qint64 cid = partModel->data(idx, VideoPartListModel::CidRole).toLongLong();
    if (cid != currentCid) continue;

    info.index = i + 1;
    int partDuration = partModel->data(idx, VideoPartListModel::DurationRole).toInt();
    if (partDuration > 0) info.duration = partDuration;
    break;
  }
  return info;
}

QString biliHeartbeatScriptOpts(qint64 aid, qint64 cid, const QString &bvid, int duration,
                                VideoPartListModel *partModel) {
  CurrentPartPlaybackInfo part = currentPartPlaybackInfo(cid, duration, partModel);
  return QStringLiteral("--script-opts=bili-aid=%1,bili-cid=%2,bili-bvid=%3,"
                        "bili-part-index=%4,bili-part-count=%5,bili-part-duration=%6,"
                        "bili-type=3,bili-sub-type=0,bili-epid=0,bili-sid=0")
      .arg(aid)
      .arg(cid)
      .arg(bvid)
      .arg(part.index)
      .arg(part.count)
      .arg(part.duration);
}

} // namespace

BiliPlaybackModule::BiliPlaybackModule(BiliController *controller)
    : QObject(controller), m_controller(controller) {}

// ====== API: 播放地址 ======

void BiliPlaybackModule::fetchPlayUrl(int quality) {
  if (m_controller->m_currentVideo.bvid.isEmpty() || m_controller->m_currentVideo.cid == 0) {
    emit m_controller->toastMessage("视频信息不完整，无法播放");
    return;
  }

  const bool audioOnly = (quality == 0);
  const int requestedQuality = audioOnly ? 16 : qBound(16, quality, 127);
  // 开启"优先播放MP4流"且非纯音频时，先请求 MP4（fnval=1），不可用再回退 DASH（fnval=4048）
  const bool preferMp4 = m_controller->m_preferMp4Stream && !audioOnly;
  requestPlayUrlInternal(requestedQuality, audioOnly, preferMp4 ? 1 : 4048, preferMp4);
}

void BiliPlaybackModule::requestPlayUrlInternal(int requestedQuality, bool audioOnly,
                                                int fnval, bool allowDashFallback) {
  const int quality = audioOnly ? 0 : requestedQuality;
  const QString requestKey = QString("%1:%2:%3:%4")
                                 .arg(m_controller->m_currentVideo.bvid)
                                 .arg(m_controller->m_currentVideo.cid)
                                 .arg(quality)
                                 .arg(fnval);
  const QString requestBvid = m_controller->m_currentVideo.bvid;
  const qint64 requestCid = m_controller->m_currentVideo.cid;
  if (m_controller->m_playUrlLoadingKey == requestKey) {
    return;
  }
  if (!m_controller->m_playUrlLoadingKey.isEmpty()) {
    m_controller->m_playUrlLoadingKey.clear();
    m_controller->setIsLoading(false);
  }
  m_controller->setIsLoading(true);
  m_controller->m_playUrlLoadingKey = requestKey;
  m_controller->clearPlayResult();

  QMap<QString, QString> params;
  params["aid"] = QString::number(m_controller->videoAid());
  params["cid"] = QString::number(m_controller->m_currentVideo.cid);
  params["qn"] = QString::number(requestedQuality);
  params["bvid"] = m_controller->m_currentVideo.bvid;
  // fnval=1: MP4 格式（仅 H.264）；fnval=4048: DASH 格式（音视频分离，含全部高级流）
  params["fnval"] = QString::number(fnval);

  QPointer<BiliController> self(m_controller);

  m_controller->m_network->get(
      "/video/playurl", params,
      [moduleSelf = QPointer<BiliPlaybackModule>(this), self, requestKey, requestBvid,
       requestCid, requestedQuality, audioOnly, fnval, allowDashFallback](const QJsonObject &data) {
        if (!moduleSelf || !self)
          return;
        if (self->m_playUrlLoadingKey != requestKey)
          return;

        self->m_playUrlLoadingKey.clear();
        if (self->m_currentVideo.bvid != requestBvid || self->m_currentVideo.cid != requestCid) {
          self->setIsLoading(false);
          return;
        }

        // MP4 优先：拿到 durl 直接用单流播放，拿不到则回退 DASH 双流
        if (!audioOnly && fnval == 1) {
          const QString mp4Url = self->pickMp4Url(data);
          if (!mp4Url.isEmpty()) {
            int apiQuality = data.value("quality").toInt(0);
            // 请求的清晰度没有 MP4 流时，API 会静默降级返回更低的 MP4（如请求 1080P 返回 720P）。
            // 此时视为"未找到 MP4 流"，回退 DASH 以获取目标清晰度，避免播放被降级。
            if (allowDashFallback && apiQuality > 0 && apiQuality < requestedQuality) {
              self->setIsLoading(false);
              moduleSelf->requestPlayUrlInternal(requestedQuality, false, 4048, false);
              return;
            }
            int finalQuality = requestedQuality;
            if (apiQuality > 0) {
              finalQuality = apiQuality;
            }
            // dash 双流留空 → launchExternalPlayerCurrentSelection 走单 URL 播放分支
            self->setPlayResult(mp4Url, finalQuality, QString(), QString());
            self->setIsLoading(false);
            emit self->playbackReady(mp4Url);
            return;
          }
          if (allowDashFallback) {
            // 先平衡本次请求的 loading 计数，再发起 DASH 回退请求
            self->setIsLoading(false);
            moduleSelf->requestPlayUrlInternal(requestedQuality, false, 4048, false);
            return;
          }
          emit self->toastMessage("未获取到播放地址");
          self->setIsLoading(false);
          return;
        }

        // 仅用 DASH（fnval=4048）响应刷新可用清晰度：MP4（fnval=1）响应只含 MP4 支持的
        // 子集清晰度，用它刷新会把完整列表（如 1080P）冲掉，导致列表在播放/下载瞬间缩水。
        self->updateAcceptQualities(data);

        QString videoUrl;
        QString audioUrl;
        int finalQuality = audioOnly ? 0 : requestedQuality;
        int apiQuality = data.value("quality").toInt(0);
        if (!audioOnly && apiQuality > 0) {
          finalQuality = apiQuality;
        }

        if (audioOnly) {
          auto dash = self->pickDashUrls(data, requestedQuality);
          audioUrl = dash.audioUrl;
          if (audioUrl.isEmpty()) {
            emit self->toastMessage("未获取到音频播放地址");
            self->setIsLoading(false);
            return;
          }
          videoUrl = audioUrl;
        } else {
          videoUrl = self->pickMp4Url(data);
          if (videoUrl.isEmpty()) {
            auto dash = self->pickDashUrls(data, requestedQuality);
            videoUrl = dash.videoUrl;
            audioUrl = dash.audioUrl;
            finalQuality = dash.finalQuality;
          }
        }

        const QString dashVideoUrl = audioOnly ? QString() : videoUrl;
        const QString dashAudioUrl = audioUrl;

        if (videoUrl.isEmpty()) {
          emit self->toastMessage("未获取到播放地址");
          self->setIsLoading(false);
          return;
        }

        // URL 安全验证
        QUrl parsedUrl(videoUrl);
        if (!parsedUrl.isValid() || (!parsedUrl.scheme().startsWith("http"))) {
          emit self->toastMessage("播放地址无效");
          self->setIsLoading(false);
          return;
        }

        self->setPlayResult(videoUrl, finalQuality, dashVideoUrl, dashAudioUrl);

        if (!audioOnly && !audioUrl.isEmpty()) {
          QUrl parsedAudio(audioUrl);
          if (parsedAudio.isValid()) {
            qDebug() << "[BiliController] DASH: video + audio";
          }
        }

        self->setIsLoading(false);

        if (!videoUrl.isEmpty()) {
          emit self->playbackReady(videoUrl);
        }
      },
      [self, requestKey](int code, const QString &msg) {
        if (!self)
          return;
        if (self->m_playUrlLoadingKey != requestKey)
          return;

        self->m_playUrlLoadingKey.clear();
        self->clearPlayResult();
        self->setIsLoading(false);
        if (code == QNetworkReply::OperationCanceledError)
          return;
        emit self->toastMessage(QString("获取播放地址失败：%1").arg(msg));
      });
}

// ====== 仅获取可用清晰度 ======

void BiliPlaybackModule::fetchAcceptQualities(int quality) {
  if (m_controller->m_currentVideo.bvid.isEmpty() || m_controller->m_currentVideo.cid == 0) {
    emit m_controller->toastMessage("视频信息不完整，无法获取清晰度");
    return;
  }

  quality = qBound(16, quality, 127);
  const QString requestKey = QString("%1:%2:%3:%4")
                                 .arg(m_controller->m_currentVideo.bvid)
                                 .arg(m_controller->m_currentVideo.cid)
                                 .arg(quality)
                                 .arg(4048);
  const QString requestBvid = m_controller->m_currentVideo.bvid;
  const qint64 requestCid = m_controller->m_currentVideo.cid;
  if (m_controller->m_acceptQualitiesLoadingKey == requestKey) {
    return;
  }
  if (!m_controller->m_acceptQualitiesLoadingKey.isEmpty()) {
    m_controller->m_acceptQualitiesLoadingKey.clear();
    m_controller->setIsLoading(false);
  }
  m_controller->setIsLoading(true);
  m_controller->m_acceptQualitiesLoadingKey = requestKey;

  QMap<QString, QString> params;
  params["aid"] = QString::number(m_controller->videoAid());
  params["cid"] = QString::number(m_controller->m_currentVideo.cid);
  params["qn"] = QString::number(quality);
  params["bvid"] = m_controller->m_currentVideo.bvid;
  params["fnval"] = "4048";

  QPointer<BiliController> self(m_controller);

  m_controller->m_network->get(
      "/video/playurl", params,
      [self, requestKey, requestBvid, requestCid](const QJsonObject &data) {
        if (!self)
          return;
        if (self->m_acceptQualitiesLoadingKey != requestKey)
          return;

        self->m_acceptQualitiesLoadingKey.clear();
        if (self->m_currentVideo.bvid != requestBvid || self->m_currentVideo.cid != requestCid) {
          self->setIsLoading(false);
          return;
        }

        self->updateAcceptQualities(data);
        self->setIsLoading(false);
      },
      [self, requestKey](int, const QString &msg) {
        if (!self)
          return;
        if (self->m_acceptQualitiesLoadingKey != requestKey)
          return;
        self->m_acceptQualitiesLoadingKey.clear();
        self->setIsLoading(false);
        emit self->toastMessage(QString("获取清晰度失败：%1").arg(msg));
      });
}

// ====== 取消下载 ======

void BiliPlaybackModule::cancelDownload() {
  if (!m_controller->m_isDownloading)
    return;

  // 先置位取消状态再 abort：abort() 同步触发 onError，否则取消会被误判为失败
  m_controller->m_isDownloading = false;
  m_controller->m_downloadProgress = 0;
  m_controller->m_downloadStatus = "正在取消...";
  emit m_controller->downloadStateChanged();

  m_controller->m_network->cancelVideoDownload();

  emit m_controller->toastMessage("正在取消下载...");
}

void BiliPlaybackModule::cleanupTempSubtitle() {
  // 清掉请求 key，让页面销毁后迟到的 fetch 回调直接 return
  m_controller->m_playUrlLoadingKey.clear();
  m_controller->m_acceptQualitiesLoadingKey.clear();

  if (m_controller->m_tempSubtitlePath.isEmpty()) {
    m_controller->clearPlayResult();
    return;
  }

  const QString subtitlePath = m_controller->m_tempSubtitlePath;

  // mpv 以路径参数读字幕有打开时延，播放器仍在运行时不删，退出后再清
  if (isExternalPlayerRunning() && m_controller->m_externalPlayerProcess) {
    QPointer<BiliController> self(m_controller);
    QPointer<QProcess> proc(m_controller->m_externalPlayerProcess);
    QObject::connect(proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                     proc,
                     [self, proc, subtitlePath](int, QProcess::ExitStatus) {
                       if (!self)
                         return;
                       QFile::remove(subtitlePath);
                       if (self->m_tempSubtitlePath == subtitlePath) {
                         self->m_tempSubtitlePath.clear();
                       }
                     });
    // 页面销毁时不立即删除；m_tempSubtitlePath 保留，待 mpv 退出后清理。
    m_controller->clearPlayResult();
    return;
  }

  QFile::remove(subtitlePath);
  m_controller->m_tempSubtitlePath.clear();
  m_controller->clearPlayResult();
}

bool BiliPlaybackModule::isExternalPlayerRunning() const {
  return m_controller->m_externalPlayerProcess &&
         m_controller->m_externalPlayerProcess->state() != QProcess::NotRunning;
}

bool BiliPlaybackModule::externalPlayerRunning() const {
  return isExternalPlayerRunning();
}

QString BiliPlaybackModule::externalPlayerTitle() const {
  QString title = m_controller->videoTitle().trimmed();
  if (title.isEmpty()) {
    title = m_controller->m_currentVideo.bvid.trimmed();
  }
  return title;
}

int BiliPlaybackModule::resumeStartSeconds() const {
  if (m_controller->m_playbackProgressCid <= 0 || m_controller->m_playbackProgressCid != m_controller->m_currentVideo.cid) {
    return 0;
  }
  int seconds = m_controller->m_playbackProgressSeconds;
  if (seconds <= 0) {
    return 0;
  }
  if (m_controller->m_currentVideo.duration > 0 && seconds >= m_controller->m_currentVideo.duration) {
    return 0;
  }
  return seconds;
}

void BiliPlaybackModule::appendResumeStartArg(QStringList &args) const {
  int seconds = resumeStartSeconds();
  if (seconds > 0) {
    args << ("--start=" + QString::number(seconds));
  }
}

bool BiliPlaybackModule::startExternalPlayer(const QStringList &args) {
  const QString player = "/userdisk/mpv/mpv";
  if (!QFile::exists(player)) {
    emit m_controller->toastMessage("外部播放器不存在");
    return false;
  }

  if (isExternalPlayerRunning()) {
    emit m_controller->toastMessage("播放器已在运行，请先关闭当前窗口");
    return false;
  }

  auto *process = new QProcess(m_controller);
  process->setProgram(player);
  process->setArguments(args);

  QObject::connect(process, &QProcess::errorOccurred, m_controller,
          [this, process](QProcess::ProcessError error) {
            if (process != m_controller->m_externalPlayerProcess) {
              process->deleteLater();
              return;
            }

            QString detail = process->errorString();
            if (detail.isEmpty()) {
              detail = QString::number(static_cast<int>(error));
            }
            emit m_controller->toastMessage(QString("启动外部播放器失败：%1").arg(detail));
            m_controller->m_externalPlayerProcess = nullptr;
            process->deleteLater();
          });

  QObject::connect(process,
          QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), m_controller,
          [this, process](int, QProcess::ExitStatus) {
            if (process == m_controller->m_externalPlayerProcess) {
              m_controller->m_externalPlayerProcess = nullptr;
            }
            process->deleteLater();
          });

  m_controller->m_externalPlayerProcess = process;
  process->start();
  return true;
}

void BiliPlaybackModule::launchExternalPlayer(const QString &path) {
  if (path.isEmpty()) {
    emit m_controller->toastMessage("播放路径为空");
    return;
  }

  QString filePath = path;
  if (filePath.startsWith("file://")) {
    filePath = filePath.mid(7);
  }

  QStringList args;
  args << ("--force-media-title=" + externalPlayerTitle());
  appendResumeStartArg(args);
  args << filePath;
  if (filePath.startsWith("http")) {
    args << "--referrer=https://www.bilibili.com"
         << "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
         << biliHeartbeatScriptOpts(m_controller->videoAid(), m_controller->m_currentVideo.cid,
                                  m_controller->m_currentVideo.bvid, m_controller->m_currentVideo.duration,
                                  m_controller->m_videoPartModel);
  }
  startExternalPlayer(args);
}

void BiliPlaybackModule::launchExternalPlayerWithSubtitle(const QString &path, const QString &subtitlePath) {
  if (path.isEmpty()) {
    emit m_controller->toastMessage("播放路径为空");
    return;
  }

  QString filePath = path;
  QString sub = subtitlePath;
  if (filePath.startsWith("file://")) {
    filePath = filePath.mid(7);
  }
  if (sub.startsWith("file://")) {
    sub = sub.mid(7);
  }

  QStringList args;
  args << ("--force-media-title=" + externalPlayerTitle());
  appendResumeStartArg(args);
  args << filePath;
  if (!sub.isEmpty()) {
    args << ("--sub-file=" + sub);
  }
  if (filePath.startsWith("http")) {
    args << "--referrer=https://www.bilibili.com"
         << "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
         << biliHeartbeatScriptOpts(m_controller->videoAid(), m_controller->m_currentVideo.cid,
                                  m_controller->m_currentVideo.bvid, m_controller->m_currentVideo.duration,
                                  m_controller->m_videoPartModel);
  }
  startExternalPlayer(args);
}

void BiliPlaybackModule::downloadSelectedSubtitle(std::function<void(const QString &subtitlePath)> onFinished) {
  const QString subtitleUrl = m_controller->selectedSubtitleAssUrl();
  if (subtitleUrl.isEmpty()) {
    if (onFinished) onFinished(QString());
    return;
  }

  if (!m_controller->m_tempSubtitlePath.isEmpty()) {
    QFile oldSubtitle(m_controller->m_tempSubtitlePath);
    if (oldSubtitle.exists()) {
      oldSubtitle.remove();
    }
    m_controller->m_tempSubtitlePath.clear();
  }

  const QString tempDir = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
  const QString baseName = QString("bili_sub_%1_%2_%3_%4")
                               .arg(m_controller->m_currentVideo.bvid)
                               .arg(m_controller->m_currentVideo.cid)
                               .arg(m_controller->m_selectedSubtitleId)
                               .arg(QDateTime::currentMSecsSinceEpoch());
  const QString subtitlePath = QDir(tempDir).filePath(baseName + ".ass");
  m_controller->m_tempSubtitlePath = subtitlePath;

  QPointer<BiliController> self(m_controller);
  m_controller->m_network->downloadVideo(
      subtitleUrl, subtitlePath,
      [self, onFinished](const QString &path) {
        if (!self) return;
        if (onFinished) onFinished(path);
      },
      [self, onFinished](int, const QString &msg) {
        if (self) {
          self->m_tempSubtitlePath.clear();
          emit self->toastMessage(QString("字幕加载失败：%1").arg(msg));
        }
        if (onFinished) onFinished(QString());
      },
      nullptr, QStringLiteral("subtitle"));
}

void BiliPlaybackModule::launchExternalPlayerWithAudioUrl(const QString &videoUrl, const QString &audioUrl) {
  if (videoUrl.isEmpty() || audioUrl.isEmpty()) {
    emit m_controller->toastMessage("播放地址不完整");
    return;
  }

  QStringList args;
  args << ("--force-media-title=" + externalPlayerTitle());
  appendResumeStartArg(args);
  args << videoUrl << ("--audio-file=" + audioUrl)
       << "--referrer=https://www.bilibili.com"
       << "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
       << biliHeartbeatScriptOpts(m_controller->videoAid(), m_controller->m_currentVideo.cid,
                                  m_controller->m_currentVideo.bvid, m_controller->m_currentVideo.duration,
                                  m_controller->m_videoPartModel);

  startExternalPlayer(args);
}

void BiliPlaybackModule::launchExternalPlayerWithAudioUrlAndSubtitle(const QString &videoUrl, const QString &audioUrl, const QString &subtitlePath) {
  if (videoUrl.isEmpty() || audioUrl.isEmpty()) {
    emit m_controller->toastMessage("播放地址不完整");
    return;
  }

  QString sub = subtitlePath;
  if (sub.startsWith("file://")) {
    sub = sub.mid(7);
  }

  QStringList args;
  args << ("--force-media-title=" + externalPlayerTitle());
  appendResumeStartArg(args);
  args << videoUrl << ("--audio-file=" + audioUrl);
  if (!sub.isEmpty()) {
    args << ("--sub-file=" + sub);
  }
  args << "--referrer=https://www.bilibili.com"
       << "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
       << biliHeartbeatScriptOpts(m_controller->videoAid(), m_controller->m_currentVideo.cid,
                                  m_controller->m_currentVideo.bvid, m_controller->m_currentVideo.duration,
                                  m_controller->m_videoPartModel);

  qDebug() << "[BiliController] launchExternalPlayerWithAudioUrlAndSubtitle"
           << "sub=" << sub;

  startExternalPlayer(args);
}

void BiliPlaybackModule::fetchSubtitleList(bool silent) {
  fetchSubtitleListInternal(silent);
}

void BiliPlaybackModule::fetchSubtitleListInternal(bool silent, std::function<void()> onFinished) {
  if (m_controller->m_currentVideo.aid <= 0 || m_controller->m_currentVideo.cid <= 0) {
    if (!silent) emit m_controller->toastMessage("视频信息不完整，无法获取字幕");
    if (onFinished) onFinished();
    return;
  }

  const qint64 requestAid = m_controller->m_currentVideo.aid;
  const qint64 requestCid = m_controller->m_currentVideo.cid;
  const QString requestBvid = m_controller->m_currentVideo.bvid;
  const QString requestKey = m_controller->currentSubtitleRequestKey();
  if (m_controller->m_subtitleItemsKey == requestKey) {
    m_controller->applyDefaultSubtitleSelection();
    if (onFinished) onFinished();
    return;
  }
  if (m_controller->m_subtitleItemsLoadingKey == requestKey) {
    if (onFinished) {
      if (m_subtitleCallbackKey != requestKey) {
        m_subtitleCallbacks.clear();
        m_subtitleCallbackKey = requestKey;
      }
      m_subtitleCallbacks.push_back(std::move(onFinished));
    }
    return;
  }

  if (onFinished) {
    m_subtitleCallbackKey = requestKey;
    m_subtitleCallbacks.clear();
    m_subtitleCallbacks.push_back(std::move(onFinished));
  }

  QMap<QString, QString> params;
  params["aid"] = QString::number(requestAid);
  params["cid"] = QString::number(requestCid);
  params["bvid"] = requestBvid;

  m_controller->m_subtitleItemsLoadingKey = requestKey;
  QPointer<BiliController> self(m_controller);
  m_controller->m_network->get(
      "/video/subtitle/list", params,
      [self, requestAid, requestCid, requestBvid, requestKey](const QJsonObject &data) {
        if (!self)
          return;
        if (self->m_currentVideo.aid != requestAid ||
            self->m_currentVideo.cid != requestCid ||
            self->m_currentVideo.bvid != requestBvid) {
          if (self->m_subtitleItemsLoadingKey == requestKey) {
            self->m_subtitleItemsLoadingKey.clear();
          }
          return;
        }
        self->m_subtitleItemsLoadingKey.clear();
        self->m_subtitleItemsKey = requestKey;
        self->setSubtitleItems(data.value("subtitles").toArray());
        self->applyDefaultSubtitleSelection();
        if (self->m_playbackModule) {
          self->m_playbackModule->runSubtitleListCallbacks(requestKey);
        }
      },
      [self, requestAid, requestCid, requestBvid, requestKey, silent](int, const QString &msg) {
        if (!self)
          return;
        if (self->m_subtitleItemsLoadingKey == requestKey) {
          self->m_subtitleItemsLoadingKey.clear();
        }
        if (self->m_currentVideo.aid != requestAid ||
            self->m_currentVideo.cid != requestCid ||
            self->m_currentVideo.bvid != requestBvid) {
          return;
        }
        self->clearSubtitleItems();
        if (!silent) emit self->toastMessage(QString("获取字幕列表失败：%1").arg(msg));
        if (self->m_playbackModule) {
          self->m_playbackModule->runSubtitleListCallbacks(requestKey);
        }
      });
}

void BiliPlaybackModule::selectSubtitle(qint64 subtitleId, const QString &label) {
  m_controller->m_subtitleSelectionOverridden = true;
  m_controller->setSelectedSubtitle(subtitleId, label);
}

void BiliPlaybackModule::clearSelectedSubtitle() {
  m_controller->m_subtitleSelectionOverridden = true;
  m_controller->setSelectedSubtitle(0, QString());
}

void BiliPlaybackModule::setSubtitleFontSize(int value) {
  value = qBound(6, value, 40);
  if (m_controller->m_subtitleFontSize == value) return;
  m_controller->m_subtitleFontSize = value;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("subtitleFontSize", m_controller->m_subtitleFontSize);
  settings.sync();
  emit m_controller->subtitleStyleChanged();
}

void BiliPlaybackModule::setSubtitleMarginV(int value) {
  value = qBound(0, value, 30);
  if (m_controller->m_subtitleMarginV == value) return;
  m_controller->m_subtitleMarginV = value;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("subtitleMarginV", m_controller->m_subtitleMarginV);
  settings.sync();
  emit m_controller->subtitleStyleChanged();
}

void BiliPlaybackModule::setSubtitleSpacing(double value) {
  if (value < 0) value = 0;
  if (value > 6.0) value = 6.0;
  if (qFuzzyCompare(m_controller->m_subtitleSpacing, value)) return;
  m_controller->m_subtitleSpacing = value;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("subtitleSpacing", m_controller->m_subtitleSpacing);
  settings.sync();
  emit m_controller->subtitleStyleChanged();
}

void BiliPlaybackModule::setSubtitleWeight(int value) {
  value = qBound(100, value, 900);
  if (m_controller->m_subtitleWeight == value) return;
  m_controller->m_subtitleWeight = value;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("subtitleWeight", m_controller->m_subtitleWeight);
  settings.sync();
  emit m_controller->subtitleStyleChanged();
}

void BiliPlaybackModule::setSubtitleColorPreset(const QString &value) {
  QString preset = value;
  if (preset != "white" && preset != "yellow" && preset != "cyan" && preset != "black") {
    preset = "white";
  }
  if (m_controller->m_subtitleColorPreset == preset) return;
  m_controller->m_subtitleColorPreset = preset;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("subtitleColorPreset", m_controller->m_subtitleColorPreset);
  settings.sync();
  emit m_controller->subtitleStyleChanged();
}

void BiliPlaybackModule::setSubtitleOutlineEnabled(bool enabled) {
  if (m_controller->m_subtitleOutlineEnabled == enabled) return;
  m_controller->m_subtitleOutlineEnabled = enabled;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("subtitleOutlineEnabled", m_controller->m_subtitleOutlineEnabled);
  settings.sync();
  emit m_controller->subtitleStyleChanged();
}

void BiliPlaybackModule::setSubtitleOutlineWidth(int value) {
  value = qBound(1, value, 6);
  if (m_controller->m_subtitleOutlineWidth == value) return;
  m_controller->m_subtitleOutlineWidth = value;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("subtitleOutlineWidth", m_controller->m_subtitleOutlineWidth);
  settings.sync();
  emit m_controller->subtitleStyleChanged();
}

void BiliPlaybackModule::setSubtitleBackgroundEnabled(bool enabled) {
  if (m_controller->m_subtitleBackgroundEnabled == enabled) return;
  m_controller->m_subtitleBackgroundEnabled = enabled;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("subtitleBackgroundEnabled", m_controller->m_subtitleBackgroundEnabled);
  settings.sync();
  emit m_controller->subtitleStyleChanged();
}

void BiliPlaybackModule::setSubtitleBackgroundOpacity(double value) {
  if (value < 0.0) value = 0.0;
  if (value > 1.0) value = 1.0;
  if (qFuzzyCompare(m_controller->m_subtitleBackgroundOpacity, value)) return;
  m_controller->m_subtitleBackgroundOpacity = value;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("subtitleBackgroundOpacity", m_controller->m_subtitleBackgroundOpacity);
  settings.sync();
  emit m_controller->subtitleStyleChanged();
}

void BiliPlaybackModule::setVideoCardOffscreenPlaceholderEnabled(bool enabled) {
  if (m_controller->m_videoCardOffscreenPlaceholderEnabled == enabled) return;
  m_controller->m_videoCardOffscreenPlaceholderEnabled = enabled;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("videoCardOffscreenPlaceholderEnabled", m_controller->m_videoCardOffscreenPlaceholderEnabled);
  settings.sync();
  emit m_controller->preferenceSettingsChanged();
}

void BiliPlaybackModule::setVideoDetailPreloadEnabled(bool enabled) {
  if (m_controller->m_videoDetailPreloadEnabled == enabled) return;
  m_controller->m_videoDetailPreloadEnabled = enabled;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("videoDetailPreloadEnabled", m_controller->m_videoDetailPreloadEnabled);
  settings.sync();
  emit m_controller->preferenceSettingsChanged();
}

void BiliPlaybackModule::setDefaultSubtitleEnabled(bool enabled) {
  if (m_controller->m_defaultSubtitleEnabled == enabled) return;
  m_controller->m_defaultSubtitleEnabled = enabled;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("defaultSubtitleEnabled", m_controller->m_defaultSubtitleEnabled);
  settings.sync();
  if (enabled) {
    m_defaultSubtitleAttemptedKey.clear();
    m_controller->m_subtitleSelectionOverridden = false;
    if (!m_controller->applyDefaultSubtitleSelection()) {
      fetchSubtitleList(true);
    }
  }
  emit m_controller->preferenceSettingsChanged();
}

void BiliPlaybackModule::setPreferMp4Stream(bool enabled) {
  if (m_controller->m_preferMp4Stream == enabled) return;
  m_controller->m_preferMp4Stream = enabled;
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("preferMp4Stream", m_controller->m_preferMp4Stream);
  settings.sync();
  emit m_controller->preferenceSettingsChanged();
}

void BiliPlaybackModule::runSubtitleListCallbacks(const QString &requestKey) {
  if (m_subtitleCallbackKey != requestKey) {
    return;
  }
  auto callbacks = std::move(m_subtitleCallbacks);
  m_subtitleCallbacks.clear();
  m_subtitleCallbackKey.clear();
  for (const auto &callback : callbacks) {
    if (callback) {
      callback();
    }
  }
}

bool BiliPlaybackModule::shouldLoadDefaultSubtitle() const {
  if (!m_controller->m_defaultSubtitleEnabled ||
      m_controller->m_subtitleSelectionOverridden ||
      m_controller->m_selectedSubtitleId > 0) {
    return false;
  }

  const QString requestKey = m_controller->currentSubtitleRequestKey();
  if (requestKey.isEmpty()) {
    return false;
  }

  if (m_controller->m_subtitleItemsKey == requestKey) {
    m_controller->applyDefaultSubtitleSelection();
    return false;
  }
  if (m_controller->m_subtitleItemsLoadingKey == requestKey) {
    return true;
  }
  if (m_defaultSubtitleAttemptedKey == requestKey) {
    return false;
  }
  return true;
}

bool BiliPlaybackModule::ensureDefaultSubtitleForCurrentVideo(std::function<void()> onFinished) {
  if (!shouldLoadDefaultSubtitle()) {
    return false;
  }
  m_defaultSubtitleAttemptedKey = m_controller->currentSubtitleRequestKey();
  fetchSubtitleListInternal(true, std::move(onFinished));
  return true;
}

void BiliPlaybackModule::launchExternalPlayerCurrentSelection() {
  if (shouldLoadDefaultSubtitle()) {
    m_defaultSubtitleAttemptedKey = m_controller->currentSubtitleRequestKey();
    QPointer<BiliController> self(m_controller);
    fetchSubtitleListInternal(true, [self]() {
      if (!self || !self->m_playbackModule) return;
      self->m_playbackModule->launchExternalPlayerCurrentSelection();
    });
    return;
  }

  if (m_controller->m_dashVideoUrl.isEmpty() || m_controller->m_dashAudioUrl.isEmpty()) {
    if (!m_controller->m_playUrl.isEmpty()) {
      if (m_controller->m_selectedSubtitleId <= 0) {
        launchExternalPlayer(m_controller->m_playUrl);
      } else {
        const QString playUrl = m_controller->m_playUrl;
        QPointer<BiliController> self(m_controller);
        downloadSelectedSubtitle([self, playUrl](const QString &subtitlePath) {
          if (!self || !self->m_playbackModule) return;
          if (subtitlePath.isEmpty()) {
            self->m_playbackModule->launchExternalPlayer(playUrl);
          } else {
            self->m_playbackModule->launchExternalPlayerWithSubtitle(playUrl, subtitlePath);
          }
        });
      }
      return;
    }
    emit m_controller->toastMessage("播放地址尚未准备好");
    return;
  }

  if (m_controller->m_selectedSubtitleId <= 0) {
    launchExternalPlayerWithAudioUrl(m_controller->m_dashVideoUrl, m_controller->m_dashAudioUrl);
    return;
  }

  const QString videoUrl = m_controller->m_dashVideoUrl;
  const QString audioUrl = m_controller->m_dashAudioUrl;
  QPointer<BiliController> self(m_controller);
  downloadSelectedSubtitle([self, videoUrl, audioUrl](const QString &subtitlePath) {
    if (!self || !self->m_playbackModule) return;
    if (subtitlePath.isEmpty()) {
      self->m_playbackModule->launchExternalPlayerWithAudioUrl(videoUrl, audioUrl);
    } else {
      self->m_playbackModule->launchExternalPlayerWithAudioUrlAndSubtitle(
          videoUrl, audioUrl, subtitlePath);
    }
  });
}
