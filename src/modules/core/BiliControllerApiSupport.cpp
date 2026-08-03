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
                                       int finalQuality,
                                       const QString &successToastPrefix,
                                       const QString &errorToastPrefix,
                                       const QString &subtitleUrl,
                                       const QString &subtitlePath,
                                       const QString &finalOutputPath) {
  if (videoUrl.isEmpty() || videoPath.isEmpty()) {
    emit toastMessage("未获取到下载地址");
    // 入口已置位 m_isDownloading，提前返回时复位
    m_isDownloading = false;
    m_downloadProgress = 0;
    m_downloadStatus.clear();
    emit downloadStateChanged();
    setIsLoading(false);
    return;
  }

  m_isDownloading = true;
  m_downloadProgress = 0;
  m_downloadStatus = (finalQuality == 0) ? "正在下载音频..." : "正在下载视频...";
  emit downloadStateChanged();

  QPointer<BiliController> self(this);

  // 进度回调工厂：statusPrefix 用于区分“正在下载视频/音频”，
  // 每个阶段各自独立节流（最多约 5 次/秒；百分比变化时立即刷新），
  // 保证视频阶段结束后音频阶段的首次进度事件不被吞掉。
  auto makeProgressHandler = [self](const QString &statusPrefix) {
    auto lastProgressEmit = std::make_shared<qint64>(0);
    auto lastProgressPercent = std::make_shared<int>(-1);
    return [self, statusPrefix, lastProgressEmit,
            lastProgressPercent](qint64 received, qint64 total) {
      if (!self)
        return;

      const qint64 now = QDateTime::currentMSecsSinceEpoch();
      const int percent =
          total > 0 ? static_cast<int>((received * 100) / total) : -1;
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
          QString("%1 %2 (%3%)")
              .arg(statusPrefix)
              .arg(sizeStr)
              .arg(percent >= 0 ? percent : static_cast<int>(progress * 100));
      emit self->downloadStateChanged();
    };
  };

  // 两个流都下载完后：有最终输出路径则进入合并，否则直接收尾
  auto afterDownloadsComplete = [self, videoPath, audioPath, finalOutputPath,
                                 successToastPrefix, errorToastPrefix,
                                 subtitleUrl, subtitlePath]() {
    if (!self)
      return;
    // 取消后到达的成功回调不得复活任务
    if (!self->m_isDownloading)
      return;
    if (finalOutputPath.isEmpty()) {
      self->finishDownloadSuccess(videoPath, successToastPrefix, subtitleUrl,
                                  subtitlePath);
      return;
    }
    self->mergeM4sPair(videoPath, audioPath, finalOutputPath,
                       successToastPrefix, errorToastPrefix, subtitleUrl,
                       subtitlePath);
  };

  m_network->downloadVideo(
      videoUrl, videoPath,
      [self, audioUrl, audioPath, afterDownloadsComplete,
       makeProgressHandler](const QString &path) {
        if (!self)
          return;
        // 取消后不再启动音频下载
        if (!self->m_isDownloading)
          return;

        if (!audioUrl.isEmpty() && !audioPath.isEmpty()) {
          // 进入音频阶段：进度归零，避免沿用视频 100% 的进度条误导
          self->m_downloadProgress = 0;
          self->m_downloadStatus = "正在下载音频...";
          emit self->downloadStateChanged();

          self->m_network->downloadVideo(
              audioUrl, audioPath,
              [afterDownloadsComplete](const QString &) {
                afterDownloadsComplete();
              },
              [self](int, const QString &msg) {
                if (!self)
                  return;
                // 用户已取消（cancelDownload 先置位），静默
                if (!self->m_isDownloading)
                  return;
                self->m_isDownloading = false;
                self->m_downloadProgress = 0;
                self->m_downloadStatus.clear();
                emit self->downloadStateChanged();
                self->setIsLoading(false);
                emit self->toastMessage(QString("音频下载失败: %1").arg(msg));
              },
              makeProgressHandler(QStringLiteral("正在下载音频...")),
              QStringLiteral("video"));
          return;
        }

        afterDownloadsComplete();
      },
      [self, errorToastPrefix](int, const QString &msg) {
        if (!self)
          return;
        // 用户已取消（cancelDownload 先置位），静默
        if (!self->m_isDownloading)
          return;

        self->m_isDownloading = false;
        self->m_downloadProgress = 0;
        self->m_downloadStatus.clear();
        emit self->downloadStateChanged();
        self->setIsLoading(false);
        emit self->toastMessage(errorToastPrefix + msg);
      },
      makeProgressHandler((finalQuality == 0) ? QStringLiteral("正在下载音频...")
                                              : QStringLiteral("正在下载...")),
      QStringLiteral("video"));
}

void BiliController::finishDownloadSuccess(const QString &path,
                                           const QString &successToastPrefix,
                                           const QString &subtitleUrl,
                                           const QString &subtitlePath) {
  QPointer<BiliController> self(this);

  auto completeDownload = [self, successToastPrefix, path]() {
    if (!self)
      return;
    self->m_isDownloading = false;
    self->m_downloadProgress = 1.0;
    self->m_downloadStatus = "下载完成";
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
        [self](int, const QString &msg) {
          if (!self)
            return;
          // 用户已取消，静默
          if (!self->m_isDownloading)
            return;
          // 字幕失败时不再伪装成"下载完成"成功提示
          self->m_isDownloading = false;
          self->m_downloadProgress = 1.0;
          self->m_downloadStatus = "下载完成（字幕保存失败）";
          emit self->downloadStateChanged();
          self->setIsLoading(false);
          emit self->toastMessage(QString("下载完成，但字幕保存失败：%1").arg(msg));
        },
        nullptr, QStringLiteral("subtitle"));
    return;
  }

  completeDownload();
}

void BiliController::mergeM4sPair(const QString &videoPath,
                                  const QString &audioPath,
                                  const QString &outputPath,
                                  const QString &successToastPrefix,
                                  const QString &errorToastPrefix,
                                  const QString &subtitleUrl,
                                  const QString &subtitlePath) {
  if (videoPath.isEmpty() || audioPath.isEmpty() || outputPath.isEmpty()) {
    emit toastMessage("合并参数不完整");
    // 防御性复位，避免状态卡死（正常不可达）
    m_isDownloading = false;
    m_downloadProgress = 0;
    m_downloadStatus.clear();
    emit downloadStateChanged();
    setIsLoading(false);
    return;
  }

  // 合并本身就是一个下载任务阶段；断点续合场景下 m_isDownloading 尚为 false
  m_isDownloading = true;
  m_downloadStatus = "正在合并...";
  m_downloadProgress = 0.99;
  emit downloadStateChanged();

  QPointer<BiliController> self(this);

  QMap<QString, QString> params;
  params["video_path"] = videoPath;
  params["audio_path"] = audioPath;
  params["output_path"] = outputPath;

  m_network->get(
      "/video/merge", params,
      [self, videoPath, audioPath, outputPath, successToastPrefix, subtitleUrl,
       subtitlePath](const QJsonObject &) {
        if (!self)
          return;
        // 合并期间用户已取消：保留 m4s，不做收尾
        if (!self->m_isDownloading)
          return;

        // 合并成功，清理 .part 残留并删除 m4s 源文件
        QFile::remove(outputPath + ".part");
        QFile::remove(videoPath);
        QFile::remove(audioPath);
        self->finishDownloadSuccess(outputPath, successToastPrefix, subtitleUrl,
                                    subtitlePath);
      },
      [self, errorToastPrefix, outputPath](int code, const QString &msg) {
        if (!self)
          return;

        // 用户已取消（cancelDownload 已把 m_isDownloading 置 false）或请求被中止：
        // 静默收尾，保留 m4s 文件，重新下载会自动续合
        const bool userCanceled =
            !self->m_isDownloading ||
            code == QNetworkReply::OperationCanceledError;
        self->m_isDownloading = false;
        self->m_downloadProgress = 0;
        self->m_downloadStatus.clear();
        emit self->downloadStateChanged();
        self->setIsLoading(false);
        if (userCanceled)
          return;

        // 真实失败：清理 Go 侧可能残留的半成品，保留 m4s 文件，重新下载会自动走合并
        QFile::remove(outputPath + ".part");
        emit self->toastMessage(errorToastPrefix + msg +
                                QStringLiteral("（已保留 m4s 文件，重新下载会自动合并）"));
      },
      300000);
}
