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
#include <QUrlQuery>
#include <QtGlobal>
#include <algorithm>
#include <functional>
#include <memory>

// ====== 内部辅助方法 ======

void BiliController::apiGet(const QString &path,
                            const QMap<QString, QString> &params,
                            std::function<void(const QJsonObject &)> onSuccess,
                            std::function<void(int, const QString &)> onError,
                            bool withLoading) {
  if (withLoading) {
    setIsLoading(true);
  }

  QPointer<BiliController> self(this);
  m_network->get(
      path, params,
      [self, onSuccess, withLoading](const QJsonObject &data) {
        if (!self)
          return;
        if (withLoading) {
          self->setIsLoading(false);
        }
        if (onSuccess) {
          onSuccess(data);
        }
      },
      [self, onError, withLoading](int code, const QString &msg) {
        if (!self)
          return;
        if (withLoading) {
          self->setIsLoading(false);
        }
        if (onError) {
          onError(code, msg);
        }
      });
}

void BiliController::updateAcceptQualities(const QJsonObject &data) {
  QVector<int> newAccepts;
  QJsonArray accept = data.value("accept_quality").toArray();
  for (const QJsonValue &v : accept) {
    int q = v.toInt(0);
    if (q > 0)
      newAccepts.append(q);
  }
  // 兼容 support_formats（仅保留可观看清晰度，作为补充）
  QJsonArray supportFormats = data.value("support_formats").toArray();
  for (const QJsonValue &v : supportFormats) {
    QJsonObject obj = v.toObject();
    int q = obj.value("quality").toInt(0);
    int canWatch = obj.value("can_watch_qn_reason").toInt(0);
    int limit = obj.value("limit_watch_reason").toInt(0);
    if (q > 0 && canWatch == 0 && limit == 0 && !newAccepts.contains(q)) {
      newAccepts.append(q);
    }
  }

  QJsonObject dash = data.value("dash").toObject();
  QJsonArray audioArray = dash.value("audio").toArray();
  if (!audioArray.isEmpty() && !newAccepts.contains(0)) {
    newAccepts.append(0);
  }

  setAcceptQualities(newAccepts);
}

BiliController::DashResult
BiliController::pickDashUrls(const QJsonObject &data, int requestedQuality) const {
  DashResult result;
  result.finalQuality = requestedQuality;

  QJsonObject dash = data.value("dash").toObject();
  if (dash.isEmpty()) {
    return result;
  }

  QJsonArray videoArray = dash.value("video").toArray();
  QJsonArray audioArray = dash.value("audio").toArray();

  auto pickVideoByQn = [&](int qn, bool preferAvc) -> bool {
    for (const QJsonValue &v : videoArray) {
      QJsonObject videoObj = v.toObject();
      if (videoObj.value("id").toInt(0) == qn) {
        QString codecs = videoObj.value("codecs").toString();
        if (preferAvc && !codecs.startsWith("avc")) {
          continue;
        }
        QString url = videoObj.value("base_url").toString();
        if (url.isEmpty())
          url = videoObj.value("baseUrl").toString();
        if (!url.isEmpty()) {
          result.videoUrl = url;
          result.finalQuality = qn;
          return true;
        }
      }
    }
    return false;
  };

  // 优先用户选择的清晰度（优先 AVC）
  if (!pickVideoByQn(requestedQuality, true)) {
    pickVideoByQn(requestedQuality, false);
  }

  if (result.videoUrl.isEmpty()) {
    QVector<int> qualityOrder = {16, 32, 64, 80, 112, 116, 120, 125};
    for (int qn : qualityOrder) {
      if (qn == requestedQuality)
        continue;
      if (pickVideoByQn(qn, true))
        break;
      if (pickVideoByQn(qn, false))
        break;
    }
  }

  if (!audioArray.isEmpty()) {
    QVector<int> audioOrder = {30280, 30232, 30216};
    for (int audioQn : audioOrder) {
      for (const QJsonValue &a : audioArray) {
        QJsonObject audioObj = a.toObject();
        if (audioObj.value("id").toInt(0) == audioQn) {
          QString url = audioObj.value("base_url").toString();
          if (url.isEmpty())
            url = audioObj.value("baseUrl").toString();
          if (!url.isEmpty()) {
            result.audioUrl = url;
            break;
          }
        }
      }
      if (!result.audioUrl.isEmpty())
        break;
    }
  }

  return result;
}

QString BiliController::pickMp4Url(const QJsonObject &data) const {
  QJsonArray durl = data.value("durl").toArray();
  if (durl.isEmpty())
    return "";

  QJsonObject first = durl.first().toObject();
  QString url = first.value("url").toString();
  if (url.isEmpty()) {
    QJsonArray backup = first.value("backup_url").toArray();
    if (!backup.isEmpty()) {
      url = backup.first().toString();
    }
  }
  return url;
}

void BiliController::startDownloadTask(const QString &videoUrl,
                                       const QString &audioUrl,
                                       const QString &videoPath,
                                       const QString &audioPath,
                                       int finalQuality, bool playAfter,
                                       const QString &successToastPrefix,
                                       const QString &errorToastPrefix,
                                       const QString &subtitleUrl,
                                       const QString &subtitlePath) {
  if (videoUrl.isEmpty() || videoPath.isEmpty()) {
    emit toastMessage("未获取到下载地址");
    setIsLoading(false);
    return;
  }

  m_isDownloading = true;
  m_downloadProgress = 0;
  m_downloadStatus = (finalQuality == 0) ? "正在下载音频..." : "正在下载视频...";
  emit downloadStateChanged();

  QPointer<BiliController> self(this);
  auto lastProgressEmit = std::make_shared<qint64>(0);
  auto lastProgressPercent = std::make_shared<int>(-1);
  auto finishSuccess = [self, finalQuality, playAfter, successToastPrefix, subtitleUrl, subtitlePath](const QString &path) {
    if (!self)
      return;

    auto completeDownload = [self, finalQuality, playAfter, successToastPrefix, path]() {
      if (!self)
        return;

      self->m_isDownloading = false;
      self->m_downloadProgress = 1.0;
      self->m_downloadStatus = "下载完成";
      if (playAfter) {
        self->m_playUrl = path;
        self->m_playQuality = finalQuality;
        emit self->playUrlChanged();
      }
      emit self->downloadStateChanged();
      self->setIsLoading(false);
      if (!successToastPrefix.isEmpty()) {
        emit self->toastMessage(successToastPrefix + path);
      }
    };

    if (!subtitleUrl.isEmpty() && !subtitlePath.isEmpty()) {
      self->m_downloadStatus = "正在保存字幕...";
      emit self->downloadStateChanged();
      self->m_network->downloadVideo(
          subtitleUrl, subtitlePath,
          [completeDownload](const QString &) { completeDownload(); },
          [self, completeDownload](int, const QString &msg) {
            if (self) {
              emit self->toastMessage(QString("字幕保存失败：%1").arg(msg));
            }
            completeDownload();
          });
      return;
    }

    completeDownload();
  };

  m_network->downloadVideo(
      videoUrl, videoPath,
      [self, audioUrl, audioPath, videoPath, finishSuccess](const QString &path) {
        if (!self)
          return;

        if (!audioUrl.isEmpty() && !audioPath.isEmpty()) {
          self->m_downloadStatus = "正在下载音频...";
          emit self->downloadStateChanged();

          self->m_network->downloadVideo(
              audioUrl, audioPath,
              [finishSuccess, videoPath](const QString &) { finishSuccess(videoPath); },
              [self](int, const QString &msg) {
                if (!self)
                  return;
                self->m_isDownloading = false;
                self->m_downloadProgress = 0;
                self->m_downloadStatus.clear();
                emit self->downloadStateChanged();
                self->setIsLoading(false);
                emit self->toastMessage(QString("音频下载失败：%1").arg(msg));
              });
          return;
        }

        finishSuccess(path);
      },
      [self, errorToastPrefix](int, const QString &msg) {
        if (!self)
          return;

        self->m_isDownloading = false;
        self->m_downloadProgress = 0;
        self->m_downloadStatus.clear();
        emit self->downloadStateChanged();
        self->setIsLoading(false);
        emit self->toastMessage(errorToastPrefix + msg);
      },
      [self, lastProgressEmit, lastProgressPercent](qint64 received, qint64 total) {
        if (!self)
          return;

        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        const int percent = total > 0 ? static_cast<int>((received * 100) / total) : -1;
        // 限制 UI 更新频率：最多约 5 次/秒；百分比变化时立即刷新
        if (*lastProgressEmit > 0 && now - *lastProgressEmit < 200 &&
            (percent < 0 || percent == *lastProgressPercent)) {
          return;
        }
        *lastProgressEmit = now;
        *lastProgressPercent = percent;

        double progress = total > 0 ? static_cast<double>(received) / total : 0;
        self->m_downloadProgress = progress;
        QString sizeStr;
        if (total > 0) {
          double mb = received / (1024.0 * 1024.0);
          double totalMb = total / (1024.0 * 1024.0);
          sizeStr = QString("%1MB / %2MB")
                        .arg(mb, 0, 'f', 1)
                        .arg(totalMb, 0, 'f', 1);
        } else {
          double mb = received / (1024.0 * 1024.0);
          sizeStr = QString("%1MB").arg(mb, 0, 'f', 1);
        }
        self->m_downloadStatus =
            QString("正在下载... %1 (%2%)")
                .arg(sizeStr)
                .arg(percent >= 0 ? percent : static_cast<int>(progress * 100));
        emit self->downloadStateChanged();
      });
}
